import Foundation

/// File overview:
/// What the word strip showed for one word, and what the writer did: the piece of the training
/// record that says whether the strip was right.
///
/// A pick alone says little. "The writer picked `throughout`" does not tell which slot it was in,
/// and every word the writer typed out themselves, with the right word sitting first in the strip
/// or missing from it, left no trace at all. `StripUseTracker` follows one word at a time and, when
/// the word is finished, hands back a `StripUse`: the words shown before any letter, the words
/// shown last, how many letters had been typed by then, and the slot picked, if one was.
///
/// Pure and small: `WordPredictionController` tells it what was shown, what the field holds, and
/// what was picked. It keeps the text before the current word and two short lists, nothing else.

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
}

nonisolated struct StripUseTracker {
    /// The text before the word being typed; nil until the first text is seen and after a reset.
    private var base: String?
    private var first: [String] = []
    private var last: [String] = []
    private var lastLetters = 0

    /// How much of the sentence so far is kept with a use.
    static let maximumBefore = 300

    /// The strip drew `words` for the field text `text`.
    mutating func shown(_ words: [String], for text: String) {
        let (textBase, prefix) = Self.split(text)
        if base != textBase {
            base = textBase
            first = []
            last = []
            lastLetters = 0
        }
        if prefix.isEmpty { first = words }
        last = words
        lastLetters = prefix.count
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
        }
        guard textBase.hasPrefix(previous) else { return nil }
        let added = textBase.dropFirst(previous.count)
        let word = added.prefix { Self.isWordCharacter($0) }
        guard !word.isEmpty, !added.dropFirst(word.count).contains(where: Self.isWordCharacter),
              !first.isEmpty || !last.isEmpty else { return nil }
        return StripUse(
            before: Self.sentenceSoFar(previous), word: String(word),
            shownFirst: first, shownLast: last, lettersTyped: lastLetters, pickedSlot: nil
        )
    }

    /// The writer picked `word` from slot `slot` of `shown`, with `textBefore` in the field (ending
    /// in the letters typed so far).
    mutating func picked(slot: Int, word: String, shown: [String], textBefore: String) -> StripUse {
        let (textBase, prefix) = Self.split(textBefore)
        let use = StripUse(
            before: Self.sentenceSoFar(textBase), word: word,
            shownFirst: base == textBase ? first : [], shownLast: shown,
            lettersTyped: prefix.count, pickedSlot: slot
        )
        reset()
        return use
    }

    mutating func reset() {
        base = nil
        first = []
        last = []
        lastLetters = 0
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
