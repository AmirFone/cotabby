import Foundation

/// File overview:
/// Chat models asked to "finish the word" usually write the whole word instead: after
/// `about the ter` they answer `terms and conditions`, not `ms and conditions`.
/// `SuggestionTextNormalizer.stripEchoPrefix` only matches whole words, so without this step the
/// ghost text would insert `terterms`. Base models continue at the byte level and never need it,
/// which is why only the cloud chat path calls this before normalization.
nonisolated enum PartialWordOverlapTrimmer {
    static func trim(_ suggestion: String, precedingText: String) -> String {
        guard let partial = trailingPartialWord(of: precedingText),
              let first = suggestion.first, !first.isWhitespace
        else { return suggestion }

        let leadingWordEnd = suggestion.firstIndex(where: { !isWordCharacter($0) }) ?? suggestion.endIndex
        let leadingWord = suggestion[..<leadingWordEnd]
        guard leadingWord.count >= partial.count,
              leadingWord.lowercased().hasPrefix(partial.lowercased())
        else { return suggestion }

        return String(suggestion.dropFirst(partial.count))
    }

    /// The letters after the last non-word character, or nil when the caret is not mid-word.
    private static func trailingPartialWord(of text: String) -> Substring? {
        guard let last = text.last, isWordCharacter(last) else { return nil }
        let start = text.lastIndex(where: { !isWordCharacter($0) }).map { text.index(after: $0) } ?? text.startIndex
        return text[start...]
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character == "'" || character == "’"
    }
}
