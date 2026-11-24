import Foundation

/// File overview:
/// How long the focused field is still believed to be there after an app failed to answer a read
/// of it.
///
/// Why this exists: every read is a request to the app in front with 50 ms to answer
/// (`AXHelper.pollMessagingTimeout`). A request that goes unanswered and a request answered with
/// "nothing has focus" both reach `FocusTracker` as "no field", and it published both the same
/// way. Everything built on the field then let go of it: the word strip came down, the text the
/// keys had left was forgotten, the field got a new number. A chat app that is busy for a moment
/// (drawing a reply, loading a thread) misses that 50 ms now and then while the writer's caret has
/// not moved at all. The strip flickered away under the writer's eyes, and Tab pressed in that
/// moment had no strip to pick from, so it went to the app and moved its focus to the next button.
///
/// So a capture that found no field is not believed when the app left a question unanswered while
/// it was made, the same app is still in front, and a field was seen a moment ago. The snapshot
/// already published stays, which every reader already copes with (an app that shows a key late
/// looks the same). The moment is bounded: an app that keeps not answering has lost its field
/// after `longestNanoseconds`, and an answer that says the field is gone, or another app in
/// front, is believed at once.
///
/// Pure and small. `FocusTracker` owns one, tells it when a capture saw a field, and asks it when
/// a capture saw none.
nonisolated struct UnansweredReadGrace: Equatable, Sendable {
    /// As long as a host is believed to be behind the keys at all
    /// (`WordPredictionController.longestHostLagNanoseconds`).
    static let longestNanoseconds: UInt64 = 1_200_000_000

    private var fieldLastSeenAt: UInt64?

    /// A capture at `now` (uptime nanoseconds) read a field.
    mutating func noteFieldSeen(at now: UInt64) {
        fieldLastSeenAt = now
    }

    /// A capture that found no field was believed: there is nothing left to keep.
    mutating func noteFieldGone() {
        fieldLastSeenAt = nil
    }

    /// Whether the field last seen is kept although the capture at `now` found none.
    /// `leftUnanswered`: the app failed to answer at least one read during that capture.
    func keepsField(leftUnanswered: Bool, sameApplication: Bool, at now: UInt64) -> Bool {
        guard leftUnanswered, sameApplication, let seen = fieldLastSeenAt, now >= seen else { return false }
        return now - seen < Self.longestNanoseconds
    }
}
