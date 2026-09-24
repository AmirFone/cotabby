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

    private static func looksMachineReadable(_ sentence: String) -> Bool {
        let lowered = sentence.lowercased()
        if lowered.contains("http") || lowered.contains("www.") || lowered.contains("://") { return true }
        if sentence.contains(where: { "{}<>`=|\\".contains($0) }) { return true }
        return sentence.split(whereSeparator: \.isWhitespace).contains { $0.contains("@") && $0.contains(".") }
    }
}

nonisolated enum SentenceRewritePlanner {
    /// Synthetic backspace bursts much longer than this get dropped by some Electron and Chromium
    /// editors, so larger rewrites are not offered.
    static let maximumDeletedUTF16 = 120

    /// The smallest trailing edit that turns the live field into the corrected sentence, or nil when
    /// the field no longer ends with exactly the sentence that was checked.
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
        let deletedText = String(original[shared...]) + finished.trailingWhitespace
        let deleted = (deletedText as NSString).length
        guard deleted <= maximumDeletedUTF16 + finished.trailingWhitespace.utf16.count else { return nil }

        return TypoCorrectionReplacement(
            deletingUTF16Count: deleted,
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
