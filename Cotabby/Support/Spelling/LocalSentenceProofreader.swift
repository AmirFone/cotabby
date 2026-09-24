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
    }

    /// Repeats that are real English (`had had`, `that that`, `bye bye`) are never collapsed.
    static let legitimateRepeats: Set<String> = [
        "that", "had", "bye", "ha", "haha", "no", "very", "so", "really", "well", "go", "now", "knock",
        "blah", "la", "do", "yeah", "yes", "ok", "okay", "more", "again", "over", "and", "on", "round",
        "far", "away", "is", "can", "tut", "chop", "hip", "night", "boo", "hear", "there", "come"
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
        for token in reviewableTokens(in: text) {
            if token.text == "i" || token.text.hasPrefix("i'") {
                replacements.append((token.range, "I" + token.text.dropFirst()))
            } else if checks.isTypo(token.text),
                      let fix = checks.fix(token.text, String(text[..<token.range.lowerBound])),
                      fix.isCertain, let best = fix.options.first {
                replacements.append((token.range, best))
            }
        }
        return collapseDoubledWords(apply(replacements, to: text))
    }

    /// Pass two, on the already-fixed text: words that need the writer's decision.
    private static func flags(in text: String, checks: Checks) -> [SentenceFlag] {
        let tokens = WordToken.tokens(in: text)
        var flags: [SentenceFlag] = []
        for (position, token) in tokens.enumerated() where position < tokens.count - 1 {
            if checks.isTypo(token.text) {
                guard let fix = checks.fix(token.text, String(text[..<token.range.lowerBound])),
                      !fix.options.isEmpty else { continue }
                flags.append(SentenceFlag(range: token.range, typed: token.text, options: Array(fix.options.prefix(2))))
            } else if let alternative = realWordAlternative(
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

    /// Every word except the last, which the word-level gate already handles at the caret.
    private static func reviewableTokens(in text: String) -> ArraySlice<WordToken> {
        WordToken.tokens(in: text).dropLast()
    }

    // MARK: - Mechanical fixes

    static func mechanicalFixes(_ text: String) -> String {
        var result = text
        // Two or more spaces between words collapse to one.
        result = result.replacingOccurrences(of: "(?<=\\S) {2,}(?=\\S)", with: " ", options: .regularExpression)
        // A comma or semicolon on the wrong side of the space: `hello ,world` → `hello, world`.
        result = result.replacingOccurrences(of: "(?<=\\p{L}) +([,;])(?=\\p{L})", with: "$1 ", options: .regularExpression)
        // No space before punctuation: `hello , world` → `hello, world`.
        result = result.replacingOccurrences(of: "(?<=\\p{L}) +(?=[,;:!?.](\\s|$))", with: "", options: .regularExpression)
        // A space after a comma or semicolon between words: `hello,world` → `hello, world`.
        result = result.replacingOccurrences(of: "(?<=\\p{L})([,;])(?=\\p{L})", with: "$1 ", options: .regularExpression)
        return collapseDoubledWords(result)
    }

    private static func collapseDoubledWords(_ text: String) -> String {
        let tokens = WordToken.tokens(in: text)
        var removals: [Range<String.Index>] = []
        for (index, token) in tokens.enumerated() where index > 0 {
            let previous = tokens[index - 1]
            let between = text[previous.range.upperBound..<token.range.lowerBound]
            guard between == " ", previous.text.lowercased() == token.text.lowercased(),
                  !legitimateRepeats.contains(token.text.lowercased()) else { continue }
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

    static func tokens(in text: String) -> [WordToken] {
        var tokens: [WordToken] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            let isInnerApostrophe = (character == "'" || character == "’") && start != nil
                && next < text.endIndex && text[next].isLetter
            if character.isLetter || isInnerApostrophe {
                if start == nil { start = index }
            } else if let begin = start {
                tokens.append(WordToken(text: String(text[begin..<index]), range: begin..<index))
                start = nil
            }
            index = next
        }
        if let begin = start {
            tokens.append(WordToken(text: String(text[begin...]), range: begin..<text.endIndex))
        }
        return tokens
    }
}
