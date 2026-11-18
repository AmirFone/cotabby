import Combine
import CoreGraphics
import XCTest
@preconcurrency @testable import Cotabby

/// Locks down the word strip's key contract: Return and Option+digit pick, Tab and letters never do,
/// Return still reaches the app where it means send or new line, and a pick replaces only the typed
/// prefix and immediately offers the next word.
@MainActor
final class WordPredictionControllerTests: XCTestCase {
    private var retained: [AnyObject] = []

    override func tearDown() {
        retained.removeAll()
        super.tearDown()
    }

    func test_tabTypesTheFirstWordAndPredictsTheNext() {
        // #given a strip after "I want "
        let harness = makeHarness(precedingText: "I want ")
        harness.note("I want ")

        // #when Tab is pressed
        XCTAssertTrue(harness.controller.observe(Self.key(48)))
        XCTAssertEqual(harness.controller.decideCaptureKey(InputMonitorKeyEvent(keyCode: 48)), .consume)
        flushMainQueue()

        // #then the top word is typed and the next strip shows
        XCTAssertEqual(harness.inserter.insertedChunks, ["to "])
        XCTAssertEqual(harness.panel.words, ["go", "be", "get", "the", "to"])
        XCTAssertEqual(harness.commits, 1)
    }

    func test_tabCompletesTheTypedPrefix() {
        let harness = makeHarness(precedingText: "I want to g")
        harness.note("I want to g")

        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        XCTAssertEqual(harness.inserter.replacements.first?.deleteCount, 1)
        XCTAssertEqual(harness.inserter.replacements.first?.text, "go ")
    }

    func test_tabCompletesAWordBegunRightAfterADot_andLeavesTheWordBeforeItAlone() {
        // #given a word begun against a dot, as in a table name (`want.t`)
        let harness = makeHarness(precedingText: "I want.t")
        harness.note("I want.t")

        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        // #then only the one letter typed is replaced, and the pick is not capitalized
        XCTAssertEqual(harness.inserter.replacements.first?.deleteCount, 1)
        XCTAssertEqual(harness.inserter.replacements.first?.text, "to ")
    }

    func test_rightAfterASlash_theStripSuggestsTheNextWord() {
        let harness = makeHarness(precedingText: "I want/")
        harness.note("I want/")
        flushMainQueue()

        XCTAssertEqual(harness.panel.words.first, "to")
    }

    func test_inASingleLineField_tabMovesFocusAndOptionOneTakesTheFirstWord() {
        // #given a strip in a search box
        let harness = makeHarness(precedingText: "I want ")
        harness.focus.role = "AXSearchField"
        harness.focus.setPrecedingText("I want ")
        harness.note("I want ")

        // #when Tab, then Option+1
        let tabClaimed = harness.controller.observe(Self.key(48))
        _ = harness.controller.observe(Self.key(18, flags: .maskAlternate))
        flushMainQueue()
        let fence = expectation(description: "modifier release")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { fence.fulfill() }
        wait(for: [fence], timeout: 1)

        // #then Tab reached the app, the strip shows no Tab hint, and Option+1 typed the word
        XCTAssertFalse(tabClaimed)
        XCTAssertNil(harness.panel.selectedIndex)
        XCTAssertEqual(harness.inserter.insertedChunks, ["to "])
    }

    func test_inACodeEditor_tabIndents() {
        let harness = makeHarness(precedingText: "I want ")
        harness.focus.bundleIdentifier = "com.microsoft.VSCode"
        harness.focus.setPrecedingText("I want ")
        harness.note("I want ")

        XCTAssertFalse(harness.controller.observe(Self.key(48)))
        XCTAssertNil(harness.panel.selectedIndex)
    }

    func test_punctuationRightAfterAPick_goesBeforeThePickedSpace() {
        // #given "to " was just picked
        let harness = makeHarness(precedingText: "I want ")
        harness.note("I want ")
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()
        harness.focus.setPrecedingText("I want to ")

        // #when a period is typed
        let claimed = harness.controller.observe(CapturedInputEvent(kind: .textMutation, keyCode: 47, characters: ".", flags: []))
        let fence = expectation(description: "space moved")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { fence.fulfill() }
        wait(for: [fence], timeout: 1)

        // #then the space moves after the period
        XCTAssertTrue(claimed)
        XCTAssertEqual(harness.inserter.replacements.last?.deleteCount, 1)
        XCTAssertEqual(harness.inserter.replacements.last?.text, ". ")
    }

    func test_spaceRightAfterAPick_isSwallowed() {
        let harness = makeHarness(precedingText: "I want ")
        harness.note("I want ")
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        XCTAssertTrue(harness.controller.observe(CapturedInputEvent(kind: .textMutation, keyCode: 49, characters: " ", flags: [])))
        XCTAssertEqual(harness.controller.decideCaptureKey(InputMonitorKeyEvent(keyCode: 49)), .consume)
    }

    func test_punctuationAfterOtherTyping_isLeftAlone() {
        let harness = makeHarness(precedingText: "I want ")
        harness.note("I want ")
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()
        _ = harness.controller.observe(CapturedInputEvent(kind: .textMutation, keyCode: 17, characters: "t", flags: []))

        XCTAssertFalse(harness.controller.observe(CapturedInputEvent(kind: .textMutation, keyCode: 47, characters: ".", flags: [])))
    }

    func test_returnAlwaysReachesTheApp() {
        let harness = makeHarness(precedingText: "I want ")
        harness.note("I want ")

        XCTAssertFalse(harness.controller.observe(Self.key(36)))
        XCTAssertEqual(harness.controller.decideCaptureKey(InputMonitorKeyEvent(keyCode: 36)), .notHandled)
        XCTAssertTrue(harness.inserter.insertedChunks.isEmpty)
    }

    func test_shiftTabIsNotClaimed() {
        let harness = makeHarness(precedingText: "I want ")
        harness.note("I want ")

        XCTAssertFalse(harness.controller.observe(Self.key(48, flags: .maskShift)))
        XCTAssertEqual(harness.controller.decideCaptureKey(InputMonitorKeyEvent(keyCode: 48)), .notHandled)
    }

    func test_optionDigit_picksThatSlotAndReplacesThePrefix() {
        let harness = makeHarness(precedingText: "I want to g")
        harness.note("I want to g")

        XCTAssertTrue(harness.controller.observe(Self.key(19, flags: .maskAlternate)))
        flushMainQueue()

        XCTAssertEqual(harness.inserter.replacements.first?.deleteCount, 1)
        XCTAssertEqual(harness.inserter.replacements.first?.text, "get ")
    }

    func test_escapeHidesUntilTheNextWord() {
        let harness = makeHarness(precedingText: "I want ")
        harness.note("I want ")

        XCTAssertFalse(harness.controller.observe(Self.key(53)))
        XCTAssertTrue(harness.panel.isHidden)
        harness.note("I want t")
        XCTAssertTrue(harness.panel.isHidden, "Still the same word, so the strip stays away")

        _ = harness.controller.observe(CapturedInputEvent(kind: .textMutation, keyCode: 49, characters: " ", flags: []))
        harness.note("I want to ")
        XCTAssertFalse(harness.panel.isHidden)
    }

    func test_typedLetter_updatesTheStripBeforeTheHostPublishes() {
        // #given a strip after "I want to "
        let harness = makeHarness(precedingText: "I want to ")
        harness.note("I want to ")

        // #when "g" is typed and the field has not been re-read yet
        _ = harness.controller.observe(CapturedInputEvent(kind: .textMutation, keyCode: 5, characters: "g", flags: []))

        // #then the strip already completes "g"
        XCTAssertEqual(harness.panel.words.first, "go")
        XCTAssertFalse(harness.panel.words.contains("be"))
    }

    func test_typedLetter_leavesTheStripAlone_whenTheSpellingGateOwnsTheWord() {
        // #given a strip after "I want to ", and a spelling fix already decided for the next key
        let harness = makeHarness(precedingText: "I want to ", isSpellingPending: { true })
        harness.note("I want to ")
        let before = harness.panel.words

        // #when a letter is typed
        _ = harness.controller.observe(CapturedInputEvent(kind: .textMutation, keyCode: 5, characters: "g", flags: []))

        // #then the strip is not redrawn for a word the gate is about to take over
        XCTAssertEqual(harness.panel.words, before)
    }

    func test_secondKeyBeforeARead_doesNotGuessAgain() {
        let harness = makeHarness(precedingText: "I want to ")
        harness.note("I want to ")
        _ = harness.controller.observe(CapturedInputEvent(kind: .textMutation, keyCode: 5, characters: "g", flags: []))
        let afterFirst = harness.panel.words

        _ = harness.controller.observe(CapturedInputEvent(kind: .textMutation, keyCode: 31, characters: "o", flags: []))

        XCTAssertEqual(harness.panel.words, afterFirst)
    }

    func test_staleStrip_isRecomputedFromTheFieldOnTab() {
        // #given a strip for "I want " and a letter typed since
        let harness = makeHarness(precedingText: "I want ")
        harness.note("I want ")
        _ = harness.controller.observe(CapturedInputEvent(kind: .textMutation, keyCode: 17, characters: "t", flags: []))
        harness.focus.setPrecedingText("I want t")

        // #when Tab is pressed before the coordinator refreshed the strip
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        // #then the pick completes the typed "t" instead of appending after it
        XCTAssertEqual(harness.inserter.replacements.first?.deleteCount, 1)
        XCTAssertEqual(harness.inserter.replacements.first?.text, "to ")
    }

    // MARK: - Language model

    func test_languageModelAnswer_redrawsTheStripInItsOrder() {
        // #given the strip drawn from the table, before the language model has answered
        let answer = LanguageModelFixture.scores(textBefore: "I want to ", ["be": 0.6, "go": 0.2, "get": 0.05])
        var isReady = false
        let harness = makeHarness(precedingText: "I want to ", languageModel: { _ in isReady ? answer : nil })
        harness.note("I want to ")
        XCTAssertEqual(Array(harness.panel.words.prefix(2)), ["go", "be"])

        // #when the model's answer arrives
        isReady = true
        harness.controller.redrawWithLanguageModel()

        // #then the strip shows the model's order
        XCTAssertEqual(Array(harness.panel.words.prefix(3)), ["be", "go", "get"])
    }

    func test_languageModelAnswer_doesNotMoveWordsUnderAHighlightTheWriterMoved() {
        // #given the writer has stepped the highlight to the second word
        let answer = LanguageModelFixture.scores(textBefore: "I want to ", ["be": 0.6, "go": 0.2, "get": 0.05])
        var isReady = false
        let harness = makeHarness(precedingText: "I want to ", languageModel: { _ in isReady ? answer : nil })
        harness.note("I want to ")
        XCTAssertTrue(harness.controller.observe(Self.key(124)))
        XCTAssertEqual(harness.controller.decideCaptureKey(InputMonitorKeyEvent(keyCode: 124)), .consume)

        // #when the model's answer arrives
        isReady = true
        harness.controller.redrawWithLanguageModel()

        // #then the words stay where they were
        XCTAssertEqual(Array(harness.panel.words.prefix(2)), ["go", "be"])
    }

    func test_whileTheLanguageModelIsWorking_theStripWaitsForItsOrder() {
        // #given a model that is still working on its answer for this text
        let answer = LanguageModelFixture.scores(textBefore: "I want to ", ["be": 0.6, "go": 0.2, "get": 0.05])
        var isReady = false
        let harness = makeHarness(
            precedingText: "I want to ",
            languageModel: { _ in isReady ? answer : nil },
            isLanguageModelPending: { _ in !isReady }
        )

        // #when the text is noted
        harness.note("I want to ")

        // #then nothing is drawn yet: the table's order would only be replaced a moment later
        XCTAssertTrue(harness.panel.isHidden)

        // #when the answer arrives
        isReady = true
        harness.controller.redrawWithLanguageModel()

        // #then the strip appears once, in the model's order
        XCTAssertEqual(Array(harness.panel.words.prefix(3)), ["be", "go", "get"])
    }

    func test_languageModelTakingTooLong_showsTheTableOrderAfterTheWait() {
        // #given a model that never answers
        let harness = makeHarness(precedingText: "I want to ", isLanguageModelPending: { _ in true })

        // #when the text is noted and the wait runs out
        harness.note("I want to ")
        XCTAssertTrue(harness.panel.isHidden)
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))

        // #then the table's list is shown after all
        XCTAssertEqual(Array(harness.panel.words.prefix(2)), ["go", "be"])
    }

    func test_languageModelAnswer_afterTheStripIsGone_showsNothing() {
        let answer = LanguageModelFixture.scores(textBefore: "I want to ", ["be": 0.6])
        let harness = makeHarness(precedingText: "I want to ", languageModel: { _ in answer })
        harness.note("I want to ")
        harness.controller.hidePredictions()

        harness.controller.redrawWithLanguageModel()

        XCTAssertTrue(harness.panel.isHidden)
    }

    func test_rightArrow_movesTheHighlightAndReturnTypesThatWord() {
        // #given the strip after "I want to " with the caret at the end of the line
        let harness = makeHarness(precedingText: "I want to ")
        harness.note("I want to ")
        XCTAssertEqual(Array(harness.panel.words.prefix(2)), ["go", "be"])

        // #when Right moves to the second word and Return takes it
        XCTAssertTrue(harness.controller.observe(Self.key(124)))
        XCTAssertEqual(harness.controller.decideCaptureKey(InputMonitorKeyEvent(keyCode: 124)), .consume)
        XCTAssertEqual(harness.panel.selectedIndex, 1)
        XCTAssertTrue(harness.controller.observe(Self.key(36)))
        flushMainQueue()

        // #then the second word is typed, not a new line
        XCTAssertEqual(harness.inserter.insertedChunks, ["be "])
    }

    func test_leftArrow_stepsBackOnlyAfterRightMovedTheHighlight() {
        let harness = makeHarness(precedingText: "I want to ")
        harness.note("I want to ")

        // Right twice, Left once: on the second word; Tab takes the highlighted word.
        _ = harness.controller.observe(Self.key(124))
        _ = harness.controller.observe(Self.key(124))
        XCTAssertTrue(harness.controller.observe(Self.key(123)))
        XCTAssertEqual(harness.panel.selectedIndex, 1)
        XCTAssertTrue(harness.controller.observe(Self.key(48)))
        flushMainQueue()

        XCTAssertEqual(harness.inserter.insertedChunks, ["be "])
    }

    func test_leftArrowFirst_isCaretMovement() {
        let harness = makeHarness(precedingText: "I want to ")
        harness.note("I want to ")

        XCTAssertFalse(harness.controller.observe(Self.key(123)))

        XCTAssertTrue(harness.panel.isHidden)
    }

    func test_rightArrowWithTextAfterTheCaret_isCaretMovement() {
        // #given the caret in the middle of a line
        let harness = makeHarness(precedingText: "I want to ", trailingText: "today")
        harness.note("I want to ")

        // #when Right is pressed
        let claimed = harness.controller.observe(Self.key(124))

        // #then the key is the app's, and the strip steps aside
        XCTAssertFalse(claimed)
        XCTAssertTrue(harness.panel.isHidden)
    }

    func test_typingAfterArrowing_putsTheHighlightBackOnTheFirstWord() {
        let harness = makeHarness(precedingText: "I want to ")
        harness.note("I want to ")
        _ = harness.controller.observe(Self.key(124))
        XCTAssertEqual(harness.controller.arrowedSlot, 1)

        // The writer keeps typing instead: new words, highlight back at the start.
        harness.note("I want ")

        XCTAssertNil(harness.controller.arrowedSlot)
        XCTAssertEqual(harness.panel.selectedIndex, 0)
    }

    func test_arrowsAreCaretMovement() {
        let harness = makeHarness(precedingText: "I want ")
        harness.note("I want ")

        XCTAssertFalse(harness.controller.observe(Self.key(126)))
        XCTAssertEqual(harness.controller.decideCaptureKey(InputMonitorKeyEvent(keyCode: 126)), .notHandled)
        XCTAssertTrue(harness.panel.isHidden)
    }

    func test_focusChange_hidesTheStrip() {
        let harness = makeHarness(precedingText: "I want ")
        harness.note("I want ")

        harness.focus.publish(precedingText: "", focusChangeSequence: 2)

        XCTAssertTrue(harness.panel.isHidden)
        XCTAssertFalse(harness.controller.isCapturing)
    }

    func test_finishedSentenceIsLearnedOnce() {
        let harness = makeHarness(precedingText: "We ship on Friday. ")
        harness.note("We ship on Friday. ")
        harness.note("We ship on Friday. ")
        flushMainQueue()

        XCTAssertEqual(harness.learned.values, ["We ship on Friday"])
    }

    func test_chatLineSentWithReturn_isLearned() {
        let harness = makeHarness(precedingText: "see you at the gym")
        harness.note("see you at the gym")

        _ = harness.controller.observe(Self.key(36))

        XCTAssertEqual(harness.learned.values, ["see you at the gym"])
    }

    func test_chatLineEndingInAPeriod_sentWithReturn_isLearnedAndSettledAsWritten() {
        // #given a message that ends in a full stop, with no space after it
        let harness = makeHarness(precedingText: "Sure. That works for me.")
        var settled: [String] = []
        harness.controller.onSentenceSettled = { settled.append($0) }
        harness.note("Sure. That works for me.")

        // #when it is sent and the field is cleared
        _ = harness.controller.observe(Self.key(36))
        harness.focus.setPrecedingText("")
        flushMainQueue()

        // #then its last sentence is learned, and settled with its full stop
        XCTAssertEqual(harness.learned.values, ["That works for me"])
        XCTAssertEqual(settled, ["That works for me."])
    }

    func test_sentenceSentBeforeTheDelayHasPassed_isStillLearned_once() {
        // #given a finished sentence (full stop and a space) whose delay is still running
        let harness = makeHarness(precedingText: "We ship on Friday. ")
        harness.note("We ship on Friday. ")

        // #when the line is sent, which clears the field before the delay is over
        _ = harness.controller.observe(Self.key(36))
        harness.focus.setPrecedingText("")
        flushMainQueue()

        // #then clearing the field by sending is not the writer taking the sentence back
        XCTAssertEqual(harness.learned.values, ["We ship on Friday"])
    }

    func test_returnInAnEditor_afterAFinishedSentence_learnsItOnce() {
        // #given an editor, where Return starts a new line and the sentence stays
        let harness = makeHarness(precedingText: "We ship on Friday.")
        harness.note("We ship on Friday.")

        _ = harness.controller.observe(Self.key(36))
        harness.focus.setPrecedingText("We ship on Friday.\n")
        harness.note("We ship on Friday.\n")
        flushMainQueue()

        XCTAssertEqual(harness.learned.values, ["We ship on Friday"])
    }

    func test_sentenceDeletedBeforeTheDelay_withoutSending_isNotLearned() {
        let harness = makeHarness(precedingText: "We ship on Friday. ")
        harness.note("We ship on Friday. ")
        harness.focus.setPrecedingText("")
        flushMainQueue()

        XCTAssertEqual(harness.learned.values, [])
    }

    func test_sentenceChangedBeforeTheDelay_isNotLearned() {
        // #given a finished sentence the sentence pass then fixes
        let harness = makeHarness(precedingText: "I went to the the store. ")
        harness.note("I went to the the store. ")
        harness.focus.setPrecedingText("I went to the store. ")
        flushMainQueue()

        // #then the mistaken version is never learned
        XCTAssertEqual(harness.learned.values, [])
    }

    // MARK: - Harness

    @MainActor
    private struct Harness {
        let controller: WordPredictionController
        let panel: RecordingStripPanel
        let focus: StripFocus
        let inserter: RigInserter
        let learned: LearnedSentences
        let commitCounter: StripCommitCounter

        var commits: Int { commitCounter.value }

        func note(_ text: String) {
            controller.noteTypedText(text, caretRect: .zero, focusChangeSequence: 1)
        }
    }

    private func makeHarness(
        precedingText: String,
        trailingText: String = "",
        isSpellingPending: @escaping () -> Bool = { false },
        languageModel: @escaping (String) -> LanguageModelScores? = { _ in nil },
        isLanguageModelPending: @escaping (String) -> Bool = { _ in false }
    ) -> Harness {
        let model = NextWordModelFixture.make([
            "": (100, [("the", 30), ("to", 20)]),
            "<s>": (50, [("we", 20), ("i", 10)]),
            "want": (40, [("to", 30), ("it", 5)]),
            "want to": (30, [("go", 12), ("be", 8), ("get", 4)]),
        ])
        let sources = NextWordPredictor.Sources(
            model: model,
            completions: { _, _ in [] },
            personal: { _ in nil },
            languageModel: languageModel
        )
        let panel = RecordingStripPanel()
        let focus = StripFocus(precedingText: precedingText, trailingText: trailingText)
        let inserter = RigInserter()
        let learned = LearnedSentences()
        let counter = StripCommitCounter()
        let controller = WordPredictionController(
            panel: panel,
            focusModel: focus,
            inserter: inserter,
            predict: { NextWordPredictor.predict(textBefore: $0, sources: sources) },
            isEnabled: { true },
            learn: { learned.values.append($0) },
            isSpellingPending: isSpellingPending,
            learnDelay: 0,
            isLanguageModelPending: isLanguageModelPending,
            languageModelWait: 0.03
        )
        controller.onCommitted = { counter.value += 1 }
        controller.start()
        retained.append(contentsOf: [controller, panel, focus, inserter, learned, counter] as [AnyObject])
        return Harness(controller: controller, panel: panel, focus: focus, inserter: inserter, learned: learned, commitCounter: counter)
    }

    // MARK: - The whole strip with the real model, no screen
    //
    // The live typing test needs an unlocked screen. These run the same path without one: the
    // production predictor (bundled table, the dictionary as the app loads it, the word lists, the
    // American spellings) and the real model service behind the real controller, with only the
    // text field, the panel and the key injector stood in. They need a model file, so they run when
    // TEST_RUNNER_WORD_LM_FILE names one, like `WordLanguageModelLiveTests`.

    private func makeRealHarness(text: String = "") throws -> (harness: Harness, service: WordLanguageModelService) {
        guard let modelPath = ProcessInfo.processInfo.environment["WORD_LM_FILE"] else {
            throw XCTSkip("Set TEST_RUNNER_WORD_LM_FILE to run the strip against a real model")
        }
        let corrector = try Self.appDictionary()
        let service = WordLanguageModelService(
            modelURL: URL(fileURLWithPath: modelPath), wordListURLs: WordLanguageModelService.bundledWordListURLs()
        )
        let predict = WordPredictionController.makePredictor(
            model: try XCTUnwrap(NextWordModel.bundled()),
            symSpellCorrector: corrector,
            phrases: PersonalPhraseModel(fileURL: nil),
            languageModel: service,
            americanSpellings: try XCTUnwrap(AmericanSpellings.preferredOnThisMac(region: "US"))
        )
        let panel = RecordingStripPanel()
        let focus = StripFocus(precedingText: text)
        let inserter = RigInserter()
        let learned = LearnedSentences()
        let counter = StripCommitCounter()
        let controller = WordPredictionController(
            panel: panel,
            focusModel: focus,
            inserter: inserter,
            predict: predict,
            isEnabled: { true },
            learn: { learned.values.append($0) },
            isSpellingPending: { false },
            learnDelay: 0,
            isLanguageModelPending: { service.isAnswerPending(forTextBefore: $0) },
            languageModelWait: 0.05
        )
        service.onReady = { [weak controller] in controller?.redrawWithLanguageModel() }
        controller.onCommitted = { counter.value += 1 }
        controller.start()
        service.warmUp()
        retained.append(contentsOf: [controller, panel, focus, inserter, learned, counter, service] as [AnyObject])
        return (Harness(controller: controller, panel: panel, focus: focus, inserter: inserter, learned: learned, commitCounter: counter), service)
    }

    /// The spelling dictionary with everything the app adds to it, built once for all tests.
    private static var sharedAppDictionary: SymSpellCorrector?
    private static func appDictionary() throws -> SymSpellCorrector {
        if let sharedAppDictionary { return sharedAppDictionary }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "frequency_dictionary_en_82_765", withExtension: "txt"))
        let corrector = SymSpellCorrector(preloadLanguage: nil)
        corrector.loadForTesting(
            contents: try String(contentsOf: url, encoding: .utf8) + "\n" + SymSpellCorrector.englishOverrides()
                + "\n" + SymSpellCorrector.englishSupplement()
        )
        sharedAppDictionary = corrector
        return corrector
    }

    /// Types `added` after `existing` one key at a time, as the app sees it: the field's text
    /// changes, then the controller is told.
    private func type(_ added: String, after existing: String, into harness: Harness) {
        var text = existing
        harness.focus.setPrecedingText(text)
        for character in added {
            text.append(character)
            harness.focus.setPrecedingText(text)
            harness.note(text)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Lets the main thread run until `condition` holds; false after `timeout`.
    private func waitFor(timeout: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    func test_realModel_pastTense_putsThePastFormFirst_andTabTypesIt() throws {
        // #given a past-tense sentence typed up to the letters every form of the verb shares
        let (harness, _) = try makeRealHarness()
        type("Yesterday we walk", after: "", into: harness)

        // #then the strip leads with the past form once the model has answered
        XCTAssertTrue(waitFor { harness.panel.words.first == "walked" }, "strip shows \(harness.panel.words)")

        // #when Tab is pressed
        XCTAssertTrue(harness.controller.observe(Self.key(48)))
        flushMainQueue()

        // #then the four typed letters are replaced by the word and its space
        XCTAssertEqual(harness.inserter.replacements.first?.deleteCount, 4)
        XCTAssertEqual(harness.inserter.replacements.first?.text, "walked ")
    }

    func test_realModel_nameAlreadyInTheText_isOfferedWithItsCapital_andTyped() throws {
        // #given a text that has named someone, and the first letters of the name typed in lowercase
        let (harness, _) = try makeRealHarness()
        let before = "I asked Priyanka about the launch plan on Monday. Then I sent the notes to "
        type("pri", after: before, into: harness)

        // #then the name is offered, capitalized as the writer wrote it
        XCTAssertTrue(waitFor { harness.panel.words.contains("Priyanka") }, "strip shows \(harness.panel.words)")
        // A model that cannot take a piece back out of its memory (Qwen 3.5) gets no exact pass, so
        // it ranks the name among dictionary words by a rough estimate and need not put it first.
        guard try modelHasExactPass() else { return }
        XCTAssertTrue(waitFor { harness.panel.words.first == "Priyanka" }, "strip shows \(harness.panel.words)")

        // #when Tab is pressed, the three letters become the name
        XCTAssertTrue(harness.controller.observe(Self.key(48)))
        flushMainQueue()
        XCTAssertEqual(harness.inserter.replacements.first?.deleteCount, 3)
        XCTAssertEqual(harness.inserter.replacements.first?.text, "Priyanka ")
    }

    private func modelHasExactPass() throws -> Bool {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["WORD_LM_FILE"])
        return try XCTUnwrap(WordLanguageModelCore(
            modelURL: URL(fileURLWithPath: path), wordListURLs: WordLanguageModelService.bundledWordListURLs()
        )).canRollBack
    }

    func test_realModel_americanWordsTheDictionaryLacked_areOffered_inOneSpelling() throws {
        // #given a sentence heading for `neighbor`, which the dictionary only has as `neighbour`
        let (harness, _) = try makeRealHarness()
        type("My mom and my neigh", after: "", into: harness)

        // #then the American word leads and the British spelling is not shown beside it
        XCTAssertTrue(waitFor { harness.panel.words.first == "neighbor" }, "strip shows \(harness.panel.words)")
        XCTAssertFalse(harness.panel.words.contains("neighbour"))

        // #and the same for a word with a doubled letter in British spelling
        type("Next week I am trav", after: "", into: harness)
        XCTAssertTrue(waitFor { harness.panel.words.first == "traveling" }, "strip shows \(harness.panel.words)")
        XCTAssertFalse(harness.panel.words.contains("travelling"))
    }

    func test_realModel_finishedWord_hasTheNextListReadyAtTheSpace() throws {
        // #given a model that can look ahead, and a whole word typed with a moment to spare
        let (harness, service) = try makeRealHarness()
        type("Yesterday we walked", after: "", into: harness)
        guard waitFor(timeout: 10, { service.lookAheadText == "Yesterday we walked" }) else {
            throw XCTSkip("this model does not look ahead (it cannot wind its memory back)")
        }

        // #when the space is typed
        type(" ", after: "Yesterday we walked", into: harness)

        // #then the list for the next word is there without waiting for the model
        XCTAssertFalse(service.isAnswerPending(forTextBefore: "Yesterday we walked "))
        XCTAssertFalse(harness.panel.words.isEmpty)
    }

    func test_realModel_longDocument_keepsPredicting_andReadsOnlyItsEnd() throws {
        // #given a text several times the model's reach, ending in a past-tense sentence
        let (harness, service) = try makeRealHarness()
        let filler = (0..<120).map { "Note \($0) says the team met and agreed on the plan." }.joined(separator: " ")
        let before = filler + " Yesterday we "
        XCTAssertGreaterThan(before.utf8.count, 3 * LanguageModelContext.Reach.standard.maximumCharacters)
        type("walk", after: before, into: harness)

        // #then the strip still follows the tense, and what the model read fits its reach
        XCTAssertTrue(waitFor { harness.panel.words.first == "walked" }, "strip shows \(harness.panel.words)")
        let read = try XCTUnwrap(service.scores(forTextBefore: before + "walk")?.key.text)
        XCTAssertLessThanOrEqual(read.utf8.count, LanguageModelContext.Reach.standard.maximumCharacters)
        XCTAssertTrue(read.hasSuffix("Yesterday we"))
    }

    func test_realModel_pickAfterPick_buildsASentence() throws {
        // #given a strip after a sentence start
        let (harness, _) = try makeRealHarness()
        type("I would like ", after: "", into: harness)
        XCTAssertTrue(waitFor { !harness.panel.words.isEmpty })

        // #when Tab is pressed three times, the field taking each pick
        var text = "I would like "
        for _ in 0..<3 {
            XCTAssertTrue(waitFor { !harness.panel.words.isEmpty && !harness.panel.isHidden })
            let before = harness.inserter.insertedChunks.count
            XCTAssertTrue(harness.controller.observe(Self.key(48)))
            flushMainQueue()
            XCTAssertEqual(harness.inserter.insertedChunks.count, before + 1)
            text += harness.inserter.insertedChunks.last ?? ""
            harness.focus.setPrecedingText(text)
            harness.note(text)
        }

        // #then three words and their spaces were typed, each a real word
        XCTAssertEqual(harness.inserter.insertedChunks.count, 3)
        XCTAssertTrue(harness.inserter.insertedChunks.allSatisfy { $0.hasSuffix(" ") && $0.count > 1 })
        XCTAssertEqual(harness.commits, 3)
    }

    private func flushMainQueue() {
        let fence = expectation(description: "flush main queue")
        DispatchQueue.main.async { fence.fulfill() }
        wait(for: [fence], timeout: 1)
    }

    private static func key(_ keyCode: CGKeyCode, flags: CGEventFlags = []) -> CapturedInputEvent {
        CapturedInputEvent(kind: .navigation, keyCode: keyCode, characters: "", flags: flags)
    }
}

@MainActor
private final class StripCommitCounter {
    var value = 0
}

@MainActor
private final class LearnedSentences {
    var values: [String] = []
}

@MainActor
private final class RecordingStripPanel: CandidateListPanelPresenting {
    var onSelectIndex: ((Int) -> Void)?
    var onClickOutside: (() -> Void)?
    private(set) var isHidden = true
    private(set) var words: [String] = []

    func show(offer: CandidateOffer, selectedIndex: Int, acceptKeyLabel: String) {}
    func setSelectedIndex(_ index: Int) { selectedIndex = index }
    private(set) var selectedIndex: Int?

    func showWordStrip(words: [String], selectedIndex: Int?, caretRect: CGRect) {
        isHidden = false
        self.words = words
        self.selectedIndex = selectedIndex
    }
    func showFlash(typo: String, correction: String, caretRect: CGRect) {}
    func showSentenceFix(segments: [SentenceFixSegment], caretRect: CGRect, acceptKeyLabel: String) {}
    func showSentenceFlash(segments: [SentenceFixSegment], caretRect: CGRect) {}
    func showSentenceReview(_ review: SentenceReviewPresentation, caretRect: CGRect, acceptKeyLabel: String) {}
    func hide() {
        isHidden = true
    }
}

@MainActor
private final class StripFocus: SuggestionFocusProviding {
    private(set) var snapshot: FocusSnapshot
    private let subject = PassthroughSubject<FocusSnapshot, Never>()
    var snapshotPublisher: AnyPublisher<FocusSnapshot, Never> { subject.eraseToAnyPublisher() }
    var millisecondsSinceLastCapture: Int? { 0 }

    var role = "AXTextArea"
    var bundleIdentifier = "com.test.app"

    init(precedingText: String, trailingText: String = "") {
        snapshot = Self.make(
            precedingText: precedingText,
            trailingText: trailingText,
            focusChangeSequence: 1,
            role: "AXTextArea",
            bundleIdentifier: "com.test.app"
        )
    }

    func refreshNow() {}
    func invalidateTransientCaretCaches() {}

    func setPrecedingText(_ text: String) {
        snapshot = Self.make(precedingText: text, focusChangeSequence: 1, role: role, bundleIdentifier: bundleIdentifier)
    }

    func publish(precedingText: String, focusChangeSequence: UInt64) {
        snapshot = Self.make(precedingText: precedingText, focusChangeSequence: focusChangeSequence, role: role, bundleIdentifier: bundleIdentifier)
        subject.send(snapshot)
    }

    private static func make(
        precedingText: String,
        trailingText: String = "",
        focusChangeSequence: UInt64,
        role: String,
        bundleIdentifier: String
    ) -> FocusSnapshot {
        FocusSnapshot(
            applicationName: "TestApp",
            bundleIdentifier: "com.test.app",
            capability: .supported,
            context: CotabbyTestFixtures.focusedInputSnapshot(
                bundleIdentifier: bundleIdentifier,
                role: role,
                precedingText: precedingText,
                trailingText: trailingText,
                focusChangeSequence: focusChangeSequence
            )
        )
    }
}
