import Foundation

/// File overview:
/// Takes Cotabby's panels off the screen when the writer stops typing, and keeps them off until
/// the next key.
///
/// The word strip and the spelling bar sit right above the caret. While the writer types they are
/// the point; once the writer stops to read or think, they cover the line being read. Each used to
/// keep its own clock (eight and ten seconds), restarted whenever the panel was drawn. A panel is
/// also drawn when no key was pressed (the language model's order arrives, screen text becomes
/// ready, the caret is reported a pixel away), so the clock kept starting over and a strip could
/// stay up, or come back, with nobody typing.
///
/// One clock for both now, and it counts from the writer's last key, not from the last drawing:
/// `InlineCommandCoordinator` reports every key it sees, the panels are told once when the time is
/// up, and from then until the next key `hasRunOut` tells them to stay down whatever asks them to
/// draw.
///
/// It is its own type because that state belongs to no single panel: a key taken by the spelling
/// bar never reaches the strip's key handling, and the strip must still know the writer is there.
/// Owned by the app environment and handed to the coordinator and to both panels.
@MainActor
final class InlinePanelIdleTimer {
    /// How long after the last key the panels go away.
    static let defaultSeconds: TimeInterval = 5

    private let seconds: TimeInterval
    private var lastActivityUptimeNanoseconds: UInt64 = 0
    private var countdown: Task<Void, Never>?
    private var handlers: [() -> Void] = []

    /// True from the moment the time ran out until the writer's next key or pick.
    private(set) var hasRunOut = false

    init(seconds: TimeInterval = InlinePanelIdleTimer.defaultSeconds) {
        self.seconds = seconds
    }

    /// Registers what a panel does when the time is up. Called once per panel at start.
    func whenRunOut(_ handler: @escaping () -> Void) {
        handlers.append(handler)
    }

    /// The writer pressed a key or picked a word: the count starts again.
    ///
    /// This runs on every key, so it does not cancel and start a task each time. It only notes
    /// the time; the one countdown that is already waiting looks at that time when it wakes and
    /// goes back to sleep for whatever is left.
    func noteActivity() {
        lastActivityUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        hasRunOut = false
        guard countdown == nil else { return }
        countdown = Task { [weak self] in
            while let remaining = self?.nanosecondsLeft(), remaining > 0 {
                try? await Task.sleep(nanoseconds: remaining)
                if Task.isCancelled { return }
            }
            self?.runOut()
        }
    }

    func stop() {
        countdown?.cancel()
        countdown = nil
        hasRunOut = false
    }

    private func nanosecondsLeft() -> UInt64 {
        let limit = UInt64(seconds * 1_000_000_000)
        let elapsed = DispatchTime.now().uptimeNanoseconds &- lastActivityUptimeNanoseconds
        return elapsed >= limit ? 0 : limit - elapsed
    }

    private func runOut() {
        countdown = nil
        hasRunOut = true
        handlers.forEach { $0() }
    }
}
