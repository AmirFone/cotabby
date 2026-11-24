import XCTest
@testable import Cotabby

/// Locks down when a field is still believed to be there after a capture found none: only when
/// the app left a read unanswered, the same app is in front, and a field was seen a moment ago.
final class UnansweredReadGraceTests: XCTestCase {
    private let millisecond: UInt64 = 1_000_000

    func test_unansweredReadRightAfterAFieldWasSeen_keepsTheField() {
        // #given a field read at 1 s
        var grace = UnansweredReadGrace()
        grace.noteFieldSeen(at: 1_000 * millisecond)

        // #when the app does not answer the next read, 80 ms later
        let keeps = grace.keepsField(leftUnanswered: true, sameApplication: true, at: 1_080 * millisecond)

        // #then the field stays
        XCTAssertTrue(keeps)
    }

    func test_answerThatSaysNoField_isBelievedAtOnce() {
        // #given a field read at 1 s
        var grace = UnansweredReadGrace()
        grace.noteFieldSeen(at: 1_000 * millisecond)

        // #when every read of the next capture is answered and there is no field
        let keeps = grace.keepsField(leftUnanswered: false, sameApplication: true, at: 1_080 * millisecond)

        // #then the field is gone
        XCTAssertFalse(keeps)
    }

    func test_anotherApplicationInFront_isBelievedAtOnce() {
        // #given a field read at 1 s
        var grace = UnansweredReadGrace()
        grace.noteFieldSeen(at: 1_000 * millisecond)

        // #when the unanswered read is of another app
        let keeps = grace.keepsField(leftUnanswered: true, sameApplication: false, at: 1_080 * millisecond)

        // #then nothing of the first app's field is kept
        XCTAssertFalse(keeps)
    }

    func test_appThatKeepsNotAnswering_losesItsFieldAfterTheLongestWait() {
        // #given a field read at 1 s and no answer since
        var grace = UnansweredReadGrace()
        grace.noteFieldSeen(at: 1_000 * millisecond)
        let justBefore = 1_000 * millisecond + UnansweredReadGrace.longestNanoseconds - 1

        // #then the field is kept up to the longest wait and not at it
        XCTAssertTrue(grace.keepsField(leftUnanswered: true, sameApplication: true, at: justBefore))
        XCTAssertFalse(grace.keepsField(leftUnanswered: true, sameApplication: true, at: justBefore + 1))
    }

    func test_noFieldSeenYet_keepsNothing() {
        // #given a tracker that has not read a field
        let grace = UnansweredReadGrace()

        // #then an unanswered read has nothing to keep
        XCTAssertFalse(grace.keepsField(leftUnanswered: true, sameApplication: true, at: 1_000 * millisecond))
    }

    func test_afterTheFieldWasBelievedGone_laterUnansweredReadsKeepNothing() {
        // #given a field that was seen and then believed gone
        var grace = UnansweredReadGrace()
        grace.noteFieldSeen(at: 1_000 * millisecond)
        grace.noteFieldGone()

        // #then the next unanswered read does not bring it back
        XCTAssertFalse(grace.keepsField(leftUnanswered: true, sameApplication: true, at: 1_050 * millisecond))
    }

    func test_eachCaptureThatSeesTheField_startsTheWaitOver() {
        // #given a field seen at 1 s and again at 2 s
        var grace = UnansweredReadGrace()
        grace.noteFieldSeen(at: 1_000 * millisecond)
        grace.noteFieldSeen(at: 2_000 * millisecond)

        // #then an unanswered read at 2.5 s is within the wait counted from the second
        XCTAssertTrue(grace.keepsField(leftUnanswered: true, sameApplication: true, at: 2_500 * millisecond))
    }
}
