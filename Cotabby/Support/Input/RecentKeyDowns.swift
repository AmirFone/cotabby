import Foundation

/// File overview:
/// A short memory of key-down events, by their timestamps, for telling whether a key has been
/// through one of `InputMonitor`'s two taps when it arrives at the other.
///
/// Why this exists: the listening tap and the consuming tap are handed the same key one after
/// the other, usually in that order, and when Cotabby's run loop is behind, in the other order or
/// two keys deep. Each tap has to know what the other has already done with a key, and "the last
/// key" is not enough to know that once two are waiting.
///
/// A timestamp is the event's own and the same in both taps. It is kept until the other tap asks
/// for it (`remove`), and the oldest are dropped past `capacity`, so a tap that is switched off
/// and never asks cannot make the memory grow.
///
/// Pure and small. `InputMonitor` owns two.
nonisolated struct RecentKeyDowns: Equatable, Sendable {
    /// More keys than can be waiting between the two taps' turns.
    static let capacity = 32

    private var timestamps: [UInt64] = []

    mutating func insert(_ timestamp: UInt64) {
        timestamps.append(timestamp)
        if timestamps.count > Self.capacity {
            timestamps.removeFirst(timestamps.count - Self.capacity)
        }
    }

    /// Forgets `timestamp` and says whether it was remembered.
    mutating func remove(_ timestamp: UInt64) -> Bool {
        guard let index = timestamps.firstIndex(of: timestamp) else { return false }
        timestamps.remove(at: index)
        return true
    }
}
