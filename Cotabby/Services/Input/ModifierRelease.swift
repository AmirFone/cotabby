import CoreGraphics
import Foundation

/// Runs an action once the writer has let go of Command, Option, Control, and Shift.
///
/// Picks made with a chord (Option+2) type text right away, but macOS merges the live modifier state
/// into synthetic key events: typing "a " while Option is still held reaches the app as Option+a,
/// which it treats as a shortcut, so the pick silently vanished. Waiting for the release (checked
/// every 10 ms, never longer than half a second) makes the typed text arrive as plain text.
@MainActor
enum ModifierRelease {
    static let pollInterval: TimeInterval = 0.01
    static let maximumWait: TimeInterval = 0.5
    private static let held: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    static func perform(_ action: @escaping @MainActor () -> Void, waited: TimeInterval = 0) {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        guard flags.isDisjoint(with: held) || waited >= maximumWait else {
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
                perform(action, waited: waited + pollInterval)
            }
            return
        }
        action()
    }
}
