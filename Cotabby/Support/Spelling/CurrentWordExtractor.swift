import Foundation

/// File overview:
/// Pure helper that pulls the trailing word out of the text before the caret. Used by the typo
/// gate to decide whether to suppress a completion or offer a correction, and again at accept time
/// to recompute how many characters to delete from the *live* field.
///
/// We intentionally do not lean on `NSLinguisticTagger` or `NLTokenizer` here. Both pull in language
/// detection that is overkill for the "is the cursor inside or just after a word" question. A
/// whitespace walk is faster, deterministic, and easy to reason about.
enum CurrentWordExtractor {
    struct Result: Equatable, Sendable {
        let word: String
        /// Number of extended grapheme clusters in the word. This is the count the inserter needs:
        /// one Delete keypress removes one user-perceived character, so deleting the word back to its
        /// start takes exactly this many backspaces.
        let characterCount: Int
        /// True when the word is one of several joined by a dot or a slash (`name` in `users.name`).
        /// Such text is as often a name or an identifier as prose, so a fix may be offered there
        /// but is never made without asking.
        var isJoined = false
    }

    /// Returns the trailing word at the cursor, or `nil` when:
    ///  - the cursor is on (or just after) whitespace (so there is no "current word"),
    ///  - the trailing token is implausible as natural language (URL, code, all-caps acronym,
    ///    digits), where `NSSpellChecker` would over-flag,
    ///  - the trailing token is too short (single-letter words are too noisy to act on).
    static func extract(from precedingText: String) -> Result? {
        guard let lastCharacter = precedingText.last, !lastCharacter.isWhitespace else {
            return nil
        }

        // Walk back to the previous whitespace boundary; that is the start of the trailing word.
        var startIndex = precedingText.endIndex
        while startIndex > precedingText.startIndex {
            let prior = precedingText.index(before: startIndex)
            if precedingText[prior].isWhitespace {
                break
            }
            startIndex = prior
        }

        let token = precedingText[startIndex..<precedingText.endIndex]
        // Words joined by a dot or a slash (`users.name`, `read/write`): the word at the caret is the
        // last of them. A hyphenated token stays whole when it has no other mark, because the
        // dictionary knows hyphenated words (`well-knwon` → well-known).
        if token.contains(where: { $0 == "." || $0 == "/" }) {
            guard let last = joinedWords(in: token)?.last, isPlausibleNaturalWord(String(last)) else { return nil }
            return Result(word: String(last), characterCount: last.count, isJoined: true)
        }
        let word = String(token)
        guard isPlausibleNaturalWord(word) else {
            return nil
        }
        return Result(word: word, characterCount: word.count)
    }

    /// Punctuation that can follow a word without being part of it. Apostrophes are excluded because
    /// they belong to contractions and possessives (`dogs'`). A slash or a hyphen right after a
    /// word finishes it like a comma does (`recieve/`, `teh-`), so the word is still checked.
    static let trailingPunctuation: Set<Character> = [",", ";", ":", ".", "!", "?", ")", "]", "\"", "”", "/", "-"]

    /// The marks that join words with no space between them.
    static let joiningMarks: Set<Character> = [".", "/", "-"]

    /// The long dashes. They are typed between two clauses, with spaces or without (`done—then`),
    /// and macOS writes one for two hyphens in a row. A word begun against one is the first word
    /// of the next clause, not the second half of a compound.
    static let longDashes: Set<Character> = ["—", "–"]

    /// The letters after the last hyphen of `word`: what the writer is typing in a compound that
    /// is not finished (`kn` in `well-kn`). The whole word when it has no hyphen.
    static func partBeingTyped(of word: String) -> Substring {
        guard let hyphen = word.lastIndex(of: "-") else { return Substring(word) }
        return word[word.index(after: hyphen)...]
    }

    /// What follows a dot in a file name or a web address. A token with one of these is not words
    /// joined by a dot, and nothing in it is a spelling mistake.
    private static let fileAndDomainEndings: Set<String> = [
        "com", "org", "net", "edu", "gov", "io", "dev", "ai", "co", "uk", "us", "ca", "de", "app",
        "txt", "md", "pdf", "png", "jpg", "jpeg", "gif", "svg", "csv", "tsv", "json", "xml", "html", "htm", "css",
        "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "swift", "java", "kt", "sql", "yml", "yaml", "toml", "sh",
        "zip", "gz", "tar", "dmg", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "log", "plist", "lock"
    ]

    /// True when the text ends in plain words joined by dots, slashes or hyphens, the last of them
    /// possibly not started yet (`users.na`, `read/`); false for a web address, a path or a file name.
    /// The word strip asks this to decide whether a word begun against a mark is prose.
    static func endsInJoinedWords(_ text: String) -> Bool {
        let token = text[(text.lastIndex(where: \.isWhitespace).map { text.index(after: $0) } ?? text.startIndex)...]
        return joinedWords(in: token, allowingOpenEnd: true) != nil
    }

    /// The words of a token made of plain words joined by single dots, slashes or hyphens
    /// (`users.name`, `schema.table.column`, `read/write`), or nil for anything else: a web address,
    /// a path, a file name, a version number, an email address. The caller acts on the words of such
    /// a token one at a time; everything else with these marks in it is left alone, as before.
    ///
    /// - Parameter allowingOpenEnd: accept a token that ends in its mark (`read/`), giving an empty
    ///   last word, for the caller that wants to suggest what comes next.
    static func joinedWords(in token: Substring, allowingOpenEnd: Bool = false) -> [Substring]? {
        let words = token.split(omittingEmptySubsequences: false) { joiningMarks.contains($0) }
        guard words.count >= 2, token.filter({ $0 == "/" }).count <= 1, words[0].lowercased() != "www" else { return nil }
        for (index, word) in words.enumerated() {
            let isOpenEnd = allowingOpenEnd && index == words.count - 1
            guard !word.isEmpty || isOpenEnd,
                  word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return nil }
            if index > 0, token[token.index(before: word.startIndex)] == ".", fileAndDomainEndings.contains(word.lowercased()) {
                return nil
            }
        }
        return words
    }

    /// Like `extract(from:)`, but tolerates exactly one trailing space so a *just-finished* word
    /// (the user typed the word and then pressed space) is still surfaced as the trailing word, and
    /// sets aside punctuation typed right after it (`teh,` → word `teh`, punctuation `,`), so a typo
    /// before a comma or period is still caught. Returns the word, how many trailing spaces were
    /// skipped (0 or 1), and the punctuation between them.
    ///
    /// This is what lets an offered correction survive the user pressing space: the word is still
    /// recognized, the green fix stays acceptable, and the accept path knows to preserve the space.
    /// Two or more trailing spaces (the user has moved on), a tab or a line break, or no plausible
    /// word before the space all return nil. Only a single space from `wordFinishingSpaces` is
    /// tolerated.
    /// The word at or just before the caret, with what separates it from the caret.
    struct TrailingWord: Equatable, Sendable {
        let result: Result
        /// The space after the word exactly as the field holds it, or empty when there is none. Kept
        /// as text, not as a count, because a replacement types it back: a non-breaking space the
        /// writer (or the host) put there must not come back as a plain one.
        let trailingSpace: String
        let trailingPunctuation: String

        var trailingSpaceCount: Int { trailingSpace.count }
    }

    /// The characters a field can hold for the one space that finishes a word: the plain space and
    /// the non-breaking ones. They are not only typography. Chromium stores the last space of a line
    /// in an editable page as U+00A0 until the next letter is typed (measured: `teh` then Space reads
    /// back as `teh\u{00A0}`), so a rule that knew only the plain space never checked a word in such
    /// a field. The same three are treated as a space by `AXTextGeometryResolver`.
    static let wordFinishingSpaces: Set<Character> = [" ", "\u{00A0}", "\u{202F}", "\u{2007}"]

    static func extractTrailingWord(from precedingText: String) -> TrailingWord? {
        var text = Substring(precedingText)
        var space = ""
        if let last = text.last, wordFinishingSpaces.contains(last) {
            text = text.dropLast()
            space = String(last)
            // A second trailing whitespace means the caret is no longer adjacent to a finished word.
            if text.last?.isWhitespace == true { return nil }
        }
        var punctuation = ""
        while let last = text.last, trailingPunctuation.contains(last), punctuation.count < 3 {
            punctuation.insert(last, at: punctuation.startIndex)
            text = text.dropLast()
        }
        guard let result = extract(from: String(text)) else { return nil }
        return TrailingWord(result: result, trailingSpace: space, trailingPunctuation: punctuation)
    }

    /// Everything before the trailing word (and its punctuation and space), or nil when there is none.
    static func textBeforeTrailingWord(in precedingText: String) -> String? {
        guard let trailing = extractTrailingWord(from: precedingText) else { return nil }
        let tail = trailing.result.word.count + trailing.trailingPunctuation.count + trailing.trailingSpaceCount
        return String(precedingText.dropLast(tail))
    }

    /// The lowercased word right before the trailing word (and its optional trailing space), used as
    /// the left context for bigram ranking. Nil at the start of the text or across sentence
    /// punctuation, where the previous word says nothing about the next one.
    static func wordBeforeTrailingWord(in precedingText: String) -> String? {
        var text = Substring(precedingText)
        // The same space `extractTrailingWord` sets aside. Skipping only a plain one would leave a
        // non-breaking space in place, and the walk below would then return the trailing word itself
        // as its own left context.
        if let last = text.last, wordFinishingSpaces.contains(last) { text = text.dropLast() }
        while let last = text.last, !last.isWhitespace { text = text.dropLast() }
        while let last = text.last, last.isWhitespace { text = text.dropLast() }
        guard let last = text.last, last.isLetter || last == "'" else { return nil }
        var start = text.endIndex
        while start > text.startIndex {
            let prior = text.index(before: start)
            if text[prior].isWhitespace { break }
            start = prior
        }
        let word = text[start...].trimmingCharacters(in: .punctuationCharacters).lowercased()
        return word.isEmpty || !word.allSatisfy({ $0.isLetter || $0 == "'" }) ? nil : word
    }

    /// Filter out tokens that are not natural-language words so we never slap a "typo" flag onto the
    /// user's variable names, URLs, mentions, or numeric values. Keep this conservative: false
    /// negatives (we miss a real typo) are fine; false positives (we flag code as a typo) are not.
    ///
    /// A token ending in punctuation (e.g. `nmae,`) is effectively rejected downstream: the spell
    /// checker's whole-word range test does not cover the trailing punctuation, so `isTypo` returns
    /// false. That keeps the "current word being typed" model intact (we only act while the caret is
    /// adjacent to the word's letters) without special-casing punctuation here.
    private static func isPlausibleNaturalWord(_ word: String) -> Bool {
        // Single letters are too noisy to act on, except the pronoun, which capitalization fixes.
        guard word.count >= 2 || word == "i" else { return false }

        let codeLikeCharacters: Set<Character> = [
            "@", "/", "\\", "_", ":", ".", "#", "<", ">",
            "(", ")", "[", "]", "{", "}",
            "$", "%", "^", "*", "=", "+", "|", "~", "`"
        ]
        for character in word {
            if character.isNumber { return false }
            if codeLikeCharacters.contains(character) { return false }
        }

        // A capital in the middle of a word after lowercase letters is an identifier
        // (`getUserName`, `isEnabled`), not prose. The first two letters are left out of the test:
        // `kKing` and `iPhone` are a Shift slip and a name, which have their own handling.
        let characters = Array(word)
        if characters.count > 2, (2..<characters.count).contains(where: { characters[$0].isUppercase && characters[$0 - 1].isLowercase }) {
            return false
        }

        // All-uppercase tokens are almost always acronyms (USA, HTTP, JSON). NSSpellChecker flags
        // many of them as typos, but correcting them is not useful here.
        let letters = word.filter { $0.isLetter }
        if !letters.isEmpty, letters.allSatisfy({ $0.isUppercase }) {
            return false
        }

        return true
    }
}

/// The exact synthetic edit needed to replace one verified trailing typo.
///
/// Keeping this as a value type lets the coordinator validate first and perform side effects second.
/// That separation matters for Accessibility-backed editors, where the field may change between the
/// original correction offer and the eventual edit.
struct TypoCorrectionReplacement: Equatable, Sendable {
    /// How many Backspace keys to post before typing `replacementText`. This is a count of keys, not
    /// of UTF-16 units and not of characters; `BackspaceKeyCount` explains why the three differ.
    let backspaceCount: Int
    let replacementText: String
}

/// How many Backspace keys delete a run of text that is already in the field.
///
/// Every edit Cotabby makes to typed text is "press Backspace N times, then type", so N decides
/// whether an edit touches only what it meant to. A host does not delete a fixed unit per key.
/// Measured with a caret after each kind of text, in an AppKit text view (`deleteBackward`) and in
/// Chromium (an editable page and a `<textarea>`):
///
/// - one Unicode scalar (`a`, `é`, `😀`): one key in both, though `😀` is two UTF-16 units.
/// - an emoji sequence (`👍🏽`, `🇺🇸`, `👨‍👩‍👧‍👦`, `1️⃣`, `❤️`): one key in both, though it is up to
///   fourteen UTF-16 units.
/// - a letter with a combining mark (`e` + U+0301), decomposed Hangul: one key in AppKit, one key
///   per scalar in Chromium.
/// - Thai and Devanagari clusters: one key per scalar in both, though Swift counts one `Character`.
///
/// So neither easy count is right. UTF-16 length is too high for every emoji, and each extra key
/// deletes a character the writer typed correctly *before* the run. `Character` count is too low
/// wherever a host deletes mark by mark, which leaves the start of the old text behind. This type
/// owns the one rule both planners need, so the measurement above lives in a single place. It exists
/// apart from the planners because they plan different edits (one word, a sentence tail) but must
/// agree exactly on this.
nonisolated enum BackspaceKeyCount {
    /// The number of Backspace keys that delete exactly `text`, or nil when that number depends on
    /// the host. A caller treats nil like a field that changed under it: it makes no edit. Missing a
    /// fix in text with decomposed accents is a small loss; a wrong count damages text.
    ///
    /// Pass the text as the field holds it now, not an earlier copy: Swift compares strings by
    /// canonical equivalence, so two strings that are `==` can still differ in how many scalars
    /// (and so how many keys) they hold.
    static func deleting(_ text: some StringProtocol) -> Int? {
        var keys = 0
        for character in text {
            let scalars = character.unicodeScalars
            guard scalars.count == 1 || isEmojiSequence(scalars) else { return nil }
            keys += 1
        }
        return keys
    }

    private static let zeroWidthJoiner: UInt32 = 0x200D
    private static let emojiVariationSelector: UInt32 = 0xFE0F
    private static let enclosingKeycap: UInt32 = 0x20E3
    /// Tag characters spell the region of a subdivision flag (England, Scotland, Wales).
    private static let tags: ClosedRange<UInt32> = 0xE0020...0xE007F

    /// Whether a cluster of several scalars is an emoji with its modifiers, the one kind every
    /// measured host deletes with a single key. Anything else of several scalars is not vouched for.
    private static func isEmojiSequence(_ scalars: Character.UnicodeScalarView) -> Bool {
        guard let base = scalars.first, base.properties.isEmoji else { return false }
        let rest = scalars.dropFirst()
        // Digits, `#` and `*` carry the emoji property only because they start a keycap (`1️⃣`). With
        // any other tail (`1` + a combining accent) they are ordinary text.
        if base.isASCII {
            return rest.last?.value == enclosingKeycap && rest.dropLast().allSatisfy { $0.value == emojiVariationSelector }
        }
        return rest.allSatisfy { scalar in
            scalar.properties.isEmoji || scalar.value == zeroWidthJoiner || scalar.value == emojiVariationSelector
                || tags.contains(scalar.value)
        }
    }
}

/// Builds a fail-closed replacement from the latest text before the caret.
///
/// Both accepted green corrections and automatic post-Space fixes use this planner. Centralizing the
/// word-match and whitespace-preservation rules prevents the two paths from drifting and accidentally
/// deleting a different word after the user continues typing.
enum TypoCorrectionReplacementPlanner {
    static func plan(
        precedingText: String,
        expectedTypo: String,
        correctedWord: String,
        requiresTrailingSpace: Bool
    ) -> TypoCorrectionReplacement? {
        let normalizedCorrection = correctedWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCorrection.isEmpty,
              normalizedCorrection != expectedTypo,
              let live = CurrentWordExtractor.extractTrailingWord(from: precedingText),
              live.result.word == expectedTypo,
              !requiresTrailingSpace || live.trailingSpaceCount == 1 else {
            return nil
        }

        let preserved = live.trailingPunctuation + live.trailingSpace
        // Counted on the word as the field holds it, not on `expectedTypo`: the two are equal as
        // strings, which does not promise the same scalars.
        guard let backspaceCount = BackspaceKeyCount.deleting(live.result.word + preserved) else { return nil }
        return TypoCorrectionReplacement(
            backspaceCount: backspaceCount,
            replacementText: normalizedCorrection + preserved
        )
    }
}
