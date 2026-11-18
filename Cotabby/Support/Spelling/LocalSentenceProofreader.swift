import Foundation

/// File overview:
/// The instant, on-device pass over a sentence the writer just finished. Word-level correction only
/// sees the word at the caret; this pass sees the whole sentence, so it can use the words on *both*
/// sides of each word and catch mechanical slips that only show up across words.
///
/// It returns two versions of the sentence:
/// - `autoCorrected`: fixes certain enough to apply without asking (a doubled `the the`, a space
///   before a comma, a missing space after one, double spaces, a leftover typo with an unambiguous
///   fix, lowercase `i`).
/// - `suggested`: `autoCorrected` plus fixes the writer should review (a likely wrong word such as
///   `their` → `there`, a typo whose best fix is not certain). The card shows these with a dotted
///   underline; Tab applies them.
///
/// Every rule here is a rule about prose, and the writer also types things that are not prose in
/// the middle of a sentence: a path, a file name, a flag, `a,b,c`, `i7`. Changing text that was
/// typed correctly is the worst thing this pass can do, so each rule first asks whether the words
/// it is looking at are plain words standing on their own (`WordToken.isJoined`, `isOrdinaryWord`)
/// and does nothing when they are not. A missed fix there costs little: the word-level gate
/// already had its say while the word was being typed.
///
/// Pure and dependency-injected, so the `cotabby-spell` CLI and unit tests exercise the same logic.
nonisolated struct LocalProofreadResult: Equatable, Sendable {
    let original: String
    let autoCorrected: String
    /// Words in `autoCorrected` the writer should decide on, in reading order.
    let flags: [SentenceFlag]

    /// `autoCorrected` with every flag's best option applied.
    var suggested: String { flags.applying(choices: flags.map { $0.options[0] }, to: autoCorrected) }
    var hasAutoFixes: Bool { autoCorrected != original }
    var hasSuggestions: Bool { !flags.isEmpty }
}

/// One word the writer should review: where it is, what was typed, and the replacements, best first.
nonisolated struct SentenceFlag: Equatable, Sendable {
    let range: Range<String.Index>
    let typed: String
    let options: [String]
}

extension [SentenceFlag] {
    /// `text` with flag `i` replaced by `choices[i]` (the typed word keeps it unchanged).
    nonisolated func applying(choices: [String], to text: String) -> String {
        var result = text
        for (flag, choice) in zip(self, choices).sorted(by: { $0.0.range.lowerBound > $1.0.range.lowerBound }) {
            result.replaceSubrange(flag.range, with: choice)
        }
        return result
    }
}

nonisolated enum LocalSentenceProofreader {
    struct Checks {
        /// Whether a word is misspelled (respecting words the writer chose to keep).
        let isTypo: (String) -> Bool
        /// Fixes for a misspelled word given the text before it, best first, and whether the best is certain.
        let fix: (_ word: String, _ textBefore: String) -> (options: [String], isCertain: Bool)?
        /// Bigram count, nil when unavailable.
        let pairCount: (_ first: String, _ second: String) -> Int64?
        /// N-gram likelihood of a word after the text before it (see
        /// `NextWordPredictor.contextScore`); vetoes wrong-word flags on words that fit the sentence.
        var sentenceScore: ((_ textBefore: String, _ word: String) -> Double)?
        /// The trained wrong-word check (`WrongWordDetector.suspects`): what a correctly spelled word
        /// was probably meant to be, best first; empty when it fits. Nil uses the listed confusables.
        var wrongWord: ((_ word: String, _ place: WordPlace) -> [String])?
    }

    /// Where a word sits in its sentence, for the wrong-word check.
    struct WordPlace {
        let textBefore: String
        let previous: String?
        let next: String?
        let afterNext: String?
    }

    /// The words whose repeat is always a slip (`the the`, `of of`), and so the only ones collapsed.
    ///
    /// The list is the words a repeat is certain for, not the words it is allowed for, because the
    /// second kind cannot be listed: any noun, adjective or exclamation can be doubled on purpose
    /// (`bye bye`, `a long long time`, `please please`, `mahi mahi`). Function words are a small
    /// closed set, so the ones English never doubles can be written down. Left out on purpose:
    /// - the ones that do double in correct sentences: `had had`, `that that`, `what it is is`,
    ///   `the one I have has`, `not not`, `gave her her keys`, `my my`, `he he`;
    /// - prepositions that end one phrase and start the next (`who do I talk to to fix this`,
    ///   `waiting for for ages`, `log in in a minute`);
    /// - single letters, which are as often labels as words (`a a b c`).
    static let neverDoubledWords: Set<String> = [
        "the", "an", "of", "with", "from", "into", "this", "these", "those", "your", "our", "their",
        "its", "his", "or", "but", "if", "because", "than", "as", "they", "she", "it", "be", "been",
        "am", "would", "could", "should", "which", "who"
    ]

    /// The verbs that take `have`, which is what `of` after one of them was meant to be.
    private static let modalsBeforeHave: Set<String> = ["could", "should", "would", "might", "must"]
    /// `might` and `must` are also nouns (`the might of Rome`, `a must of the season`). Right after
    /// one of these words they can only be the verb.
    private static let subjectsBeforeModal: Set<String> = [
        "i", "you", "he", "she", "it", "we", "they", "who", "that", "there",
        "someone", "somebody", "everyone", "everybody", "nobody"
    ]
    /// Words that may stand between `have` and its verb: `would of never known`.
    private static let adverbsBeforeParticiple: Set<String> = [
        "not", "never", "just", "already", "really", "probably", "easily", "also", "always",
        "actually", "even", "still", "ever", "definitely"
    ]
    /// Past participles that do not end in `-ed`.
    private static let irregularParticiples: Set<String> = [
        "been", "done", "gone", "had", "seen", "known", "got", "gotten", "made", "said", "taken",
        "come", "given", "told", "thought", "found", "left", "put", "kept", "let", "lost", "heard",
        "went", "came", "saw", "felt", "meant", "brought", "bought", "caught", "taught", "sent",
        "spent", "built", "written", "eaten", "forgotten", "spoken", "chosen", "broken", "fallen",
        "driven", "hidden", "run", "won", "read", "set", "cut", "hit", "hurt", "held", "paid", "sold",
        "stood", "understood", "become", "begun", "shown", "grown", "thrown", "drawn", "worn",
        "slept", "met", "sat", "stuck"
    ]
    /// A wrong-word suggestion needs the typed word to be this many times rarer on both sides combined.
    static let realWordSuggestRatio = RealWordErrorDetector.minimumRatio
    static let realWordMinimumSideRatio = 1.0

    static func proofread(_ sentence: String, checks: Checks) -> LocalProofreadResult {
        let auto = applyCertainFixes(to: sentence, checks: checks)
        return LocalProofreadResult(original: sentence, autoCorrected: auto, flags: flags(in: auto, checks: checks))
    }

    /// Pass one: everything certain. Fixing a typo can create a doubled word (`teh the` → `the the`),
    /// so doubled words are collapsed again at the end.
    private static func applyCertainFixes(to sentence: String, checks: Checks) -> String {
        let text = mechanicalFixes(sentence)
        var replacements: [(Range<String.Index>, String)] = []
        // A joined token is skipped whole. That is what keeps the `i` of `i.e.`, `i7`, `i/o`, `a[i]`
        // and `(i)` a letter instead of the pronoun, and `/etc/passwd` from becoming `/etc/passed`.
        for token in reviewableTokens(in: text) where !token.isJoined {
            let isPronoun = token.text == "i" || token.text.hasPrefix("i'") || token.text.hasPrefix("i’")
            if isPronoun {
                replacements.append((token.range, "I" + token.text.dropFirst()))
            } else if checks.isTypo(token.text),
                      !isLikelyName(token.text, textBefore: String(text[..<token.range.lowerBound])),
                      let fix = checks.fix(token.text, String(text[..<token.range.lowerBound])),
                      fix.isCertain, let best = fix.options.first {
                replacements.append((token.range, best))
            }
        }
        return collapseDoubledWords(apply(replacements, to: text))
    }

    /// Pass two, on the already-fixed text: words that need the writer's decision. A joined token is
    /// not offered either: the card would propose `app.tax` for `app.tsx`, and one Tab would apply it.
    private static func flags(in text: String, checks: Checks) -> [SentenceFlag] {
        let tokens = WordToken.tokens(in: text)
        var flags: [SentenceFlag] = []
        for (position, token) in tokens.enumerated() where position < tokens.count - 1 && !token.isJoined {
            let textBefore = String(text[..<token.range.lowerBound])
            if checks.isTypo(token.text) {
                // Capitalized mid-sentence is almost always a name the dictionary does not know.
                if isLikelyName(token.text, textBefore: textBefore) { continue }
                guard let fix = checks.fix(token.text, String(text[..<token.range.lowerBound])),
                      !fix.options.isEmpty else { continue }
                flags.append(SentenceFlag(range: token.range, typed: token.text, options: Array(fix.options.prefix(2))))
            } else if let wrongWord = checks.wrongWord {
                guard token.text != "I", !isLikelyName(token.text, textBefore: textBefore) else { continue }
                let options = wrongWord(token.text, WordPlace(
                    textBefore: textBefore,
                    previous: position > 0 ? tokens[position - 1].text : nil,
                    next: tokens[position + 1].text,
                    afterNext: position + 2 < tokens.count ? tokens[position + 2].text : nil
                ))
                guard !options.isEmpty else { continue }
                flags.append(SentenceFlag(
                    range: token.range,
                    typed: token.text,
                    options: options.map { TypoCaseTransfer.applying(caseOf: token.text, to: $0) }
                ))
            } else if !fitsSentence(token.text, textBefore: textBefore, checks: checks),
                      let alternative = realWordAlternative(
                token.text,
                previous: position > 0 ? tokens[position - 1].text : nil,
                next: tokens[position + 1].text,
                count: checks.pairCount
            ) {
                let option = TypoCaseTransfer.applying(caseOf: token.text, to: alternative)
                flags.append(SentenceFlag(range: token.range, typed: token.text, options: [option]))
            }
        }
        return flags
    }

    /// The sentence model's veto: a word it finds likely after the text before it is left alone,
    /// whatever the pair counts say (they split contractions, so `It's hard` looked wrong).
    private static func fitsSentence(_ word: String, textBefore: String, checks: Checks) -> Bool {
        guard let score = checks.sentenceScore, !RealWordErrorDetector.alternatives(for: word).isEmpty else { return false }
        return RealWordErrorDetector.sentenceVerdict(word: word, score: { score(textBefore, $0) }).typedFits
    }

    private static func isLikelyName(_ word: String, textBefore: String) -> Bool {
        guard word.first?.isUppercase == true, word != "I" else { return false }
        let before = textBefore.trimmingCharacters(in: .whitespaces)
        guard let last = before.last else { return false }
        return !".!?\"“(".contains(last)
    }

    /// Every word except the last, which the word-level gate already handles at the caret.
    private static func reviewableTokens(in text: String) -> ArraySlice<WordToken> {
        WordToken.tokens(in: text).dropLast()
    }

    // MARK: - Mechanical fixes

    static func mechanicalFixes(_ text: String) -> String {
        // Two or more spaces between words collapse to one.
        var result = text.replacingOccurrences(of: "(?<=\\S) {2,}(?=\\S)", with: " ", options: .regularExpression)
        result = apply(punctuationSpacingFixes(in: result), to: result)
        result = apply(modalOfFixes(in: result), to: result)
        return collapseDoubledWords(result)
    }

    /// A word a spacing rule may act next to: letters only, more than one of them, and not all
    /// capitals. That leaves out everything a comma or a question mark sits beside in code, where
    /// the spacing is the writer's own: one-letter names (`a,b,c`, `x ? y : z`), acronyms (`TL;DR`),
    /// and anything with a bracket, a slash, a sign or a digit in it (`foo(a,b)`, `u+x,g+r`).
    private static func isOrdinaryWord(_ word: Substring) -> Bool {
        word.count >= 2 && word.allSatisfy(WordToken.isWordCharacter)
            && word.first?.isLetter == true && word.contains(where: \.isLowercase)
    }

    /// Spaces on the wrong side of a mark, each fix as the range to replace and its replacement.
    ///
    /// The rules read the sentence as the pieces between its spaces, so "both sides are ordinary
    /// words" is a question about whole pieces and not about the one letter next to the mark.
    private static func punctuationSpacingFixes(in text: String) -> [(Range<String.Index>, String)] {
        let pieces = text.split(whereSeparator: \.isWhitespace)
        var fixes: [(Range<String.Index>, String)] = []
        for (index, piece) in pieces.enumerated() {
            // No space after a comma: `hello,world` → `hello, world`. One comma between two words is
            // a slip; more (`name,email,phone`) is a list written that way on purpose. A semicolon
            // with no space on either side is left alone: there it is `TL;DR` or `cd src;ls` far more
            // often than a sentence.
            let core = WordToken.core(of: piece)
            if let comma = core.firstIndex(of: ","), isOrdinaryWord(core[..<comma]),
               isOrdinaryWord(core[core.index(after: comma)...]) {
                fixes.append((comma..<core.index(after: comma), ", "))
            }

            guard index > 0, let mark = piece.first else { continue }
            let previous = pieces[index - 1]
            let gap = previous.endIndex..<piece.startIndex
            guard previous.last?.isLetter == true, isOrdinaryWord(WordToken.core(of: previous)),
                  text[gap].allSatisfy({ $0 == " " }) else { continue }
            if piece.count == 1 {
                // A mark standing alone: `hello , world` → `hello, world`, `Is it ready ?` → `ready?`.
                // A comma or semicolon needs a word after it as well. A `?` or `!` is only moved at
                // the very end, where it closes the sentence; further in it is `x ? y : z`. A lone
                // colon or full stop is never moved: `key : value`, and the `.` of `git add .` is the
                // folder, which closing the gap would turn into the end of the word `add`.
                let isLast = index == pieces.count - 1
                let closesSentence = isLast && "!?".contains(mark)
                let separatesWords = ",;".contains(mark) && (isLast || WordToken.isProse(pieces[index + 1]))
                if closesSentence || separatesWords { fixes.append((gap, "")) }
            } else if ",;".contains(mark), isOrdinaryWord(WordToken.core(of: piece.dropFirst())) {
                // The space on the wrong side: `hello ,world` → `hello, world`.
                fixes.append((gap.lowerBound..<piece.index(after: piece.startIndex), "\(mark) "))
            }
        }
        return fixes
    }

    /// `could of` is `could have` written as it sounds: each `of` to replace, with its `have`.
    ///
    /// Only the certain cases. `of` is also a real preposition after these words (`would of
    /// necessity`, `could of course`), so the word after it must be the verb `have` needs: a past
    /// participle, with at most one adverb in front (`should of never gone`). And `might` and `must`
    /// are also nouns (`the might of armed men`), so those two need a subject right before them,
    /// unless `n't` already makes them a verb.
    private static func modalOfFixes(in text: String) -> [(Range<String.Index>, String)] {
        let tokens = WordToken.tokens(in: text)
        /// The lowercased word `offset` tokens from `index`, when every step from one to the other
        /// is a plain word a single space from its neighbour. A comma in between, or a joined token,
        /// means the words do not belong to one phrase, and the answer is nil.
        func word(_ offset: Int, from index: Int) -> String? {
            let target = index + offset
            guard tokens.indices.contains(target) else { return nil }
            for position in min(index, target)..<max(index, target) {
                let gap = text[tokens[position].range.upperBound..<tokens[position + 1].range.lowerBound]
                guard gap == " ", !tokens[position].isJoined, !tokens[position + 1].isJoined else { return nil }
            }
            return tokens[target].text.lowercased()
        }
        func isParticiple(_ word: String?) -> Bool {
            guard let word else { return false }
            return irregularParticiples.contains(word) || (word.count >= 4 && word.hasSuffix("ed") && !word.hasSuffix("eed"))
        }

        var fixes: [(Range<String.Index>, String)] = []
        for index in tokens.indices where word(1, from: index) == "of" {
            var modal = tokens[index].text.lowercased()
            let isNegated = modal.hasSuffix("n't") || modal.hasSuffix("n’t")
            if isNegated { modal.removeLast(3) }
            guard modalsBeforeHave.contains(modal) else { continue }

            let afterOf = word(2, from: index)
            let verb = afterOf.map(adverbsBeforeParticiple.contains) == true ? word(3, from: index) : afterOf
            guard isParticiple(verb) else { continue }
            let canBeNoun = (modal == "might" || modal == "must") && !isNegated
            if canBeNoun, word(-1, from: index).map(subjectsBeforeModal.contains) != true { continue }

            let typedOf = tokens[index + 1]
            fixes.append((typedOf.range, TypoCaseTransfer.applying(caseOf: typedOf.text, to: "have")))
        }
        return fixes
    }

    /// Removes the second of two identical words when the repeat can only be a slip (see
    /// `neverDoubledWords`). A capitalised second word inside the sentence is a name (`The The`,
    /// like `Bora Bora`), and a joined token is not a word at all, so both stay.
    private static func collapseDoubledWords(_ text: String) -> String {
        let tokens = WordToken.tokens(in: text)
        var removals: [Range<String.Index>] = []
        for (index, token) in tokens.enumerated() where index > 0 {
            let previous = tokens[index - 1]
            let between = text[previous.range.upperBound..<token.range.lowerBound]
            guard between == " ", !previous.isJoined, !token.isJoined,
                  previous.text.lowercased() == token.text.lowercased(),
                  token.text.first?.isUppercase != true,
                  neverDoubledWords.contains(token.text.lowercased()) else { continue }
            removals.append(previous.range.upperBound..<token.range.upperBound)
        }
        var result = text
        for range in removals.reversed() {
            result.removeSubrange(range)
        }
        return result
    }

    // MARK: - Real-word check with both neighbors

    static func realWordAlternative(
        _ word: String,
        previous: String?,
        next: String?,
        count: (String, String) -> Int64?
    ) -> String? {
        let typed = word.lowercased()
        let floor = 1_000_000.0
        var best: (term: String, ratio: Double)?
        for option in RealWordErrorDetector.alternatives(for: typed) {
            var sides: [Double] = []
            var supporting: Int64 = 0
            // A side where neither pairing is in the list says nothing, so it neither helps nor vetoes.
            for (typedPair, optionPair) in [
                previous.map { ((($0, typed)), ($0, option)) },
                next.map { (((typed, $0)), (option, $0)) }
            ].compactMap({ $0 }) {
                guard let typedCount = count(typedPair.0, typedPair.1),
                      let optionCount = count(optionPair.0, optionPair.1) else { return nil }
                guard typedCount > 0 || optionCount > 0 else { continue }
                sides.append(Double(optionCount) / max(Double(typedCount), floor))
                supporting += optionCount
            }
            guard !sides.isEmpty, supporting >= RealWordErrorDetector.minimumAlternativeCount,
                  sides.allSatisfy({ $0 >= realWordMinimumSideRatio }) else { continue }
            let ratio = sides.reduce(1, *)
            if ratio >= realWordSuggestRatio, ratio > (best?.ratio ?? 0) {
                best = (option, ratio)
            }
        }
        return best?.term
    }

    // MARK: - Applying replacements

    private static func apply(_ replacements: [(Range<String.Index>, String)], to text: String) -> String {
        var result = text
        for (range, replacement) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}

/// A run of letters (and inner apostrophes) inside a sentence.
nonisolated struct WordToken {
    let text: String
    let range: Range<String.Index>
    /// True when the run is not a word standing on its own: it is typed against something else with
    /// no space between, as in a path (`/etc/passwd`), a dotted, slashed, hyphenated or underscored
    /// name (`fs.readdir`, `i/o`, `aws-sdk`, `tmp_buf`), a flag (`--force`), a call or an index
    /// (`foo(a,b)`, `a[i]`), an abbreviation (`i.e.`), or anything touching a digit (`i7`).
    ///
    /// This is the sentence pass's form of `CurrentWordExtractor.Result.isJoined`, and it exists so
    /// the two levels agree: at the caret, a word in such text is never fixed without asking, and
    /// most of it is not checked at all. The sentence pass applies its fixes with no bar to decline
    /// them on, and its card applies a suggestion on one Tab, so here a joined token is neither
    /// fixed nor offered. The letters still come back as tokens because other callers count words.
    let isJoined: Bool

    /// Quotes and brackets that open in front of a word without being part of it.
    private static let openingMarks: Set<Character> = ["(", "[", "\"", "“", "‘", "'"]
    /// What can follow a word without being part of it. A slash or a hyphen is not here: `teh-` is
    /// the start of a joined word, which the caret-level check also only offers a fix for.
    private static let closingMarks: Set<Character> = [",", ";", ":", ".", "!", "?", "…", ")", "]", "\"", "”", "’", "'"]
    private static let closingQuotes: Set<Character> = ["\"", "”", "’", "'"]

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character == "'" || character == "’"
    }

    /// A piece of the sentence without the quotes, brackets and sentence punctuation around it.
    static func core(of piece: Substring) -> Substring {
        var core = piece.drop(while: openingMarks.contains)
        while let last = core.last, closingMarks.contains(last) { core = core.dropLast() }
        return core
    }

    /// Whether a piece of the sentence (the text between two spaces) is one plain word.
    ///
    /// A single letter closed by a bracket (`(i)`, `a)`, `[x]`) or quoted on both sides (`"i"`) is a
    /// list marker or a letter being talked about, not a word being used, so it does not count.
    static func isProse(_ piece: Substring) -> Bool {
        let core = core(of: piece)
        guard !core.isEmpty, core.allSatisfy(isWordCharacter) else { return false }
        guard core.count == 1, core.endIndex < piece.endIndex else { return true }
        let closer = piece[core.endIndex]
        let isQuotedLetter = core.startIndex > piece.startIndex && closingQuotes.contains(closer)
        return !(closer == ")" || closer == "]" || isQuotedLetter)
    }

    static func tokens(in text: String) -> [WordToken] {
        var tokens: [WordToken] = []
        // A dash between words is sentence punctuation like a space (`late—the bus`), so it ends a
        // piece too. Cutting there cannot change the tokens, since a dash is not a letter.
        for piece in text.split(whereSeparator: { $0.isWhitespace || $0 == "—" || $0 == "–" }) {
            let isJoined = !isProse(piece)
            var start: String.Index?
            var index = piece.startIndex
            while index < piece.endIndex {
                let character = piece[index]
                let next = piece.index(after: index)
                let isInnerApostrophe = (character == "'" || character == "’") && start != nil
                    && next < piece.endIndex && piece[next].isLetter
                if character.isLetter || isInnerApostrophe {
                    if start == nil { start = index }
                } else if let begin = start {
                    tokens.append(WordToken(text: String(piece[begin..<index]), range: begin..<index, isJoined: isJoined))
                    start = nil
                }
                index = next
            }
            if let begin = start {
                tokens.append(WordToken(text: String(piece[begin...]), range: begin..<piece.endIndex, isJoined: isJoined))
            }
        }
        return tokens
    }
}
