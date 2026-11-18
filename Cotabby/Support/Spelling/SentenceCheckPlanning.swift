import Foundation

/// File overview:
/// Pure rules for the per-sentence spelling and grammar check: which text counts as "a sentence the
/// writer just finished", the smallest keystroke edit that swaps in a corrected version, and the
/// word-level diff the card highlights. `SentenceCheckController` owns timing, networking, and UI;
/// everything here is deterministic so it can be tested without a text field or a server.

/// The sentence immediately before the caret, captured at the moment it was finished.
nonisolated struct FinishedSentence: Equatable, Sendable {
    let sentence: String
    /// Whitespace typed after the sentence (the Space or Return that finished it).
    let trailingWhitespace: String
    /// Up to a few hundred characters before the sentence, sent as read-only context.
    let precedingContext: String
}

nonisolated enum FinishedSentenceExtractor {
    static let minimumWords = 3
    static let maximumWords = 40
    static let maximumCharacters = 320
    private static let precedingContextCharacters = 400

    /// Returns the sentence the writer just finished, or nil when the caret is not right after a
    /// sentence end, the sentence is too short or long to be worth a request, or it looks like code,
    /// a URL, or an email address that a grammar model would mangle.
    static func extract(from precedingText: String) -> FinishedSentence? {
        guard let last = precedingText.last, last.isWhitespace else { return nil }
        let body = precedingText.trimmingTrailingWhitespace()
        let trailingWhitespace = String(precedingText.dropFirst(body.count))
        guard trailingWhitespace.count <= 2, SentenceBoundaryClassifier.endsSentence(body) else { return nil }

        let start = sentenceStart(in: body)
        let sentence = String(body[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let words = sentence.split(whereSeparator: \.isWhitespace)
        guard (minimumWords...maximumWords).contains(words.count),
              sentence.count <= maximumCharacters,
              !looksMachineReadable(sentence) else { return nil }

        let sentenceStartIndex = body.index(body.endIndex, offsetBy: -sentence.count)
        return FinishedSentence(
            sentence: sentence,
            trailingWhitespace: trailingWhitespace,
            precedingContext: String(body[..<sentenceStartIndex].suffix(precedingContextCharacters))
        )
    }

    /// Walks back past the sentence's own terminal punctuation to the previous sentence end or line
    /// break. Abbreviation-aware so `Dr. Smith arrived.` stays one sentence.
    private static func sentenceStart(in body: String) -> String.Index {
        var index = body.index(before: body.endIndex)
        while index > body.startIndex, body[index].isSentenceTerminalOrClosing {
            index = body.index(before: index)
        }
        while index > body.startIndex {
            let previous = body.index(before: index)
            let character = body[previous]
            if character.isNewline { return index }
            // Punctuation ends the previous sentence only when a space follows it, so `example.com`
            // and `3.5` never split a sentence.
            if body[index].isWhitespace {
                if character == "!" || character == "?" { return index }
                if character == ".", SentenceBoundaryClassifier.isTerminalPeriod(in: body, at: previous) { return index }
            }
            index = previous
        }
        return body.startIndex
    }

    /// Text with a web address, an email address, or code in it. Internal because the training
    /// record uses the same test for lines that never pass through `extract` (a chat line sent with
    /// Return): such text is neither prose to train on nor something to keep a copy of.
    static func looksMachineReadable(_ sentence: String) -> Bool {
        let lowered = sentence.lowercased()
        if lowered.contains("http") || lowered.contains("www.") || lowered.contains("://") { return true }
        if sentence.contains(where: { "{}<>`=|\\".contains($0) }) { return true }
        return sentence.split(whereSeparator: \.isWhitespace).contains { $0.contains("@") && $0.contains(".") }
    }
}

nonisolated enum SentenceRewritePlanner {
    /// Synthetic backspace bursts much longer than this get dropped by some Electron and Chromium
    /// editors, so larger rewrites are not offered.
    static let maximumBackspaces = 120

    /// The smallest trailing edit that turns the live field into the corrected sentence, or nil when
    /// the field no longer ends with exactly the sentence that was checked, or when the tail to
    /// delete holds text whose Backspace count depends on the host (see `BackspaceKeyCount`).
    ///
    /// Only the text from the first changed character onward is retyped, so fixing one word near the
    /// end deletes a few characters instead of the whole sentence.
    static func plan(
        precedingText: String,
        finished: FinishedSentence,
        corrected: String
    ) -> TypoCorrectionReplacement? {
        let expectedTail = finished.sentence + finished.trailingWhitespace
        guard precedingText.hasSuffix(expectedTail) else { return nil }

        let original = Array(finished.sentence)
        let replacement = Array(corrected.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !replacement.isEmpty, replacement != original else { return nil }

        var shared = 0
        while shared < original.count, shared < replacement.count, original[shared] == replacement[shared] {
            shared += 1
        }
        // The tail is read back from the live field and counted in Backspace keys. The prefix above
        // is shared by character, and an emoji in the tail is one character and one key but two or
        // more UTF-16 units: counting units sent extra keys that deleted the end of the shared
        // prefix, which is text this plan promised not to touch.
        let deletedCharacters = original.count - shared + finished.trailingWhitespace.count
        guard let backspaceCount = BackspaceKeyCount.deleting(precedingText.suffix(deletedCharacters)),
              backspaceCount <= maximumBackspaces + finished.trailingWhitespace.count else { return nil }

        return TypoCorrectionReplacement(
            backspaceCount: backspaceCount,
            replacementText: String(replacement[shared...]) + finished.trailingWhitespace
        )
    }
}

/// A word of the corrected sentence, flagged when it differs from what the writer typed.
nonisolated struct SentenceFixSegment: Equatable, Sendable {
    let text: String
    let isChanged: Bool
    /// A change the writer should review (dotted underline) rather than a confident fix (green).
    var isSuggestion = false
}

/// What happened to a sentence the local pass fixed on its own, read from the field afterwards.
/// Mirrors `AutoFixOutcomeTracker` for single words: typing on confirms the fixes, the original
/// sentence coming back (Cmd+Z) rejects them.
nonisolated struct SentenceFixOutcomeTracker {
    enum Outcome: Equatable {
        case confirmed(original: String, corrected: String)
        case reverted(original: String, corrected: String)
    }

    private struct Pending {
        let original: String
        let corrected: String
        /// Field length once the corrected sentence was first seen; nil until then.
        var settledLength: Int?
    }

    /// Characters the writer must type past a fixed sentence before its fixes count as accepted.
    static let confirmationCharacters = 8

    private var pending: [Pending] = []

    mutating func noteApplied(original: String, corrected: String) {
        pending.append(Pending(original: original, corrected: corrected))
        if pending.count > 4 { pending.removeFirst() }
    }

    mutating func observe(_ precedingText: String) -> [Outcome] {
        var outcomes: [Outcome] = []
        pending = pending.compactMap { item in
            var item = item
            let hasCorrected = precedingText.contains(item.corrected)
            if precedingText.contains(item.original), !hasCorrected {
                // Undone means it was there and is gone again. The original still standing before
                // the corrected sentence was ever seen is a fix that has not landed yet, or never
                // did (its keys were lost): the writer undid nothing, and calling it undone would
                // mark their slip as a word they meant.
                guard item.settledLength != nil else { return item }
                outcomes.append(.reverted(original: item.original, corrected: item.corrected))
                return nil
            }
            guard hasCorrected else {
                return item.settledLength == nil ? item : nil
            }
            let settled = item.settledLength ?? precedingText.count
            if precedingText.count >= settled + Self.confirmationCharacters {
                outcomes.append(.confirmed(original: item.original, corrected: item.corrected))
                return nil
            }
            item.settledLength = settled
            return item
        }
        return outcomes
    }

    /// Word-for-word spelling changes between two versions of a sentence, lowercased and without
    /// surrounding punctuation. Capitalization and punctuation fixes are not spelling, so they are
    /// left out. Only same-length sentences pair up; a fix that merged or split words is skipped.
    static func wordChanges(original: String, corrected: String) -> [(typed: String, fixed: String)] {
        let before = original.split(whereSeparator: \.isWhitespace).map(normalized)
        let after = corrected.split(whereSeparator: \.isWhitespace).map(normalized)
        guard before.count == after.count else { return [] }
        return zip(before, after).filter { $0 != $1 && !$0.isEmpty && !$1.isEmpty }
    }

    private static func normalized(_ word: Substring) -> String {
        word.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }
}

nonisolated enum SentenceWordDiff {
    /// Longest-common-subsequence diff over words; sentences are capped at 40 words, so the table
    /// stays tiny.
    static func segments(original: String, corrected: String, asSuggestions: Bool) -> [SentenceFixSegment] {
        segments(original: original, corrected: corrected).map {
            SentenceFixSegment(text: $0.text, isChanged: $0.isChanged, isSuggestion: $0.isChanged && asSuggestions)
        }
    }

    static func segments(original: String, corrected: String) -> [SentenceFixSegment] {
        let before = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let after = corrected.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !after.isEmpty else { return [] }
        guard !before.isEmpty else { return after.map { SentenceFixSegment(text: $0, isChanged: true) } }

        var table = Array(repeating: Array(repeating: 0, count: after.count + 1), count: before.count + 1)
        for row in stride(from: before.count - 1, through: 0, by: -1) {
            for col in stride(from: after.count - 1, through: 0, by: -1) {
                table[row][col] = before[row] == after[col]
                    ? table[row + 1][col + 1] + 1
                    : max(table[row + 1][col], table[row][col + 1])
            }
        }

        var segments: [SentenceFixSegment] = []
        var row = 0
        var col = 0
        while col < after.count {
            if row < before.count, before[row] == after[col] {
                segments.append(SentenceFixSegment(text: after[col], isChanged: false))
                row += 1
                col += 1
            } else if row < before.count, table[row + 1][col] >= table[row][col + 1] {
                row += 1
            } else {
                segments.append(SentenceFixSegment(text: after[col], isChanged: true))
                col += 1
            }
        }
        return segments
    }
}

private extension Character {
    var isSentenceTerminalOrClosing: Bool {
        ".!?\"'”’)]".contains(self)
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var view = Substring(self)
        while let last = view.last, last.isWhitespace {
            view = view.dropLast()
        }
        return String(view)
    }
}
