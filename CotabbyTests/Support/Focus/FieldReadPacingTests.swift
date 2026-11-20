import XCTest
@testable import Cotabby

/// Locks down when the focused field is left unread: only after a slow read, for twice as long
/// as that read took, and never longer than the cap.
final class FieldReadPacingTests: XCTestCase {
    private let millisecond: UInt64 = 1_000_000

    func test_fastRead_isFollowedByNoRest() {
        // #given a read that took 2 ms, as a native text view does
        var pacing = FieldReadPacing()
        pacing.noteRead(started: 1_000 * millisecond, ended: 1_002 * millisecond)

        // #then the next read may start at once
        XCTAssertFalse(pacing.isResting(at: 1_002 * millisecond))
    }

    func test_slowRead_isFollowedByARestOfTwiceItsLength() {
        // #given a read that took 100 ms
        var pacing = FieldReadPacing()
        pacing.noteRead(started: 1_000 * millisecond, ended: 1_100 * millisecond)

        // #then the field is left alone for the next 200 ms and no longer
        XCTAssertTrue(pacing.isResting(at: 1_299 * millisecond))
        XCTAssertFalse(pacing.isResting(at: 1_300 * millisecond))
    }

    func test_restIsCapped() {
        // #given a read that took a whole second
        var pacing = FieldReadPacing()
        pacing.noteRead(started: 0, ended: 1_000 * millisecond)

        // #then the rest ends after the cap, not after two seconds
        XCTAssertFalse(pacing.isResting(at: 1_000 * millisecond + FieldReadPacing.longestRestNanoseconds))
    }

    func test_fastReadAfterASlowOne_endsTheRest() {
        // #given a slow read, then (once the rest was over) a fast one
        var pacing = FieldReadPacing()
        pacing.noteRead(started: 0, ended: 100 * millisecond)
        pacing.noteRead(started: 300 * millisecond, ended: 302 * millisecond)

        // #then nothing is held back any more
        XCTAssertFalse(pacing.isResting(at: 302 * millisecond))
    }

    func test_lastReadCost_isKept() {
        var pacing = FieldReadPacing()
        pacing.noteRead(started: 5 * millisecond, ended: 45 * millisecond)

        XCTAssertEqual(pacing.lastReadNanoseconds, 40 * millisecond)
    }
}
