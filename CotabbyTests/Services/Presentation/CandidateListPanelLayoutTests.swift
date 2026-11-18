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

    func test_regularPanel_keepsTheOffsetsItAlwaysHad() {
        // #given a panel at the Regular size, the one every panel had before sizes existed

        // #when it is placed with the size named and with the size left out
        let named = CandidateListPanelLayout.frame(caretRect: caret, contentSize: size, visibleFrame: screen, size: .regular)
        let unnamed = CandidateListPanelLayout.frame(caretRect: caret, contentSize: size, visibleFrame: screen)

        // #then both start 12 pt left of the caret and 6 pt above its line
        XCTAssertEqual([named.origin, unnamed.origin], [CGPoint(x: 88, y: 424), CGPoint(x: 88, y: 424)])
    }

    func test_compactPanel_sitsCloserToTheCaret() {
        // #given a Compact panel, whose own padding is three quarters of the Regular one

        // #when it is placed at the caret
        let frame = CandidateListPanelLayout.frame(caretRect: caret, contentSize: size, visibleFrame: screen, size: .compact)

        // #then its offsets shrink by the same three quarters: 9 pt left, 4.5 pt above
        XCTAssertEqual(frame.origin, CGPoint(x: 91, y: 422.5))
    }
}
