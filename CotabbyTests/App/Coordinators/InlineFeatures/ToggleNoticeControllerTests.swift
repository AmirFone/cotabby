import XCTest
@testable import Cotabby

/// The on/off notice of the toggle shortcut: what it says and where it goes.
@MainActor
final class ToggleNoticeControllerTests: XCTestCase {
    func test_switchingOff_saysHowToTurnItBackOn() {
        // #given a writer typing in a field
        let panel = RecordingNoticePanel()
        let notice = ToggleNoticeController(panel: panel, caretRect: { CGRect(x: 40, y: 300, width: 2, height: 18) })

        // #when the shortcut switches Cotabby off
        notice.show(isOn: false, shortcutLabel: "⌃⌥C")

        // #then the notice names the shortcut, as plain text rather than a highlighted fix
        XCTAssertEqual(panel.segments, [SentenceFixSegment(text: "Cotabby is off. ⌃⌥C turns it back on.", isChanged: false)])
    }

    func test_switchingOn_saysSo() {
        let panel = RecordingNoticePanel()
        let notice = ToggleNoticeController(panel: panel, caretRect: { nil }, pointerLocation: { .zero })

        notice.show(isOn: true, shortcutLabel: "⌃⌥C")

        XCTAssertEqual(panel.segments.map(\.text), ["Cotabby is on"])
    }

    func test_notice_appearsAtTheCaret() {
        let caret = CGRect(x: 40, y: 300, width: 2, height: 18)
        let panel = RecordingNoticePanel()
        let notice = ToggleNoticeController(panel: panel, caretRect: { caret }, pointerLocation: { CGPoint(x: 900, y: 900) })

        notice.show(isOn: false, shortcutLabel: "⌃⌥C")

        XCTAssertEqual(panel.anchor, caret)
    }

    func test_noticeWithNoFocusedField_appearsAtThePointer() {
        // #given the shortcut pressed with no text field in focus
        let panel = RecordingNoticePanel()
        let notice = ToggleNoticeController(panel: panel, caretRect: { nil }, pointerLocation: { CGPoint(x: 900, y: 500) })

        // #when the shortcut switches Cotabby on
        notice.show(isOn: true, shortcutLabel: "⌃⌥C")

        // #then the notice goes where the pointer is
        XCTAssertEqual(panel.anchor, CGRect(x: 900, y: 500, width: 0, height: 0))
    }
}

@MainActor
private final class RecordingNoticePanel: CandidateListPanelPresenting {
    var onSelectIndex: ((Int) -> Void)?
    var onClickOutside: (() -> Void)?
    private(set) var segments: [SentenceFixSegment] = []
    private(set) var anchor: CGRect?

    func show(offer: CandidateOffer, selectedIndex: Int, acceptKeyLabel: String) {}
    func setSelectedIndex(_ index: Int) {}
    func showWordStrip(words: [String], selectedIndex: Int?, caretRect: CGRect) {}
    func showFlash(typo: String, correction: String, caretRect: CGRect) {}
    func showSentenceFix(segments: [SentenceFixSegment], caretRect: CGRect, acceptKeyLabel: String) {}
    func showSentenceFlash(segments: [SentenceFixSegment], caretRect: CGRect) {
        self.segments = segments
        anchor = caretRect
    }
    func showSentenceReview(_ review: SentenceReviewPresentation, caretRect: CGRect, acceptKeyLabel: String) {}
    func hide() {}
}
