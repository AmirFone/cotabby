import XCTest
@testable import Cotabby

/// Tests for the pure end-of-line classifier that gates mid-line completion strategies.
///
/// The key distinction these lock down: a caret can have non-empty `trailingText` (a line break and
/// later paragraphs) while still being at the end of its own line. Fill-in-middle must treat that as
/// end-of-line, not as mid-line infilling.
final class CaretLinePositionTests: XCTestCase {
    func test_emptyTrailingTextIsEndOfLine() {
        XCTAssertTrue(CaretLinePosition.isAtEndOfLine(trailingText: ""))
    }

    func test_leadingNewlineIsEndOfLine() {
        // Caret sits at line end; the next paragraph follows after the break.
        XCTAssertTrue(CaretLinePosition.isAtEndOfLine(trailingText: "\nnext paragraph"))
    }

    func test_whitespaceThenNewlineIsEndOfLine() {
        XCTAssertTrue(CaretLinePosition.isAtEndOfLine(trailingText: "   \nmore"))
    }

    func test_trailingWhitespaceOnlyIsEndOfLine() {
        XCTAssertTrue(CaretLinePosition.isAtEndOfLine(trailingText: "   "))
    }

    func test_sameLineTextIsNotEndOfLine() {
        XCTAssertFalse(CaretLinePosition.isAtEndOfLine(trailingText: " world"))
    }

    func test_singleNonWhitespaceCharacterIsNotEndOfLine() {
        XCTAssertFalse(CaretLinePosition.isAtEndOfLine(trailingText: ")"))
    }

    func test_whitespaceThenSameLineTextIsNotEndOfLine() {
        // Whitespace before real same-line text still means the caret is mid-line.
        XCTAssertFalse(CaretLinePosition.isAtEndOfLine(trailingText: "  rest of line\n"))
    }

    func test_focusedInputContextExposesSignal() {
        let midLine = CotabbyTestFixtures.suggestionRequest(trailingText: " rest of line")
        XCTAssertFalse(midLine.context.isCaretAtEndOfLine)

        let endOfLine = CotabbyTestFixtures.suggestionRequest(trailingText: "\nnext paragraph")
        XCTAssertTrue(endOfLine.context.isCaretAtEndOfLine)
    }

    // MARK: - Nothing follows on the line (may a picked word bring its own space?)

    func test_nothingFollows_atTheEndOfTheFieldOrOfALine() {
        // #given a caret at the end of the field, and one at the end of a line with more below
        let trailing = ["", "\nnext paragraph"]

        // #then a picked word may type its space
        XCTAssertEqual(trailing.map { CaretLinePosition.nothingFollowsOnLine(trailingText: $0) }, [true, true])
    }

    func test_somethingFollows_whenAMarkAWordOrASpaceIsAlreadyThere() {
        // #given text right after the caret: a period, a word, a closing bracket, a space, spaces only
        let trailing = [". Then", "and more", ")", " and more", "  "]

        // #then a space typed there would be a stray one, even where `isAtEndOfLine` says end of line
        XCTAssertEqual(
            trailing.map { CaretLinePosition.nothingFollowsOnLine(trailingText: $0) },
            [Bool](repeating: false, count: trailing.count)
        )
    }
}
