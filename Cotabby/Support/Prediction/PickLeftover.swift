import Foundation

/// File overview:
/// Tells when a pick from the word strip left some of the writer's letters standing in front of
/// the word it typed, and what puts that right.
///
/// Why this exists: a pick is typed blind. It presses Backspace once for each letter the writer
/// typed, then types the whole word. If the app does not act on one of those Backspaces, the word
/// still arrives and a typed letter is left in front of it: `ph` picked as `physical` reads
/// `pphysical`. A recorded week showed it in 4 of 17 picks in one native notes app and in none of
/// 600 in a chat app, so the cause is on the app's side (a key that dismisses the app's own
/// inline suggestion instead of deleting, or a key dropped under load), and which one it is
/// cannot be known from outside. What can be known is the result: right after a pick, with no
/// key pressed since, the field ends in the first letters the writer typed followed by the whole
/// picked word. No correct pick and no in-between state of a pick reads like that (the
/// Backspaces are sent before the word), so it is safe to act on.
///
/// Pure. `WordPredictionController` remembers what its last pick was meant to leave and asks
/// this about the first read of the field after it.
nonisolated enum PickLeftover {
    /// What a pick was meant to do: the text before the letters the writer typed (`stem`), those
    /// letters (`prefix`), and what was typed in their place (`typed`, the word and its space).
    struct Pick: Equatable, Sendable {
        let stem: String
        let prefix: String
        let typed: String

        /// The text before the caret once the pick has landed.
        var expected: String { stem + typed }
    }

    /// How many of the writer's letters still stand in front of the picked word in `read`, or nil
    /// when the field does not read as a pick that lost Backspaces: it holds what the pick meant
    /// to leave, or something else altogether.
    static func lettersLeft(in read: String, after pick: Pick) -> Int? {
        guard !pick.prefix.isEmpty, read.hasSuffix(pick.typed) else { return nil }
        let front = String(read.dropLast(pick.typed.count))
        for kept in 1...pick.prefix.count
        where TextFromKeys.isSameText(front, pick.stem + pick.prefix.prefix(kept)) {
            return kept
        }
        return nil
    }

    /// The Backspace keys that take the leftover letters and the word out again, so the word can
    /// be typed once more on its own; nil when that number depends on the app
    /// (`BackspaceKeyCount`), and then nothing is repaired.
    static func backspaces(removing kept: Int, of pick: Pick) -> Int? {
        BackspaceKeyCount.deleting(pick.prefix.prefix(kept) + pick.typed)
    }
}
