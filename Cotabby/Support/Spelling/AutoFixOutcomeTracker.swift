import Foundation

/// File overview:
/// Decides, from the text the writer goes on to type, whether an automatic fix was right. An auto-fix
/// is only a guess until the writer reacts: typing on past the fixed word confirms it, while the
/// original spelling coming back (Cmd+Z, or deleting the fix and retyping the word) rejects it.
///
/// Recording a fix as accepted the moment it is applied would let a wrong fix teach itself: the
/// personal history would boost the very correction the writer keeps undoing. So the coordinator
/// hands each auto-fix here and only records the outcome this tracker reports. Pure and value-typed,
/// so the rules are testable without a text field.

/// How the writer reacted to one automatic fix.
nonisolated struct AutoFixOutcome: Equatable {
    enum Kind: Equatable {
        /// The writer kept typing after the fix.
        case confirmed
        /// The typed spelling is back where the fix was.
        case reverted
    }

    let kind: Kind
    let typo: String
    let fix: String
}

nonisolated struct AutoFixOutcomeTracker {
    private struct Pending {
        let typo: String
        let fix: String
        /// Everything before the fixed word, as it was when the fix landed.
        let textBefore: String
    }

    /// Fixes waiting for a verdict; a writer rarely has more than one or two in flight.
    static let maximumPending = 4

    private var pending: [Pending] = []

    var pendingCount: Int { pending.count }

    /// `precedingText` is the field before the caret right before the fix, ending in the typo and
    /// the space that triggered it.
    /// Capitalization fixes (`it` → `It`) are not tracked: the words match without case, so the fix
    /// would read as undone the moment it landed.
    mutating func noteAutoFix(typo: String, fix: String, precedingText: String) {
        guard typo.lowercased() != fix.lowercased() else { return }
        let trimmed = precedingText.reversed().drop { $0.isWhitespace }
        let word = String(trimmed.prefix(typo.count).reversed())
        guard word.caseInsensitiveCompare(typo) == .orderedSame else { return }
        let textBefore = String(trimmed.dropFirst(typo.count).reversed())
        pending.append(Pending(typo: typo.lowercased(), fix: fix.lowercased(), textBefore: textBefore))
        if pending.count > Self.maximumPending { pending.removeFirst() }
    }

    /// Reads the latest text before the caret and returns the fixes it settles. A fix whose earlier
    /// text was edited, or whose field changed, is dropped without a verdict.
    mutating func observe(_ precedingText: String) -> [AutoFixOutcome] {
        var outcomes: [AutoFixOutcome] = []
        pending.removeAll { item in
            guard precedingText.hasPrefix(item.textBefore) else { return true }
            let rest = precedingText.dropFirst(item.textBefore.count)
            let word = rest.prefix { $0.isLetter || $0 == "'" || $0 == "’" }.lowercased()
            let wordIsFinished = rest.count > word.count
            if word == item.typo, wordIsFinished {
                outcomes.append(AutoFixOutcome(kind: .reverted, typo: item.typo, fix: item.fix))
                return true
            }
            if word == item.fix, Self.hasFinishedAnotherWord(after: rest.dropFirst(word.count)) {
                outcomes.append(AutoFixOutcome(kind: .confirmed, typo: item.typo, fix: item.fix))
                return true
            }
            return false
        }
        return outcomes
    }

    /// At least one complete word follows (letters, then a space or punctuation).
    private static func hasFinishedAnotherWord(after tail: Substring) -> Bool {
        var sawLetters = false
        for character in tail {
            if character.isLetter {
                sawLetters = true
            } else if sawLetters {
                return true
            }
        }
        return false
    }
}
