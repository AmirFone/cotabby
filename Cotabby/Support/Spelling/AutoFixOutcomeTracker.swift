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
        /// Another word stands where the fix was: neither what was typed nor what Cotabby made of
        /// it. The fix was wrong and the writer put in what they meant (`replacement`).
        case replaced
    }

    let kind: Kind
    let typo: String
    let fix: String
    /// The word the writer put in the fix's place; only for `.replaced`.
    var replacement: String?
}

nonisolated struct AutoFixOutcomeTracker {
    private struct Pending {
        let typo: String
        let fix: String
        /// Everything before the fixed word, as it was when the fix landed.
        let textBefore: String
        /// The field the fix was made in (its focus sequence), so text in another field that
        /// happens to begin the same way is never read as a verdict on this fix.
        var field: UInt64 = 0
        /// True once the field has been seen holding the fix. Until then the typo still standing
        /// is the text from before the fix, not the writer putting it back.
        var wasSeen = false
    }

    /// Fixes waiting for a verdict; a writer rarely has more than one or two in flight.
    static let maximumPending = 4

    private var pending: [Pending] = []

    var pendingCount: Int { pending.count }

    /// `precedingText` is the field before the caret right before the fix, ending in the typo and
    /// the space that triggered it.
    /// Capitalization fixes (`it` → `It`) are not tracked: the words match without case, so the fix
    /// would read as undone the moment it landed.
    mutating func noteAutoFix(typo: String, fix: String, precedingText: String, field: UInt64 = 0) {
        guard typo.lowercased() != fix.lowercased() else { return }
        let trimmed = precedingText.reversed().drop { $0.isWhitespace }
        let word = String(trimmed.prefix(typo.count).reversed())
        guard word.caseInsensitiveCompare(typo) == .orderedSame else { return }
        let textBefore = String(trimmed.dropFirst(typo.count).reversed())
        pending.append(Pending(typo: typo.lowercased(), fix: fix.lowercased(), textBefore: textBefore, field: field))
        if pending.count > Self.maximumPending { pending.removeFirst() }
    }

    /// Reads the latest text before the caret and returns the fixes it settles. A fix whose earlier
    /// text was edited, or whose field changed, is dropped without a verdict.
    mutating func observe(_ precedingText: String, field: UInt64 = 0) -> [AutoFixOutcome] {
        var outcomes: [AutoFixOutcome] = []
        pending = pending.compactMap { item in
            var item = item
            guard item.field == field, precedingText.hasPrefix(item.textBefore) else { return nil }
            let rest = precedingText.dropFirst(item.textBefore.count)
            let word = rest.prefix { $0.isLetter || $0 == "'" || $0 == "’" }.lowercased()
            let wordIsFinished = rest.count > word.count
            // The fix, or a start of it that the typo does not share (`th` of `the`, typed as
            // `teh`): the writer is already backspacing through a fix that landed.
            if word == item.fix || (!word.isEmpty && item.fix.hasPrefix(word) && !item.typo.hasPrefix(word)) {
                item.wasSeen = true
            }
            if word == item.typo, wordIsFinished {
                // A read from before the fix landed shows the typo too; only a fix that was seen
                // and is gone again was undone.
                guard item.wasSeen else { return item }
                outcomes.append(AutoFixOutcome(kind: .reverted, typo: item.typo, fix: item.fix))
                return nil
            }
            if word == item.fix, Self.hasFinishedAnotherWord(after: rest.dropFirst(word.count)) {
                outcomes.append(AutoFixOutcome(kind: .confirmed, typo: item.typo, fix: item.fix))
                return nil
            }
            // A third word, finished, where the fix had been seen. Most wrong fixes end this way
            // (the writer deletes the fix and types what they meant, not the slip again), and
            // until this was reported they left no trace: nothing learned the right word, and
            // the count of undone fixes that tunes the threshold missed them.
            if item.wasSeen, wordIsFinished, !word.isEmpty, word != item.fix, word != item.typo {
                outcomes.append(AutoFixOutcome(kind: .replaced, typo: item.typo, fix: item.fix, replacement: word))
                return nil
            }
            return item
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
