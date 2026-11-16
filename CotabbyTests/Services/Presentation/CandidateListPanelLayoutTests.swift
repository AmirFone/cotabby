import CoreGraphics
import XCTest
@testable import Cotabby

/// Panels sit above the line being typed; confirmations go below so the word strip never hides them.
final class CandidateListPanelLayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let caret = CGRect(x: 100, y: 400, width: 2, height: 18)
    private let size = CGSize(width: 200, height: 30)

    func test_panelsGoAboveTheLineByDefault() {
        let frame = CandidateListPanelLayout.frame(caretRect: caret, contentSize: size, visibleFrame: screen)

        XCTAssertGreaterThanOrEqual(frame.minY, caret.maxY)
    }

    func test_flashesGoBelowTheLine() {
        let frame = CandidateListPanelLayout.frame(caretRect: caret, contentSize: size, visibleFrame: screen, preferBelow: true)

        XCTAssertLessThanOrEqual(frame.maxY, caret.minY)
    }

    func test_flashAtTheBottomOfTheScreenGoesAbove() {
        let low = CGRect(x: 100, y: 10, width: 2, height: 18)

        let frame = CandidateListPanelLayout.frame(caretRect: low, contentSize: size, visibleFrame: screen, preferBelow: true)

        XCTAssertGreaterThanOrEqual(frame.minY, low.maxY)
    }
}
