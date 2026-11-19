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

    func test_escapeOnTheSpellingBar_reportsTheDismissal() {
        let harness = makeHarness(precedingText: "I think wich ")
        var dismissals = 0
        harness.controller.onDismissedByEscape = { dismissals += 1 }
        harness.controller.presentChoices(harness.spellingOffer(typo: "wich", candidates: ["which", "with"]))

        _ = harness.controller.observe(Self.key(53))

        XCTAssertEqual(dismissals, 1)
    }

    func test_shiftArrow_closesTheBarAndReachesTheApp() {
        let harness = makeHarness(precedingText: "I think wich ")
        harness.controller.presentChoices(harness.spellingOffer(typo: "wich", candidates: ["which", "with"]))

        let handled = harness.controller.observe(
            CapturedInputEvent(kind: .navigation, keyCode: 123, characters: "", flags: .maskShift)
        )

        XCTAssertFalse(handled)
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

    func test_focusUpdateWithTheCaretInPlace_doesNotPlaceTheBarAgain() {
        // #given a bar that has followed the caret once
        let harness = makeHarness(precedingText: "I think wich")
        harness.controller.presentChoices(harness.spellingOffer(typo: "wich", candidates: ["wich", "which", "with"]))
        harness.focus.publish(precedingText: "I think wich", focusChangeSequence: 1)
        let showsAfterTheMove = harness.panel.showCount

        // #when the same caret position is published again (most focus updates are repeats)
        harness.focus.publish(precedingText: "I think wich", focusChangeSequence: 1)

        // #then the panel is not asked to place itself again
        XCTAssertEqual(harness.panel.showCount, showsAfterTheMove)
        XCTAssertFalse(harness.panel.isHidden)
    }

    func test_focusChangeClosesTheList() {
        let harness = makeHarness(precedingText: "I think wich ")
        harness.controller.presentChoices(harness.spellingOffer(typo: "wich", candidates: ["which", "with"]))

        harness.focus.publish(precedingText: "other field", focusChangeSequence: 2)

        XCTAssertTrue(harness.panel.isHidden)
        XCTAssertFalse(harness.controller.isCapturing)
    }

    func test_leftAlone_theBarCloses_andStaysClosedUntilAKey() {
        // #given a spelling bar, and a writer who typed a moment ago
        let idle = InlinePanelIdleTimer(seconds: 0.05)
        let harness = makeHarness(precedingText: "I think wich ", idle: idle)
        let offer = harness.spellingOffer(typo: "wich", candidates: ["which", "with"])
        idle.noteActivity()
        harness.controller.presentChoices(offer)
        XCTAssertFalse(harness.panel.isHidden)

        // #when no key follows for longer than the idle time
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        // #then the bar is closed and takes no keys
        XCTAssertTrue(harness.panel.isHidden)
        XCTAssertFalse(harness.controller.isCapturing)

        // #when the same offer is made again without a key, as a re-run of the spelling gate would
        harness.controller.presentChoices(offer)

        // #then it stays closed
        XCTAssertTrue(harness.panel.isHidden)

        // #when the writer presses a key and the gate offers again
        idle.noteActivity()
        harness.controller.presentChoices(offer)

        // #then the bar is back
        XCTAssertFalse(harness.panel.isHidden)
        XCTAssertTrue(harness.controller.isCapturing)
    }

    func test_fieldThatOnlyChangedItsFrame_keepsItsBar_andAPickStillTypes() {
        // #given a spelling bar in a message box
        let harness = makeHarness(precedingText: "I think wich ")
        harness.controller.presentChoices(harness.spellingOffer(typo: "wich", candidates: ["wich", "which", "with"]))

        // #when the box grows a line: the same element, reported under a new number
        harness.focus.publish(precedingText: "I think wich ", focusChangeSequence: 2, sameElement: true)

        // #then the bar is still up and still takes a pick
        XCTAssertFalse(harness.panel.isHidden)
        XCTAssertTrue(harness.controller.isCapturing)
        _ = harness.controller.observe(Self.key(125))
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()
        XCTAssertEqual(harness.inserter.replacements.first?.text, "which ")
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

    // MARK: - The space a pick types

    func test_pickBeforeExistingPunctuation_typesNoSpace() {
        // #given the caret right after a slip, with a period and more text already after it
        let harness = makeHarness(precedingText: "Call my dady", trailingText: ". Then")
        harness.controller.presentChoices(harness.barOffer(typo: "dady", fixes: ["dad", "day"]))

        // #when the best fix is picked
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        // #then only the word is typed: `Call my dad. Then`, not `Call my dad . Then`
        XCTAssertEqual(harness.inserter.replacements.map(\.text), ["dad"])
    }

    func test_pickBeforeAnExistingSpace_doesNotTypeASecondOne() {
        // #given the caret between a slip and the space before the next word
        let harness = makeHarness(precedingText: "my dady", trailingText: " and more")
        harness.controller.presentChoices(harness.barOffer(typo: "dady", fixes: ["dad", "day"]))

        // #when the best fix is picked
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        // #then the field reads `my dad and more`
        XCTAssertEqual(harness.inserter.replacements.map(\.text), ["dad"])
    }

    func test_pickAtTheEndOfALineWithTextBelow_stillTypesTheSpace() {
        // #given a slip at the end of its line; the next paragraph is not text after the word
        let harness = makeHarness(precedingText: "my dady", trailingText: "\nNext paragraph")
        harness.controller.presentChoices(harness.barOffer(typo: "dady", fixes: ["dad", "day"]))

        // #when the best fix is picked
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        // #then the word is finished with a space, as at the end of the field
        XCTAssertEqual(harness.inserter.replacements.map(\.text), ["dad "])
    }

    func test_pickWithTextAfterTheCaret_doesNotAnnounceASpaceItDidNotType() {
        // #given a listener for "the pick typed its own space" and a caret in front of a comma
        let harness = makeHarness(precedingText: "I saw my dady", trailingText: ", and left")
        var announced: [String] = []
        harness.controller.onPickAddedSpace = { announced.append($0) }
        harness.controller.presentChoices(harness.barOffer(typo: "dady", fixes: ["dad", "day"]))

        // #when the best fix is picked
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        // #then nothing is announced, so the word strip does not swallow the writer's next Space
        XCTAssertEqual(announced, [])
    }

    func test_midWordPickAtTheEndOfTheField_announcesTheTextItLeaves() {
        // #given a listener and a mid-word slip with an emoji earlier in the field
        let harness = makeHarness(precedingText: "👍🏽 my dady")
        var announced: [String] = []
        harness.controller.onPickAddedSpace = { announced.append($0) }
        harness.controller.presentChoices(harness.barOffer(typo: "dady", fixes: ["dad", "day"]))

        // #when the best fix is picked
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        // #then the announced text is the field as the keys leave it
        XCTAssertEqual(announced, ["👍🏽 my dad "])
    }

    func test_keepingTheTypedWordBeforeExistingText_typesNothing() {
        // #given a mid-word bar on a name, inside brackets the host closed for the writer
        let harness = makeHarness(precedingText: "ask (Kubernets", trailingText: ")")
        harness.controller.presentChoices(harness.barOffer(typo: "Kubernets", fixes: ["Kubernetes"]))

        // #when the quoted slot is picked
        _ = harness.controller.observe(Self.key(126))
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        // #then no space lands between the word and the bracket
        XCTAssertEqual(harness.inserter.insertedChunks, [])
    }

    func test_pickAfterANonBreakingSpace_keepsItAndAddsNoSecondSpace() {
        // #given a finished slip whose space the host stored as U+00A0
        let harness = makeHarness(precedingText: "my dady\u{00A0}")
        harness.controller.presentChoices(harness.barOffer(typo: "dady", fixes: ["dad", "day"]))

        // #when the best fix is picked
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        // #then the word and the same space are typed back, nothing more
        XCTAssertEqual(harness.inserter.replacements.map(\.text), ["dad\u{00A0}"])
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

    private func makeHarness(precedingText: String, trailingText: String = "", idle: InlinePanelIdleTimer? = nil) -> Harness {
        let suite = "CandidateListControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let panel = RecordingCandidatePanel()
        let focus = MutableFocus(precedingText: precedingText, trailingText: trailingText)
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
            qualityMetricsStore: metrics,
            idle: idle
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
    private(set) var showCount = 0

    func show(offer: CandidateOffer, selectedIndex: Int, acceptKeyLabel: String) {
        showCount += 1
        isHidden = false
        self.selectedIndex = selectedIndex
    }

    func setSelectedIndex(_ index: Int) {
        selectedIndex = index
    }

    func showFlash(typo: String, correction: String, caretRect: CGRect) {}

    func showWordStrip(words: [String], selectedIndex: Int?, caretRect: CGRect) {}

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

    init(precedingText: String, trailingText: String = "") {
        snapshot = Self.make(precedingText: precedingText, trailingText: trailingText, focusChangeSequence: 1)
    }

    func refreshNow() {}

    func setPrecedingText(_ text: String) {
        snapshot = Self.make(precedingText: text, focusChangeSequence: 1)
    }

    /// Another field unless `sameElement` says the field only got a new number (its frame changed).
    func publish(precedingText: String, focusChangeSequence: UInt64, sameElement: Bool = false) {
        snapshot = Self.make(
            precedingText: precedingText, focusChangeSequence: focusChangeSequence,
            elementIdentifier: sameElement ? "field-1" : "field-\(focusChangeSequence)"
        )
        subject.send(snapshot)
    }

    private static func make(
        precedingText: String, trailingText: String = "", focusChangeSequence: UInt64, elementIdentifier: String = "field-1"
    ) -> FocusSnapshot {
        FocusSnapshot(
            applicationName: "TestApp",
            bundleIdentifier: "com.test.app",
            capability: .supported,
            context: CotabbyTestFixtures.focusedInputSnapshot(
                elementIdentifier: elementIdentifier,
                precedingText: precedingText,
                trailingText: trailingText,
                focusChangeSequence: focusChangeSequence
            )
        )
    }
}
