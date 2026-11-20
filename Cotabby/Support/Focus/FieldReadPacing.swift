import Foundation

/// File overview:
/// How long the focused field is left unread after a read that was slow.
///
/// Why this exists: every read of the field is a request to the app in front, made on Cotabby's
/// main thread, and nothing else happens on that thread until the app answers. A native text view
/// answers in a millisecond or two. A chat or browser app that is busy drawing takes 30 to 300 ms.
/// Cotabby reads again and again while it waits for a key to show up (every 10 to 30 ms), so in
/// such an app the main thread did little but wait for reads, and the main thread is also where
/// the key taps are served. Measured with a test app that answers in about 100 ms: the word strip
/// was drawn up to 700 ms after its key, Tab on the strip picked the word 6 times in 12, macOS
/// switched the tap off 7 times for answering too slowly, and with the tap off Tab went to the app.
///
/// So a slow read is followed by a rest of twice its length, during which a request for another
/// read is answered with the text already known. Whoever asked sees a field that has not changed
/// yet, which every caller already has to cope with (an app that publishes a key late looks the
/// same), and asks again. Reads then take a third of the main thread at most, whatever the app
/// costs, and a key is never kept waiting behind more than the one read in flight. Fast apps are
/// read exactly as before: a read under `slowReadNanoseconds` is followed by no rest at all.
///
/// Pure and small. `FocusTracker` owns one, tells it how long each read took, and asks it before
/// the next.
nonisolated struct FieldReadPacing: Equatable, Sendable {
    /// A read at least this long is a slow one. A read is a handful of queries, and a query to a
    /// Chromium app that is not busy takes a few milliseconds, so such an app stays under this
    /// and is read as before.
    static let slowReadNanoseconds: UInt64 = 30_000_000
    /// The longest rest, so one freak read does not leave Cotabby blind for long.
    static let longestRestNanoseconds: UInt64 = 300_000_000

    private var restUntil: UInt64 = 0
    /// How long the last read took, for the training record and the debug log.
    private(set) var lastReadNanoseconds: UInt64 = 0

    /// A read ran from `started` to `ended` (uptime nanoseconds).
    mutating func noteRead(started: UInt64, ended: UInt64) {
        let cost = ended > started ? ended - started : 0
        lastReadNanoseconds = cost
        restUntil = cost >= Self.slowReadNanoseconds ? ended + min(cost * 2, Self.longestRestNanoseconds) : 0
    }

    /// True while the field should be left alone after a slow read.
    func isResting(at now: UInt64) -> Bool {
        now < restUntil
    }
}
