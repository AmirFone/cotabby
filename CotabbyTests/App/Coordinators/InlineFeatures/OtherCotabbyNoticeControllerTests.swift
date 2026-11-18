import XCTest
@testable import Cotabby

/// The one-time warning that the released Cotabby app is running next to this build.
@MainActor
final class OtherCotabbyNoticeControllerTests: XCTestCase {
    private let caret = CGRect(x: 40, y: 300, width: 2, height: 18)

    func test_otherAppRunning_warnsOnceAtTheCaret() {
        // #given the released app running while this build is in use
        let panel = CountingNoticePanel()
        let notice = OtherCotabbyNoticeController(panel: panel, ownBundleIdentifier: "com.jacobfu.tabby.dev", isOtherRunning: { true })

        // #when the writer focuses a text field, then another
        notice.noteTextFieldFocus(caretRect: caret)
        notice.noteTextFieldFocus(caretRect: CGRect(x: 1, y: 1, width: 2, height: 18))

        // #then the warning was shown where they were looking, and only the first time
        XCTAssertEqual(panel.anchors, [caret])
    }

    func test_warning_saysWhatHappensAndWhatToDo() {
        let panel = CountingNoticePanel()
        let notice = OtherCotabbyNoticeController(panel: panel, ownBundleIdentifier: "com.jacobfu.tabby.dev", isOtherRunning: { true })

        notice.noteTextFieldFocus(caretRect: caret)

        XCTAssertEqual(panel.segments, [SentenceFixSegment(text: OtherCotabbyNoticeController.message, isChanged: false)])
        XCTAssertTrue(OtherCotabbyNoticeController.message.contains("Tab"))
        XCTAssertTrue(OtherCotabbyNoticeController.message.contains("Quit"))
    }

    func test_otherAppNotRunning_showsNothing() {
        let panel = CountingNoticePanel()
        let notice = OtherCotabbyNoticeController(panel: panel, ownBundleIdentifier: "com.jacobfu.tabby.dev", isOtherRunning: { false })

        notice.noteTextFieldFocus(caretRect: caret)

        XCTAssertEqual(panel.segments, [])
    }

    func test_theReleasedAppItself_neverWarnsAboutItself() {
        // #given this code built as the released app, which finds its own identifier running
        XCTAssertFalse(OtherCotabbyNoticeController.isNoticeDue(
            ownBundleIdentifier: OtherCotabbyNoticeController.releasedBundleIdentifier, hasShown: false, isOtherRunning: { true }
        ))
    }

    func test_runningAppsAreOnlyListed_whenAWarningCouldFollow() {
        var asked = 0
        let due = OtherCotabbyNoticeController.isNoticeDue(ownBundleIdentifier: "com.jacobfu.tabby.dev", hasShown: true) {
            asked += 1
            return true
        }

        XCTAssertFalse(due)
        XCTAssertEqual(asked, 0)
    }
}

/// A panel that keeps every notice it was asked to show.
@MainActor
private final class CountingNoticePanel: CandidateListPanelPresenting {
    var onSelectIndex: ((Int) -> Void)?
    var onClickOutside: (() -> Void)?
    private(set) var segments: [SentenceFixSegment] = []
    private(set) var anchors: [CGRect] = []

    func show(offer: CandidateOffer, selectedIndex: Int, acceptKeyLabel: String) {}
    func setSelectedIndex(_ index: Int) {}
    func showWordStrip(words: [String], selectedIndex: Int?, caretRect: CGRect) {}
    func showFlash(typo: String, correction: String, caretRect: CGRect) {}
    func showSentenceFix(segments: [SentenceFixSegment], caretRect: CGRect, acceptKeyLabel: String) {}
    func showSentenceFlash(segments: [SentenceFixSegment], caretRect: CGRect) {
        self.segments = segments
        anchors.append(caretRect)
    }
    func showSentenceReview(_ review: SentenceReviewPresentation, caretRect: CGRect, acceptKeyLabel: String) {}
    func hide() {}
}
