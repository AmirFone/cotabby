import Foundation

/// File overview:
/// Whether the app in front has been slow to show typed keys, from how long its last few keys
/// took to appear in its text field.
///
/// Why this exists: an automatic fix can be made two ways. In an app that shows a key within
/// tens of milliseconds, Cotabby waits for the field to read the finished word and fixes what it
/// reads; that read is also where a host's own autocorrect, having changed the word first, would
/// be seen. In an app that takes 150 ms or more, or answers reads slowly, waiting means the fix
/// comes late, lands on the next word, or never comes, and the fix is typed from the keys instead
/// (`SuggestionCoordinator.typeFixFromKeys`). This type is what tells the two kinds of app apart.
///
/// The delay is smoothed over the last few keys, so one late key in a quick app (a native field
/// shows nine keys in ten within 60 ms and the odd one after 100) does not switch routes, and
/// two or three in a row do. It belongs to one app: the first key in another app starts over.
///
/// Pure and small. `SuggestionCoordinator` owns one and feeds it from the publish wait.
nonisolated struct HostLateness: Equatable, Sendable {
    /// A smoothed delay at or above this is a late app.
    static let lateMilliseconds = 60.0
    /// How much the newest key counts against the ones before it.
    static let newestWeight = 0.4

    private var bundleIdentifier: String?
    private var smoothedMilliseconds = 0.0

    /// A key typed in `bundleIdentifier` showed up in its field after `milliseconds` (or the
    /// wait for it gave up after that long).
    mutating func note(publishedAfter milliseconds: Int, inApp bundleIdentifier: String) {
        if self.bundleIdentifier == bundleIdentifier {
            smoothedMilliseconds += Self.newestWeight * (Double(milliseconds) - smoothedMilliseconds)
        } else {
            self.bundleIdentifier = bundleIdentifier
            smoothedMilliseconds = Double(milliseconds)
        }
    }

    /// True when `bundleIdentifier` has been showing keys late, or its last read was a slow one
    /// (`FieldReadPacing`): an app that answers slowly is not going to show a key promptly either.
    func isLate(inApp bundleIdentifier: String, lastReadMilliseconds: Int) -> Bool {
        if UInt64(max(0, lastReadMilliseconds)) * 1_000_000 >= FieldReadPacing.slowReadNanoseconds { return true }
        return self.bundleIdentifier == bundleIdentifier && smoothedMilliseconds >= Self.lateMilliseconds
    }
}
