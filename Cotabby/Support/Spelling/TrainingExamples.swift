import Foundation

/// File overview:
/// The pure half of the training record (`Services/Spelling/TrainingLog.swift` is the file half).
///
/// While the writer types, the log only appends small events as they happen: a sentence that was
/// finished and left standing, a word that was fixed or kept, a sentence fix that was kept or
/// undone. Nothing is worked out on the typing path. This file turns that stream into what a
/// spelling model is trained on: one example per sentence with the sentence as first typed, the
/// sentence as it ended up, and the fixes the writer accepted and rejected.
///
/// Why the examples are built at export time and not as the events arrive: the events for one
/// sentence do not arrive in order. A sentence fix is confirmed only when the writer types on, which
/// can be after the sentence was recorded, and an undo replaces a sentence that was already
/// written down. Joining once, over the whole stream, needs no amending of the file.

/// One line of the training log.
nonisolated enum TrainingLogEvent: Equatable, Sendable {
    /// A finished sentence that was still in the field, as written, a moment later. `day` is a
    /// calendar date (`2026-11-15`); the time of day is deliberately not kept.
    case sentence(text: String, day: String)
    /// What happened to one word. `how` is a `CorrectionJournal.Kind` raw value; `offered` is the
    /// fix the writer turned down, when there was one.
    case word(how: String, typed: String, final: String, offered: String?)
    /// A fix made to a whole finished sentence, kept (the writer typed on) or undone.
    case sentenceFix(original: String, corrected: String, kept: Bool)

    /// The event as the JSON object written to the file.
    var json: [String: Any] {
        switch self {
        case let .sentence(text, day):
            return ["event": "sentence", "text": text, "day": day]
        case let .word(how, typed, final, offered):
            var object = ["event": "word", "how": how, "typed": typed, "final": final]
            if let offered { object["offered"] = offered }
            return object
        case let .sentenceFix(original, corrected, kept):
            return ["event": "sentenceFix", "original": original, "corrected": corrected, "kept": kept]
        }
    }

    /// Nil for a line this build does not understand, which the builder then skips: a file written
    /// by a newer build must not make an export fail.
    init?(json: [String: Any]) {
        switch json["event"] as? String {
        case "sentence":
            guard let text = json["text"] as? String, let day = json["day"] as? String else { return nil }
            self = .sentence(text: text, day: day)
        case "word":
            guard let how = json["how"] as? String, let typed = json["typed"] as? String,
                  let final = json["final"] as? String else { return nil }
            self = .word(how: how, typed: typed, final: final, offered: json["offered"] as? String)
        case "sentenceFix":
            guard let original = json["original"] as? String, let corrected = json["corrected"] as? String,
                  let kept = json["kept"] as? Bool else { return nil }
            self = .sentenceFix(original: original, corrected: corrected, kept: kept)
        default:
            return nil
        }
    }
}

/// One exported training example. The field names are the file format: `typed` is the model's input,
/// `final` its target, and `accepted` / `rejected` say which changes the writer agreed with.
nonisolated struct TrainingExample: Codable, Equatable, Sendable {
    struct Change: Codable, Equatable, Sendable {
        /// The word as the writer typed it.
        let typed: String
        /// What it was changed to (accepted) or what was offered and turned down (rejected); nil
        /// when the writer kept their word and the offer was not recorded.
        let fix: String?
        /// Accepted: `autoFix` (changed for the writer, who typed on), `picked` (chosen from the bar
        /// or card), `selfCorrected` (retyped by the writer), `sentenceFix` (changed when the
        /// sentence was finished). Rejected: `autoFix` or `sentenceFix` that was undone, or
        /// `offered` (the writer kept their word from the bar or card).
        let how: String
    }

    /// `sentence`, or `word` for a fix that could not be placed in a recorded sentence.
    let scope: String
    let day: String?
    let typed: String
    let final: String
    let accepted: [Change]
    let rejected: [Change]
}

nonisolated enum TrainingExampleBuilder {
    /// The examples for a stream of log events, in the order the sentences were written.
    static func examples(from events: [TrainingLogEvent]) -> [TrainingExample] {
        var assembly = Assembly()
        for event in events {
            switch event {
            case let .word(how, typed, final, offered):
                assembly.pendingWords.append(WordEvent(how: how, typed: typed, final: final, offered: offered))
            case let .sentence(text, day):
                assembly.addSentence(text, day: day)
            case let .sentenceFix(original, corrected, kept):
                if kept {
                    assembly.noteKeptFix(original: original, corrected: corrected)
                } else {
                    assembly.noteUndoneFix(original: original, corrected: corrected)
                }
            }
        }
        return (assembly.drafts + assembly.pendingWords.map(Draft.init(word:))).map(\.example)
    }

    /// The examples being put together while the events are read in order.
    private struct Assembly {
        var drafts: [Draft] = []
        /// Word events since the last sentence, waiting for the sentence they belong to.
        var pendingWords: [WordEvent] = []
        /// Sentence-fix outcomes that arrived before the sentence they belong to was recorded.
        private var keptFixes: [String: String] = [:]
        private var undoneFixes: [String: String] = [:]

        mutating func addSentence(_ text: String, day: String) {
            var draft = Draft(final: text, day: day)
            draft.beforeSentenceFix = keptFixes.removeValue(forKey: text)
            draft.undoneSentenceFix = undoneFixes.removeValue(forKey: text)
            drafts.append(draft)
            // A word event belongs to the sentence recorded after it; one that only fits the
            // sentence before (its outcome was settled late) goes there instead.
            for word in pendingWords {
                if TrainingExampleBuilder.attach(word, to: &drafts, at: drafts.count - 1) { continue }
                if drafts.count >= 2, TrainingExampleBuilder.attach(word, to: &drafts, at: drafts.count - 2) { continue }
                drafts.insert(Draft(word: word), at: drafts.count - 1)
            }
            pendingWords = []
        }

        mutating func noteKeptFix(original: String, corrected: String) {
            if let index = drafts.lastIndex(where: { $0.final == corrected && $0.beforeSentenceFix == nil }) {
                drafts[index].beforeSentenceFix = original
            } else {
                keptFixes[corrected] = original
            }
        }

        /// The corrected sentence may have been written down before the writer undid it; it is not
        /// what they meant. Its word events go back in line for the sentence as written.
        mutating func noteUndoneFix(original: String, corrected: String) {
            if let index = drafts.lastIndex(where: { $0.final == corrected && !$0.isWordOnly }) {
                pendingWords = drafts[index].words + pendingWords
                drafts.remove(at: index)
            }
            if let index = drafts.lastIndex(where: { $0.final == original && !$0.isWordOnly }) {
                drafts[index].undoneSentenceFix = corrected
            } else {
                undoneFixes[original] = corrected
            }
        }
    }

    /// One JSON object per line, keys sorted so two exports of the same log are identical.
    static func jsonLines(_ examples: [TrainingExample]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return examples.compactMap { try? encoder.encode($0) }.reduce(into: Data()) { $0 += $1 + Data("\n".utf8) }
    }

    private struct WordEvent {
        let how: String
        let typed: String
        let final: String
        let offered: String?

        /// The writer ended up with their own word: an undone automatic fix, or a word kept from
        /// the bar or card.
        var isRejection: Bool { typed == final }
    }

    private struct Draft {
        var final: String
        var day: String?
        var words: [WordEvent] = []
        /// The sentence before a sentence fix the writer kept.
        var beforeSentenceFix: String?
        /// What a sentence fix would have made of this sentence, had the writer not undone it.
        var undoneSentenceFix: String?
        var isWordOnly = false

        init(final: String, day: String) {
            self.final = final
            self.day = day
        }

        init(word: WordEvent) {
            final = word.final
            words = [word]
            isWordOnly = true
        }

        var example: TrainingExample {
            var accepted: [TrainingExample.Change] = []
            var rejected: [TrainingExample.Change] = []
            // Word-level fixes happened first, while the sentence was being typed, so they are
            // undone last: start from the sentence as it stood before any sentence fix.
            var typed = beforeSentenceFix ?? final
            for word in words {
                if word.isRejection {
                    let how = word.how == CorrectionJournal.Kind.autoFixUndone.rawValue ? "autoFix" : "offered"
                    rejected.append(.init(typed: word.typed, fix: word.offered, how: how))
                } else {
                    accepted.append(.init(typed: word.typed, fix: word.final, how: Self.acceptedHow(word.how)))
                    if !isWordOnly, let range = TrainingExampleBuilder.wholeWordRange(of: word.final, in: typed) {
                        typed.replaceSubrange(range, with: word.typed)
                    }
                }
            }
            if isWordOnly { typed = words.first?.typed ?? final }
            if let beforeSentenceFix {
                accepted += TrainingExampleBuilder.changedWords(from: beforeSentenceFix, to: final)
                    .map { .init(typed: $0.typed, fix: $0.fixed, how: "sentenceFix") }
            }
            if let undoneSentenceFix {
                rejected += TrainingExampleBuilder.changedWords(from: final, to: undoneSentenceFix)
                    .map { .init(typed: $0.typed, fix: $0.fixed, how: "sentenceFix") }
            }
            return TrainingExample(
                scope: isWordOnly ? "word" : "sentence", day: day, typed: typed, final: final,
                accepted: accepted, rejected: rejected
            )
        }

        private static func acceptedHow(_ journalKind: String) -> String {
            switch CorrectionJournal.Kind(rawValue: journalKind) {
            case .autoFixKept: return "autoFix"
            case .selfCorrected: return "selfCorrected"
            default: return "picked"
            }
        }
    }

    /// Adds the event to the draft at `index` when its word is in that sentence. An accepted fix is
    /// looked for by what the word became, a rejected one by the word the writer kept.
    private static func attach(_ word: WordEvent, to drafts: inout [Draft], at index: Int) -> Bool {
        let draft = drafts[index]
        guard !draft.isWordOnly, wholeWordRange(of: word.final, in: draft.beforeSentenceFix ?? draft.final) != nil else {
            return false
        }
        drafts[index].words.append(word)
        return true
    }

    /// The first place `word` stands in `text` with no letter or digit against either end, so `the`
    /// is not found inside `other`. `word` may itself be two words (`next door`).
    private static func wholeWordRange(of word: String, in text: String) -> Range<String.Index>? {
        guard !word.isEmpty else { return nil }
        var searchStart = text.startIndex
        while let range = text.range(of: word, range: searchStart..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !isWordCharacter(before), !isWordCharacter(after) { return range }
            searchStart = text.index(after: range.lowerBound)
        }
        return nil
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        character.map { $0.isLetter || $0.isNumber } ?? false
    }

    /// The words that differ between two versions of a sentence, in the casing they were written.
    /// Empty when the versions do not have the same number of words (a word was split or joined):
    /// the sentence pair still carries the change, it is only not itemized.
    private static func changedWords(from original: String, to changed: String) -> [(typed: String, fixed: String)] {
        let before = original.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters) }
        let after = changed.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters) }
        guard before.count == after.count else { return [] }
        return zip(before, after).filter { $0 != $1 && !$0.isEmpty && !$1.isEmpty }.map { (typed: $0, fixed: $1) }
    }
}
