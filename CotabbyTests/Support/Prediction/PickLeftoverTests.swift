import XCTest
@testable import Cotabby

/// Locks down when a field reads as a pick that lost Backspaces, and that nothing else does.
final class PickLeftoverTests: XCTestCase {
    private let pick = PickLeftover.Pick(stem: "I saw the ", prefix: "rep", typed: "report ")

    func test_pickThatLanded_leavesNothing() {
        // #given the field holds what the pick meant to leave
        // #then there is nothing to repair
        XCTAssertNil(PickLeftover.lettersLeft(in: "I saw the report ", after: pick))
    }

    func test_oneBackspaceLost_leavesTheFirstLetter() {
        // #given two of three Backspaces took effect before the word arrived
        // #then one typed letter stands in front of the word
        XCTAssertEqual(PickLeftover.lettersLeft(in: "I saw the rreport ", after: pick), 1)
    }

    func test_everyBackspaceLost_leavesAllTheLetters() {
        XCTAssertEqual(PickLeftover.lettersLeft(in: "I saw the repreport ", after: pick), 3)
    }

    func test_stateWhileThePickIsLanding_isNotALeftover() {
        // #given the Backspaces have landed and the word is half typed
        // #then the read is the pick on its way, not a failed one
        XCTAssertNil(PickLeftover.lettersLeft(in: "I saw the rep", after: pick))
        XCTAssertNil(PickLeftover.lettersLeft(in: "I saw the repo", after: pick))
    }

    func test_otherTextEndingInTheWord_isNotALeftover() {
        // #given the writer's own text that happens to end in the picked word
        // #then it is left alone
        XCTAssertNil(PickLeftover.lettersLeft(in: "I read the report ", after: pick))
        XCTAssertNil(PickLeftover.lettersLeft(in: "I saw the xreport ", after: pick))
    }

    func test_pickAfterASpace_hasNoLettersToLeave() {
        // #given a word picked before any letter was typed
        let next = PickLeftover.Pick(stem: "I saw the ", prefix: "", typed: "report ")

        // #then no read counts as a leftover
        XCTAssertNil(PickLeftover.lettersLeft(in: "I saw the report ", after: next))
    }

    func test_repair_deletesTheLeftoverLettersAndTheWord() {
        // #given one letter left in front of `report ` (seven characters)
        // #then eight Backspaces clear the way for the word to be typed again
        XCTAssertEqual(PickLeftover.backspaces(removing: 1, of: pick), 8)
    }
}
