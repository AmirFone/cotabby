import Foundation

/// File overview:
/// The writer's own words in the text being written: a colleague's name, a project name, a term of
/// the trade. None of them is in any dictionary, so the strip could never offer them, and they are
/// exactly the words a writer types again and again in the same message.
///
/// `TextVocabulary.read` finds them in the text the language model reads. `WordLanguageModelCore`
/// asks the model how likely each is to come next (a model that has just read `Priyanka` twice
/// expects it a third time) and the strip offers them, spelled and capitalized as the writer did.
///
/// Pure: it sees only the text and a "is this a dictionary word" test, so tests need no model.
nonisolated enum TextVocabulary {
    /// One word to offer or to respell.
    struct Word: Equatable, Sendable {
        /// As the writer wrote it: `Priyanka`, `cutover`, `ETL`.
        let display: String
        let lowercased: String
        /// False for a dictionary word that only gets its capital from here (`Dana`, `Lantern`).
        let isNew: Bool
    }

    /// Shorter strings are initials and fragments, not words worth a slot.
    static let minimumLength = 3
    /// The most recent words kept; a text rarely has more of its own than this.
    static let maximumWords = 24

    /// The words of `text` to offer that the dictionary lacks, and the dictionary words the writer
    /// capitalizes, most recently used last.
    ///
    /// A word the dictionary lacks is offered when the writer used it capitalized inside a sentence
    /// (a name, an acronym), or used it twice. Once in lowercase is more often a slip the writer has
    /// not corrected yet, and offering that back would teach the mistake.
    ///
    /// A dictionary word is respelled with a capital when the writer capitalized it inside a
    /// sentence twice and never wrote it in lowercase: then it is a name here (`Dana`, the project
    /// `Lantern`), whatever else it means.
    static func read(_ text: String, isKnown: (String) -> Bool) -> [Word] {
        let (uses, order) = uses(in: text)
        let words = order.compactMap { lowercased -> Word? in
            guard let use = uses[lowercased] else { return nil }
            if isKnown(lowercased) {
                guard use.lowercase == 0, use.capitalInside >= 2, let display = use.insideForm else { return nil }
                return Word(display: display, lowercased: lowercased, isNew: false)
            }
            guard use.capitalInside >= 1 || use.total >= 2 else { return nil }
            return Word(display: use.display(fallback: lowercased), lowercased: lowercased, isNew: true)
        }
        return Array(words.suffix(maximumWords))
    }

    /// How every word of at least `minimumLength` letters was written, and the words in order of
    /// their last use.
    private static func uses(in text: String) -> (uses: [String: Uses], order: [String]) {
        var uses: [String: Uses] = [:]
        var lastUse: [String: Int] = [:]
        var position = 0
        var startsSentence = true
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character.isLetter else {
                if ".!?\n".contains(character) { startsSentence = true }
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, text[end].isLetter { end = text.index(after: end) }
            let raw = String(text[index..<end])
            // `Priyanka's` counts as a use of `Priyanka`; the ending is skipped, not read as a word.
            var ending = Substring()
            if end < text.endIndex, text[end] == "'" || text[end] == "’" {
                let endingStart = text.index(after: end)
                end = endingStart
                while end < text.endIndex, text[end].isLetter { end = text.index(after: end) }
                ending = text[endingStart..<end]
            }
            // `didn't` is not `didn` with an ending: the `n` belongs to `n't`, and what is left
            // before the apostrophe (`didn`, `wouldn`, `isn`) is in no dictionary. Read as a word
            // it looked like a term of the writer's after two uses, or after one in capitals, and
            // the strip offered it. Every other ending (`'s`, `'ll`, `'re`, `'ve`, `'d`) follows a
            // whole word, so only this one is left out.
            let isNegativeContraction = ending.lowercased() == "t" && raw.last?.lowercased() == "n"
            if raw.count >= minimumLength, !isNegativeContraction {
                let lowercased = raw.lowercased()
                uses[lowercased, default: Uses()].note(raw, startsSentence: startsSentence)
                lastUse[lowercased] = position
                position += 1
            }
            startsSentence = false
            index = end
        }
        return (uses, lastUse.sorted { $0.value < $1.value }.map(\.key))
    }

    /// How one word was written across the text.
    private struct Uses {
        var total = 0
        var lowercase = 0
        /// Capitalized (or all capitals) where a sentence was not starting.
        var capitalInside = 0
        var insideForm: String?
        var startForm: String?

        mutating func note(_ raw: String, startsSentence: Bool) {
            total += 1
            if raw == raw.lowercased() {
                lowercase += 1
            } else if startsSentence {
                startForm = startForm ?? raw
            } else {
                capitalInside += 1
                insideForm = insideForm ?? raw
            }
        }

        /// Lowercase if the writer ever wrote it so; else the capitals they gave it inside a
        /// sentence; else what stood at a sentence start, which is all there is to go on.
        func display(fallback lowercased: String) -> String {
            if lowercase > 0 { return lowercased }
            return insideForm ?? startForm ?? lowercased
        }
    }
}
