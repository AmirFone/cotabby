import Foundation

/// File overview:
/// What the word strip showed for one word, and what the writer did: the piece of the training
/// record that says whether the strip was right.
///
/// A pick alone says little. "The writer picked `throughout`" does not tell which slot it was in,
/// and every word the writer typed out themselves, with the right word sitting first in the strip
/// or missing from it, left no trace at all. `StripUseTracker` follows one word at a time and, when
/// the word is finished, hands back a `StripUse`: the words shown before any letter, the words
/// shown last, how many letters had been typed by then, the slot picked, if one was, and every
/// strip drawn on the way with the letters it was drawn for.
///
/// Why every strip and not only the first and last: the last strip is usually drawn when the word
/// is complete, and a complete word is never offered back, so "was the word in the last strip"
/// said no for most words whether the strip had been right three letters earlier or not. And the
/// letters matter as much as the words: a strip drawn for `hab` when `have` was meant is a
/// different failure from one drawn for `hav`.
///
/// Pure and small: `WordPredictionController` tells it what was shown, what the field holds, and
/// what was picked. It keeps the text before the current word and the strips drawn for that word.

/// One word's worth of strip history.
nonisolated struct StripUse: Equatable, Sendable {
    /// The sentence so far, before the word (empty at a sentence start).
    let before: String
    /// The word as the writer finished it, or the word picked.
    let word: String
    /// The strip before any letter of the word was typed; empty when none was shown then.
    let shownFirst: [String]
    /// The strip as it last stood for this word.
    let shownLast: [String]
    /// Letters of the word typed when `shownLast` was on screen.
    let lettersTyped: Int
    /// The slot the writer picked (0 is the first), or nil when they typed the word out.
    let pickedSlot: Int?
    /// Each strip drawn for this word, in order: the letters typed at that moment and the words
    /// shown. Empty in records from before this was kept.
    var draws: [Draw] = []

    struct Draw: Equatable, Sendable, Codable {
        /// The letters of the word typed when the strip was drawn ("" before the first).
        let typed: String
        let shown: [String]
    }
}

nonisolated struct StripUseTracker {
    /// The text before the word being typed; nil until the first text is seen and after a reset.
    private var base: String?
    private var first: [String] = []
    private var last: [String] = []
    private var lastLetters = 0
    private var draws: [StripUse.Draw] = []

    /// How much of the sentence so far is kept with a use.
    static let maximumBefore = 300
    /// More strips than any word gets letters; a word that is typed, deleted and retyped stops
    /// adding to its record here.
    static let maximumDraws = 24

    /// The strip drew `words` for the field text `text`. Returns the use of the word before, when
    /// this strip is the first for a new word.
    ///
    /// The strip is drawn from the key, before the field is read (`WordPredictionController
    /// .predictAhead`), so the strip for the next word arrives here before `typed` hears that the
    /// word before it is finished. This used to start the new word's record and throw the old
    /// one away unreported, which lost the strip record of nine words in ten.
    mutating func shown(_ words: [String], for text: String) -> StripUse? {
        let finished = typed(text)
        let (textBase, prefix) = Self.split(text)
        base = textBase
        if prefix.isEmpty { first = words }
        last = words
        lastLetters = prefix.count
        if draws.last != StripUse.Draw(typed: prefix, shown: words), draws.count < Self.maximumDraws {
            draws.append(.init(typed: prefix, shown: words))
        }
        return finished
    }

    /// The field now holds `text`. Returns the finished word's use when exactly one word was
    /// completed since the last call and a strip had been shown for it; nil while a word is still
    /// being typed, and after any other change (a deletion, a paste, another field), which simply
    /// starts over from the new text.
    mutating func typed(_ text: String) -> StripUse? {
        let (textBase, _) = Self.split(text)
        guard let previous = base else {
            base = textBase
            return nil
        }
        guard textBase != previous else { return nil }
        defer {
            base = textBase
            first = []
            last = []
            lastLetters = 0
            draws = []
        }
        guard textBase.hasPrefix(previous) else { return nil }
        let added = textBase.dropFirst(previous.count)
        let word = added.prefix { Self.isWordCharacter($0) }
        guard !word.isEmpty, !added.dropFirst(word.count).contains(where: Self.isWordCharacter),
              !first.isEmpty || !last.isEmpty else { return nil }
        return StripUse(
            before: Self.sentenceSoFar(previous), word: String(word),
            shownFirst: first, shownLast: last, lettersTyped: lastLetters, pickedSlot: nil, draws: draws
        )
    }

    /// The writer picked `word` from slot `slot` of `shown`, with `textBefore` in the field (ending
    /// in the letters typed so far).
    mutating func picked(slot: Int, word: String, shown: [String], textBefore: String) -> StripUse {
        let (textBase, prefix) = Self.split(textBefore)
        let use = StripUse(
            before: Self.sentenceSoFar(textBase), word: word,
            shownFirst: base == textBase ? first : [], shownLast: shown,
            lettersTyped: prefix.count, pickedSlot: slot, draws: base == textBase ? draws : []
        )
        reset()
        return use
    }

    mutating func reset() {
        base = nil
        first = []
        last = []
        lastLetters = 0
        draws = []
    }

    /// The text before the word in progress, and the letters of that word.
    private static func split(_ text: String) -> (base: String, prefix: String) {
        var start = text.endIndex
        while start > text.startIndex {
            let previous = text.index(before: start)
            guard isWordCharacter(text[previous]) else { break }
            start = previous
        }
        return (String(text[..<start]), String(text[start...]))
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character == "'" || character == "’"
    }

    /// The part of `text` after its last sentence end, without the space that follows it.
    static func sentenceSoFar(_ text: String) -> String {
        let start = text.lastIndex { ".!?\n".contains($0) }.map { text.index(after: $0) } ?? text.startIndex
        let sentence = text[start...].drop { $0.isWhitespace }
        return String(sentence.suffix(maximumBefore)).trimmingCharacters(in: .whitespaces)
    }
}
