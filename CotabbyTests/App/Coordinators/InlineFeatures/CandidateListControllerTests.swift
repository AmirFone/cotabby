import Combine
import CoreGraphics
import XCTest
@preconcurrency @testable import Cotabby

/// Locks down the candidate list's key ownership and commit path: which keys it swallows, that a
/// commit is deferred off the tap callback, that a stale word is never overwritten, and that picks
/// feed the writer's correction history.
@MainActor
final class CandidateListControllerTests: XCTestCase {
    private var retained: [AnyObject] = []

    override func tearDown() {
        retained.removeAll()
        super.tearDown()
    }

    func test_presentChoices_showsListAndClaimsNavigationKeys() {
        // #given a visible spelling list
        let harness = makeHarness(precedingText: "I think wich ")
        harness.controller.presentChoices(harness.spellingOffer(typo: "wich", candidates: ["which", "with"]))

        // #when Down is pressed
        let involved = harness.controller.observe(Self.key(125))

        // #then the key is consumed and the selection moves
        XCTAssertTrue(involved)
        XCTAssertEqual(harness.controller.decideCaptureKey(InputMonitorKeyEvent(keyCode: 125)), .consume)
        XCTAssertEqual(harness.panel.selectedIndex, 1)
        XCTAssertTrue(harness.controller.isCapturing)
    }

    func test_returnCommitsSelectedSpellingAfterRunloopTick() {
        let harness = makeHarness(precedingText: "I think wich ")
        harness.controller.presentChoices(harness.spellingOffer(typo: "wich", candidates: ["which", "with"]))
        _ = harness.controller.observe(Self.key(125))

        XCTAssertTrue(harness.controller.observe(Self.key(36)))
        XCTAssertTrue(harness.inserter.replacements.isEmpty, "The replace must be deferred off the tap callback")
        flushMainQueue()

        XCTAssertEqual(harness.inserter.replacements.first?.text, "with ")
        XCTAssertEqual(harness.inserter.replacements.first?.deleteCount, 5)
        XCTAssertEqual(harness.memory.acceptedReplacements(for: "wich"), ["with": 1])
        XCTAssertTrue(harness.panel.isHidden)
        XCTAssertEqual(harness.commits, 1)
    }

    func test_midWordPickAddsTheFinishingSpace() {
        let harness = makeHarness(precedingText: "the questoi")
        harness.controller.presentChoices(harness.spellingOffer(typo: "questoi", candidates: ["questions", "question"]))

        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        XCTAssertEqual(harness.inserter.replacements.first?.text, "questions ")
        XCTAssertEqual(harness.inserter.replacements.first?.deleteCount, 7)
    }

    func test_commitSkipsWhenTheWordChangedUnderTheList() {
        let harness = makeHarness(precedingText: "I think wich ")
        harness.controller.presentChoices(harness.spellingOffer(typo: "wich", candidates: ["which", "with"]))
        harness.focus.setPrecedingText("I think which ")

        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        XCTAssertTrue(harness.inserter.replacements.isEmpty)
    }

    func test_typingLettersKeepsListAndPassesKeysThrough() {
        let harness = makeHarness(precedingText: "the questo")
        harness.controller.presentChoices(harness.spellingOffer(typo: "questo", candidates: ["question", "questions"]))

        let involved = harness.controller.observe(CapturedInputEvent(kind: .textMutation, keyCode: 34, characters: "i", flags: []))

        XCTAssertFalse(involved)
        XCTAssertEqual(harness.controller.decideCaptureKey(InputMonitorKeyEvent(keyCode: 34)), .notHandled)
        XCTAssertFalse(harness.panel.isHidden)
    }

    func test_escapeClosesAndIsConsumed() {
        let harness = makeHarness(precedingText: "I think wich ")
        harness.controller.presentChoices(harness.spellingOffer(typo: "wich", candidates: ["which", "with"]))

        XCTAssertTrue(harness.controller.observe(Self.key(53)))

        XCTAssertEqual(harness.controller.decideCaptureKey(InputMonitorKeyEvent(keyCode: 53)), .consume)
        XCTAssertTrue(harness.panel.isHidden)
        XCTAssertFalse(harness.controller.isCapturing)
    }

    func test_armedAlternates_openOnlyOnDownAndInsertWholeChoice() {
        let harness = makeHarness(precedingText: "Can we meet ")
        harness.controller.armChoices(CandidateOffer(
            source: .continuation,
            candidates: ["tomorrow morning", "next week"],
            scores: [],
            caretRect: .zero,
            focusChangeSequence: 1
        ))
        XCTAssertTrue(harness.panel.isHidden, "An armed offer stays invisible")

        XCTAssertTrue(harness.controller.observe(Self.key(125)))
        XCTAssertFalse(harness.panel.isHidden)
        _ = harness.controller.observe(Self.key(125))
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        XCTAssertEqual(harness.inserter.insertedChunks, ["next week"])
        XCTAssertEqual(harness.metrics.counters.alternatesOpened, 1)
        XCTAssertEqual(harness.metrics.counters.alternatesPicked, 1)
    }

    func test_armedAlternates_disarmOnAnyOtherKey() {
        let harness = makeHarness(precedingText: "Can we meet ")
        harness.controller.armChoices(CandidateOffer(
            source: .continuation, candidates: ["a", "b"], scores: [], caretRect: .zero, focusChangeSequence: 1
        ))

        XCTAssertFalse(harness.controller.observe(Self.key(48)))
        XCTAssertFalse(harness.controller.observe(Self.key(125)), "Down after disarming must move the caret")
        XCTAssertTrue(harness.panel.isHidden)
    }

    func test_focusChangeClosesTheList() {
        let harness = makeHarness(precedingText: "I think wich ")
        harness.controller.presentChoices(harness.spellingOffer(typo: "wich", candidates: ["which", "with"]))

        harness.focus.publish(precedingText: "other field", focusChangeSequence: 2)

        XCTAssertTrue(harness.panel.isHidden)
        XCTAssertFalse(harness.controller.isCapturing)
    }

    func test_spellingBar_opensOnBestFixAndTabTakesIt() {
        // #given the iPhone-style bar: typed word, best fix, runner-up
        let harness = makeHarness(precedingText: "I think wich ")
        harness.controller.presentChoices(harness.barOffer(typo: "wich", fixes: ["which", "with"]))
        XCTAssertEqual(harness.panel.selectedIndex, 1)

        // #when Tab is pressed
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        // #then the middle slot is typed
        XCTAssertEqual(harness.inserter.replacements.first?.text, "which ")
    }

    func test_spellingBar_leftAndRightMoveAlongTheBar() {
        // #given a bar opened on the middle slot
        let harness = makeHarness(precedingText: "I think wich ")
        harness.controller.presentChoices(harness.barOffer(typo: "wich", fixes: ["which", "with"]))

        // #when Right, then Tab
        XCTAssertTrue(harness.controller.observe(Self.key(124)))
        XCTAssertEqual(harness.controller.decideCaptureKey(InputMonitorKeyEvent(keyCode: 124)), .consume)
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        // #then the right-hand slot is typed
        XCTAssertEqual(harness.inserter.replacements.first?.text, "with ")
    }

    func test_spellingBar_returnWithoutNavigating_reachesTheApp() {
        let harness = makeHarness(precedingText: "I think wich ")
        harness.controller.presentChoices(harness.barOffer(typo: "wich", fixes: ["which", "with"]))

        let involved = harness.controller.observe(Self.key(36))

        XCTAssertFalse(involved)
        XCTAssertEqual(harness.controller.decideCaptureKey(InputMonitorKeyEvent(keyCode: 36)), .notHandled)
        XCTAssertTrue(harness.panel.isHidden)
        XCTAssertTrue(harness.inserter.replacements.isEmpty)
    }

    func test_spellingBar_optionDigitPicksSlotDirectly() {
        let harness = makeHarness(precedingText: "I think wich ")
        harness.controller.presentChoices(harness.barOffer(typo: "wich", fixes: ["which", "with"]))

        XCTAssertTrue(harness.controller.observe(CapturedInputEvent(kind: .textMutation, keyCode: 20, characters: "£", flags: .maskAlternate)))
        flushMainQueue()

        XCTAssertEqual(harness.inserter.replacements.first?.text, "with ")
    }

    func test_spellingBar_keepingTheTypedWordRemembersIt() {
        // #given a mid-word bar
        let harness = makeHarness(precedingText: "ask Kubernets")
        harness.controller.presentChoices(harness.barOffer(typo: "Kubernets", fixes: ["Kubernetes"]))

        // #when the quoted slot is picked
        _ = harness.controller.observe(Self.key(126))
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        // #then only a space is typed and the word is no longer flagged
        XCTAssertTrue(harness.inserter.replacements.isEmpty)
        XCTAssertEqual(harness.inserter.insertedChunks, [" "])
        XCTAssertTrue(harness.memory.isKept("kubernets"))
    }

    // MARK: - Harness

    @MainActor
    private struct Harness {
        let controller: CandidateListController
        let panel: RecordingCandidatePanel
        let focus: MutableFocus
        let inserter: RigInserter
        let memory: PersonalCorrectionMemory
        let metrics: SuggestionQualityMetricsStore
        let commitCounter: CommitCounter

        var commits: Int { commitCounter.value }

        func barOffer(typo: String, fixes: [String]) -> CandidateOffer {
            var offer = spellingOffer(typo: typo, candidates: [typo] + fixes)
            offer.preferredIndex = 1
            return offer
        }

        func spellingOffer(typo: String, candidates: [String]) -> CandidateOffer {
            CandidateOffer(
                source: .spelling(typo: typo),
                candidates: candidates,
                scores: candidates.map { _ in 0.8 },
                caretRect: .zero,
                focusChangeSequence: 1
            )
        }
    }

    private func makeHarness(precedingText: String) -> Harness {
        let suite = "CandidateListControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let panel = RecordingCandidatePanel()
        let focus = MutableFocus(precedingText: precedingText)
        let inserter = RigInserter()
        let memory = PersonalCorrectionMemory(userDefaults: defaults)
        let metrics = SuggestionQualityMetricsStore(userDefaults: defaults)
        let counter = CommitCounter()
        let controller = CandidateListController(
            panel: panel,
            focusModel: focus,
            inserter: inserter,
            isWordAcceptKey: { $0.keyCode == 48 },
            acceptKeyLabel: { "Tab" },
            correctionMemory: memory,
            qualityMetricsStore: metrics
        )
        controller.onCommitted = { counter.value += 1 }
        controller.start()
        let owned: [AnyObject] = [controller, panel, focus, inserter, memory, metrics, counter]
        retained.append(contentsOf: owned)
        return Harness(
            controller: controller,
            panel: panel,
            focus: focus,
            inserter: inserter,
            memory: memory,
            metrics: metrics,
            commitCounter: counter
        )
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
private final class CommitCounter {
    var value = 0
}

@MainActor
private final class RecordingCandidatePanel: CandidateListPanelPresenting {
    var onSelectIndex: ((Int) -> Void)?
    var onClickOutside: (() -> Void)?
    private(set) var isHidden = true
    private(set) var selectedIndex = 0

    func show(offer: CandidateOffer, selectedIndex: Int, acceptKeyLabel: String) {
        isHidden = false
        self.selectedIndex = selectedIndex
    }

    func setSelectedIndex(_ index: Int) {
        selectedIndex = index
    }

    func showFlash(typo: String, correction: String, caretRect: CGRect) {}

    func showSentenceFlash(segments: [SentenceFixSegment], caretRect: CGRect) {}

    func showSentenceReview(_ review: SentenceReviewPresentation, caretRect: CGRect, acceptKeyLabel: String) {
        isHidden = false
    }

    func showSentenceFix(segments: [SentenceFixSegment], caretRect: CGRect, acceptKeyLabel: String) {
        isHidden = false
    }

    func hide() {
        isHidden = true
    }
}

@MainActor
private final class MutableFocus: SuggestionFocusProviding {
    private(set) var snapshot: FocusSnapshot
    private let subject = PassthroughSubject<FocusSnapshot, Never>()
    var snapshotPublisher: AnyPublisher<FocusSnapshot, Never> { subject.eraseToAnyPublisher() }

    init(precedingText: String) {
        snapshot = Self.make(precedingText: precedingText, focusChangeSequence: 1)
    }

    func refreshNow() {}

    func setPrecedingText(_ text: String) {
        snapshot = Self.make(precedingText: text, focusChangeSequence: 1)
    }

    func publish(precedingText: String, focusChangeSequence: UInt64) {
        snapshot = Self.make(precedingText: precedingText, focusChangeSequence: focusChangeSequence)
        subject.send(snapshot)
    }

    private static func make(precedingText: String, focusChangeSequence: UInt64) -> FocusSnapshot {
        FocusSnapshot(
            applicationName: "TestApp",
            bundleIdentifier: "com.test.app",
            capability: .supported,
            context: CotabbyTestFixtures.focusedInputSnapshot(
                precedingText: precedingText,
                focusChangeSequence: focusChangeSequence
            )
        )
    }
}
