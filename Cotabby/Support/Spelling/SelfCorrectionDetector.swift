import Foundation

/// File overview:
/// Notices the writer fixing a word themselves: they finish a word, go back over it, and type a
/// different word in the same place (`I saw becuase ` → `I saw because `). That is the clearest
/// signal of what they meant, and it arrives with no bar, card, or question. The coordinator feeds
/// every settled read of the field here and records what it reports as an accepted correction, so
/// the next `becuase` is fixed without the writer doing it.
///
/// Only the most recently finished word is watched, which covers the common case of catching a
/// mistake right away. Pure and value-typed; the caller resets it whenever Cotabby itself edited the
/// field, so the app's own fixes are never mistaken for the writer's.
nonisolated struct SelfCorrectionDetector {
    struct Correction: Equatable {
        let typed: String
        let corrected: String
    }

    private var finished: (textBefore: String, word: String)?

    mutating func reset() {
        finished = nil
    }

    /// Reads the text before the caret; returns a correction when the watched word was replaced by
    /// a different finished word. `isPlausible` decides whether the pair looks like a fix (a typo
    /// becoming a real, similar word) rather than a change of mind.
    mutating func observe(_ text: String, isPlausible: (_ typed: String, _ corrected: String) -> Bool) -> Correction? {
        var result: Correction?
        if let watched = finished {
            if text.hasPrefix(watched.textBefore) {
                let rest = text.dropFirst(watched.textBefore.count)
                let word = rest.prefix(while: Self.isWordCharacter)
                if !word.isEmpty, rest.count > word.count, word.lowercased() != watched.word.lowercased() {
                    finished = nil
                    if isPlausible(watched.word, String(word)) {
                        result = Correction(typed: watched.word, corrected: String(word))
                    }
                }
            } else {
                finished = nil
            }
        }
        // While the writer is deleting back over the watched word (even past it, down to the word
        // before), keep watching it; only moving forward past it changes the watch.
        let isDeletingBack = finished.map { ($0.textBefore + $0.word + " ").hasPrefix(text) } ?? false
        if !isDeletingBack, let latest = Self.trailingFinishedWord(in: text) {
            finished = latest
        }
        return result
    }

    /// A retyped word counts as a fix when the first spelling was not a word, the second is, and
    /// they are close (a few edits apart, or sounding alike): `becuase` → because, not `cat` → dog.
    static func isPlausibleFix(typed: String, corrected: String, isWord: (String) -> Bool) -> Bool {
        let from = typed.lowercased()
        let to = corrected.lowercased()
        guard !isWord(from), isWord(to) else { return false }
        if PhoneticKey.vowelKey(for: from) == PhoneticKey.vowelKey(for: to), !PhoneticKey.vowelKey(for: to).isEmpty {
            return true
        }
        return editDistance(Array(from), Array(to)) <= max(2, to.count / 3)
    }

    /// Plain Levenshtein distance; words are short, so the full table is cheap.
    static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var previous = Array(0...rhs.count)
        for (row, left) in lhs.enumerated() {
            var current = [row + 1] + Array(repeating: 0, count: rhs.count)
            for (column, right) in rhs.enumerated() {
                current[column + 1] = min(previous[column + 1] + 1, current[column] + 1, previous[column] + (left == right ? 0 : 1))
            }
            previous = current
        }
        return previous[rhs.count]
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character == "'" || character == "’"
    }

    /// The last word when the text ends with that word and one space, with the text before it.
    private static func trailingFinishedWord(in text: String) -> (textBefore: String, word: String)? {
        guard text.last == " " else { return nil }
        let body = text.dropLast()
        let word = body.reversed().prefix(while: isWordCharacter)
        guard word.count >= 2 else { return nil }
        let textBefore = body.dropLast(word.count)
        guard textBefore.isEmpty || textBefore.last?.isWhitespace == true else { return nil }
        return (String(textBefore), String(word.reversed()))
    }
}
