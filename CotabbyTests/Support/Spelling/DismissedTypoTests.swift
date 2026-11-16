import XCTest
@testable import Cotabby

/// Escape on the spelling bar covers one word in one place, and nothing after the caret moves on.
final class DismissedTypoTests: XCTestCase {
    func test_coversTheSameWordWhileItIsExtendedOrFinished() throws {
        let dismissed = try XCTUnwrap(DismissedTypo(precedingText: "I think becuas"))

        XCTAssertEqual(dismissed.word, "becuas")
        XCTAssertEqual(dismissed.textBefore, "I think ")
        XCTAssertTrue(dismissed.covers(precedingText: "I think becuas"))
        XCTAssertTrue(dismissed.covers(precedingText: "I think becuase"))
        XCTAssertTrue(dismissed.covers(precedingText: "I think becuase "))
        XCTAssertTrue(dismissed.covers(precedingText: "I think becuase, "))
    }

    func test_stopsCoveringOnceTheCaretMovesOn() throws {
        let dismissed = try XCTUnwrap(DismissedTypo(precedingText: "I think becuas"))

        XCTAssertFalse(dismissed.covers(precedingText: "I think becuase it"))
        XCTAssertFalse(dismissed.covers(precedingText: "I think bec"))
        XCTAssertFalse(dismissed.covers(precedingText: "We think becuas"))
        XCTAssertFalse(dismissed.covers(precedingText: "I think "))
    }

    func test_theSameMisspellingElsewhereIsNotCovered() throws {
        let dismissed = try XCTUnwrap(DismissedTypo(precedingText: "I think becuase "))

        XCTAssertFalse(dismissed.covers(precedingText: "I think becuase it rained becuase "))
    }

    func test_nothingToDismissWithoutAWordAtTheCaret() {
        XCTAssertNil(DismissedTypo(precedingText: "I think  "))
        XCTAssertNil(DismissedTypo(precedingText: ""))
    }
}
