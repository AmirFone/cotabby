import Combine
import CoreGraphics
import XCTest
@preconcurrency @testable import Cotabby

/// The sentence pass as the writer experiences it: certain fixes applied at once, unsure words
/// reviewed one at a time with Tab / Escape / arrows, and typing never blocked.
@MainActor
final class SentenceCheckControllerTests: XCTestCase {
    private var retained: [AnyObject] = []

    override func tearDown() {
        retained.removeAll()
        super.tearDown()
    }

    func test_certainFixesAreAppliedAtOnce() {
        // #given a finished sentence with a doubled word and no unsure words
        let harness = makeHarness(sentence: "I went to the the store today. ", proofread: { finished in
            LocalProofreadResult(original: finished.sentence, autoCorrected: "I went to the store today.", flags: [])
        })

        // #when the pass runs
        harness.controller.noteTypedText(harness.focus.snapshot.context!.precedingText, caretRect: .zero, focusChangeSequence: 1)
        flushMainQueue()

        // #then only the differing tail is retyped
        XCTAssertEqual(harness.inserter.replacements.count, 1)
        XCTAssertEqual(harness.inserter.replacements.first?.text, "store today. ")
        XCTAssertEqual(harness.panel.flashes, 1)
    }

    func test_review_tabTakesEachBestOptionThenAppliesOnce() {
        // #given two unsure words
        let harness = makeHarness(sentence: "I went their with adres book. ", proofread: Self.twoFlags)
        harness.controller.noteTypedText(harness.focus.snapshot.context!.precedingText, caretRect: .zero, focusChangeSequence: 1)
        XCTAssertEqual(harness.panel.reviews.last?.position, 1)

        // #when Tab twice
        XCTAssertTrue(harness.controller.observe(Self.key(48)))
        XCTAssertEqual(harness.panel.reviews.last?.position, 2)
        XCTAssertTrue(harness.controller.observe(Self.key(48)))
        flushMainQueue()

        // #then one rewrite with both fixes, retyping only from the first difference ("the|ir")
        XCTAssertEqual(harness.inserter.replacements.count, 1)
        XCTAssertEqual(harness.inserter.replacements.first?.text, "re with address book. ")
        XCTAssertFalse(harness.controller.isShowingFix)
    }

    func test_review_escapeKeepsTheTypedWord() {
        let harness = makeHarness(sentence: "I went their with adres book. ", proofread: Self.twoFlags)
        harness.controller.noteTypedText(harness.focus.snapshot.context!.precedingText, caretRect: .zero, focusChangeSequence: 1)

        _ = harness.controller.observe(Self.key(53))
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        XCTAssertEqual(harness.inserter.replacements.first?.text, "dress book. ")
    }

    func test_review_arrowsPickAnotherOption() {
        let harness = makeHarness(sentence: "I went their with adres book. ", proofread: Self.twoFlags)
        harness.controller.noteTypedText(harness.focus.snapshot.context!.precedingText, caretRect: .zero, focusChangeSequence: 1)

        _ = harness.controller.observe(Self.key(48))
        XCTAssertTrue(harness.controller.observe(Self.key(124)))
        XCTAssertEqual(harness.panel.reviews.last?.selectedIndex, 2)
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        XCTAssertEqual(harness.inserter.replacements.first?.text, "re with adders book. ")
    }

    func test_review_typingClosesWithoutChanges() {
        let harness = makeHarness(sentence: "I went their with adres book. ", proofread: Self.twoFlags)
        harness.controller.noteTypedText(harness.focus.snapshot.context!.precedingText, caretRect: .zero, focusChangeSequence: 1)

        let involved = harness.controller.observe(CapturedInputEvent(kind: .textMutation, keyCode: 0, characters: "a", flags: []))
        flushMainQueue()

        XCTAssertFalse(involved)
        XCTAssertFalse(harness.controller.isShowingFix)
        XCTAssertTrue(harness.inserter.replacements.isEmpty)
    }

    func test_sameSentenceIsNotReviewedTwice() {
        let harness = makeHarness(sentence: "I went their with adres book. ", proofread: Self.twoFlags)
        let text = harness.focus.snapshot.context!.precedingText
        harness.controller.noteTypedText(text, caretRect: .zero, focusChangeSequence: 1)
        _ = harness.controller.observe(Self.key(53))
        _ = harness.controller.observe(Self.key(53))

        harness.controller.noteTypedText(text, caretRect: .zero, focusChangeSequence: 1)

        XCTAssertEqual(harness.panel.reviews.count, 2, "Only the two steps of the first review")
    }

    func test_sentenceTypedAgainAfterClearingIsReviewedAgain() {
        // #given a reviewed sentence
        let harness = makeHarness(sentence: "I went their with adres book. ", proofread: Self.twoFlags)
        let text = harness.focus.snapshot.context!.precedingText
        harness.controller.noteTypedText(text, caretRect: .zero, focusChangeSequence: 1)
        _ = harness.controller.observe(Self.key(53))
        _ = harness.controller.observe(Self.key(53))

        // #when the field is cleared and the same sentence typed again
        harness.controller.noteTypedText("", caretRect: .zero, focusChangeSequence: 1)
        harness.controller.noteTypedText(text, caretRect: .zero, focusChangeSequence: 1)

        // #then it is reviewed again
        XCTAssertEqual(harness.panel.reviews.count, 3)
    }

    // MARK: - Harness

    private static func twoFlags(_ finished: FinishedSentence) -> LocalProofreadResult? {
        let sentence = finished.sentence
        let their = sentence.range(of: "their")!
        let adres = sentence.range(of: "adres")!
        return LocalProofreadResult(original: sentence, autoCorrected: sentence, flags: [
            SentenceFlag(range: their, typed: "their", options: ["there"]),
            SentenceFlag(range: adres, typed: "adres", options: ["address", "adders"])
        ])
    }

    private struct Harness {
        let controller: SentenceCheckController
        let panel: ReviewRecordingPanel
        let focus: StaticFocus
        let inserter: RigInserter
    }

    private func makeHarness(
        sentence: String,
        proofread: @escaping (FinishedSentence) -> LocalProofreadResult?
    ) -> Harness {
        let suite = "SentenceCheckControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let panel = ReviewRecordingPanel()
        let focus = StaticFocus(precedingText: sentence)
        let inserter = RigInserter()
        let metrics = SuggestionQualityMetricsStore(userDefaults: defaults)
        let controller = SentenceCheckController(
            panel: panel,
            focusModel: focus,
            inserter: inserter,
            client: OpenAICompatibleAPIClient(),
            configurationProvider: { throw CancellationError() },
            apiKeyProvider: { nil },
            rateGovernor: nil,
            isEnabled: { false },
            knownTerms: { nil },
            acceptKeyLabel: { "Tab" },
            isWordAcceptKey: { $0.keyCode == 48 },
            qualityMetricsStore: metrics,
            localProofread: proofread,
            isLocalEnabled: { true },
            appliesLocalFixes: { true }
        )
        controller.start()
        retained.append(contentsOf: [controller, panel, focus, inserter, metrics] as [AnyObject])
        return Harness(controller: controller, panel: panel, focus: focus, inserter: inserter)
    }

    private func flushMainQueue() {
        let fence = expectation(description: "flush main queue")
        DispatchQueue.main.async { fence.fulfill() }
        wait(for: [fence], timeout: 1)
    }

    private static func key(_ keyCode: CGKeyCode) -> CapturedInputEvent {
        CapturedInputEvent(kind: .navigation, keyCode: keyCode, characters: "", flags: [])
    }
}

@MainActor
private final class ReviewRecordingPanel: CandidateListPanelPresenting {
    var onSelectIndex: ((Int) -> Void)?
    var onClickOutside: (() -> Void)?
    private(set) var reviews: [SentenceReviewPresentation] = []
    private(set) var flashes = 0

    func show(offer: CandidateOffer, selectedIndex: Int, acceptKeyLabel: String) {}
    func setSelectedIndex(_ index: Int) {}
    func showFlash(typo: String, correction: String, caretRect: CGRect) {}
    func showSentenceFlash(segments: [SentenceFixSegment], caretRect: CGRect) { flashes += 1 }
    func showSentenceReview(_ review: SentenceReviewPresentation, caretRect: CGRect, acceptKeyLabel: String) {
        reviews.append(review)
    }
    func showSentenceFix(segments: [SentenceFixSegment], caretRect: CGRect, acceptKeyLabel: String) {}
    func hide() {}
}

@MainActor
private final class StaticFocus: SuggestionFocusProviding {
    let snapshot: FocusSnapshot
    var snapshotPublisher: AnyPublisher<FocusSnapshot, Never> { Empty().eraseToAnyPublisher() }

    init(precedingText: String) {
        snapshot = FocusSnapshot(
            applicationName: "TestApp",
            bundleIdentifier: "com.test.app",
            capability: .supported,
            context: CotabbyTestFixtures.focusedInputSnapshot(precedingText: precedingText, focusChangeSequence: 1)
        )
    }

    func refreshNow() {}
}
