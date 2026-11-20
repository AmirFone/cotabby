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

        // #then the top word is typed and the next strip shows, without the word just typed
        XCTAssertEqual(harness.inserter.insertedChunks, ["to "])
        XCTAssertEqual(harness.panel.words, ["go", "be", "get", "the"])
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

        // #when Tab, then Option+1. Tab went to the app, which may have done anything with it, so
        // the strip only takes a pick again once the field has been read (here: nothing changed).
        let tabClaimed = harness.controller.observe(Self.key(48))
        harness.note("I want ")
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

    // MARK: - Drawn from the keys

    func test_everyKeyBeforeARead_isFollowed() {
        // #given a strip after "I ", and a host that publishes nothing while the writer types on
        let harness = makeHarness(precedingText: "I ")
        harness.note("I ")

        // #when a whole word and its space are typed without one read of the field
        for character in "want " { _ = harness.controller.observe(Self.typed(String(character), keyCode: character == " " ? 49 : 0)) }

        // #then the strip is the one for the text those keys leave, not for the text last read
        XCTAssertFalse(harness.panel.isHidden)
        XCTAssertEqual(harness.panel.words.first, "to")
        XCTAssertTrue(harness.panel.words.contains("it"), "after `want`, not after `I`: \(harness.panel.words)")
    }

    func test_slashTypedAfterAWord_predictsTheNextWord_notTheWordBeforeIt() {
        // #given the strip completing the last word of "I want t"
        let harness = makeHarness(precedingText: "I want t")
        harness.note("I want t")
        XCTAssertEqual(harness.panel.words, ["to", "the"])

        // #when the word is finished and a slash typed, before the field is read again
        _ = harness.controller.observe(Self.typed("o"))
        _ = harness.controller.observe(Self.typed("/"))

        // #then the strip offers what follows "want to", and no longer completes the word before
        XCTAssertFalse(harness.panel.isHidden)
        XCTAssertEqual(Array(harness.panel.words.prefix(3)), ["go", "be", "get"])
    }

    func test_hyphenTypedAfterAWord_predictsTheNextWord_notTheWordBeforeIt() {
        let harness = makeHarness(precedingText: "I want t")
        harness.note("I want t")

        _ = harness.controller.observe(Self.typed("o"))
        _ = harness.controller.observe(Self.typed("-"))

        XCTAssertFalse(harness.panel.isHidden)
        XCTAssertEqual(Array(harness.panel.words.prefix(3)), ["go", "be", "get"])
    }

    func test_keyThatLeavesNothingToComplete_takesTheStripDown() {
        // #given the strip completing "t"
        let harness = makeHarness(precedingText: "I want t")
        harness.note("I want t")
        XCTAssertFalse(harness.panel.isHidden)

        // #when a period is typed against the letter: no word is completed after a period
        _ = harness.controller.observe(Self.typed(".", keyCode: 47))

        // #then the completions of the word before it do not stay up
        XCTAssertTrue(harness.panel.isHidden)
        XCTAssertFalse(harness.controller.isCapturing)
    }

    func test_keyAfterAStripWentDown_bringsItBackWithoutARead() {
        // #given no strip: nothing completes "to" in this table
        let harness = makeHarness(precedingText: "I want to")
        harness.note("I want to")
        XCTAssertTrue(harness.panel.isHidden)

        // #when Space is typed
        _ = harness.controller.observe(Self.typed(" ", keyCode: 49))

        // #then the next word is offered at once
        XCTAssertFalse(harness.panel.isHidden)
        XCTAssertEqual(harness.panel.words.first, "go")
    }

    func test_readThatConfirmsTheStripDrawnFromTheKey_doesNotDrawItAgain() {
        // #given a strip drawn from the key "g"
        let harness = makeHarness(precedingText: "I want to ")
        harness.note("I want to ")
        _ = harness.controller.observe(Self.typed("g"))
        let drawn = harness.panel.timesShown

        // #when the field is read and holds exactly that text
        harness.focus.setPrecedingText("I want to g")
        harness.note("I want to g")

        // #then nothing is drawn again, and Tab picks without the strip being thrown away
        XCTAssertEqual(harness.panel.timesShown, drawn)
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()
        XCTAssertEqual(harness.inserter.replacements.first?.text, "go ")
    }

    func test_readOfAnEarlierStateOfTheBurst_doesNotPutTheStripBack() {
        // #given a word and its space typed in one go; the strip is the one for the text they leave
        let harness = makeHarness(precedingText: "I ")
        harness.note("I ")
        for character in "want " { _ = harness.controller.observe(Self.typed(String(character), keyCode: character == " " ? 49 : 0)) }
        let afterTheKeys = harness.panel.words

        // #when a slow host's publish of the first letters arrives as if it were the text now
        XCTAssertTrue(harness.controller.isBehindTheKeys("I wa"))
        harness.note("I wa")

        // #then the strip is not taken back to the middle of the finished word
        XCTAssertEqual(harness.panel.words, afterTheKeys)
        XCTAssertFalse(harness.panel.isHidden)
    }

    func test_fieldAheadOfAKeyNotYetSeen_isRecognizedThroughABurst() {
        // #given `we` typed in one go after a read of an empty field, with no read in between
        let harness = makeHarness(precedingText: "")
        harness.note("")
        for character in "we" { _ = harness.controller.observe(Self.typed(String(character))) }

        // #then a field that already reads `we ` when the space key arrives shows that key
        XCTAssertEqual(harness.controller.alreadyShows(typed: " ", in: "we "), true)
    }

    func test_fieldStillBeforeTheKey_doesNotShowIt() {
        let harness = makeHarness(precedingText: "")
        harness.note("")
        for character in "we" { _ = harness.controller.observe(Self.typed(String(character))) }

        XCTAssertEqual(harness.controller.alreadyShows(typed: " ", in: "we"), false)
    }

    func test_onlyAnEarlierStateOfTheKeys_countsAsBehind() {
        // #given the keys `want ` typed after `I `
        let harness = makeHarness(precedingText: "I ")
        harness.note("I ")
        for character in "want " { _ = harness.controller.observe(Self.typed(String(character), keyCode: character == " " ? 49 : 0)) }

        // #then the text those keys leave is not behind, nor is text that differs elsewhere
        XCTAssertFalse(harness.controller.isBehindTheKeys("I want "))
        XCTAssertFalse(harness.controller.isBehindTheKeys("I went "))
        XCTAssertFalse(harness.controller.isBehindTheKeys("You wan"))
        XCTAssertFalse(harness.controller.isBehindTheKeys("I want to"), "more text than the keys typed is not an earlier state")
        XCTAssertTrue(harness.controller.isBehindTheKeys("I want"))
        XCTAssertTrue(harness.controller.isBehindTheKeys("I "))
    }

    func test_afterBackspaces_theTextBeforeThemIsBehind() {
        // #given two letters deleted since the last read
        let harness = makeHarness(precedingText: "I want to go")
        harness.note("I want to go")
        _ = harness.controller.observe(CapturedInputEvent(kind: .textMutation, keyCode: 51, characters: "", flags: []))
        _ = harness.controller.observe(CapturedInputEvent(kind: .textMutation, keyCode: 51, characters: "", flags: []))

        // #then a field that still shows them is behind, and one that shows neither is not
        XCTAssertTrue(harness.controller.isBehindTheKeys("I want to go"))
        XCTAssertTrue(harness.controller.isBehindTheKeys("I want to g"))
        XCTAssertFalse(harness.controller.isBehindTheKeys("I want to "))
    }

    func test_keyWhileAnotherPanelIsUp_drawsNoStripUnderIt() {
        // #given the spelling bar on screen and no strip
        var barIsUp = true
        let harness = makeHarness(precedingText: "I want to", isAnotherPanelUp: { barIsUp })
        harness.note("I want to")

        // #when Space is typed
        _ = harness.controller.observe(Self.typed(" ", keyCode: 49))

        // #then no strip is drawn under the bar
        XCTAssertTrue(harness.panel.isHidden)

        // #when the bar is gone and the field is read
        barIsUp = false
        harness.focus.setPrecedingText("I want to ")
        harness.note("I want to ")

        // #then the strip is there
        XCTAssertEqual(harness.panel.words.first, "go")
    }

    // MARK: - Left alone

    func test_leftAlone_theStripGoesAway_andStaysAwayUntilAKey() {
        // #given a strip, and a writer who typed a moment ago
        let idle = InlinePanelIdleTimer(seconds: 0.05)
        let harness = makeHarness(precedingText: "I want ", idle: idle)
        idle.noteActivity()
        harness.note("I want ")
        XCTAssertFalse(harness.panel.isHidden)

        // #when no key follows for longer than the idle time
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        // #then the strip is gone
        XCTAssertTrue(harness.panel.isHidden)
        XCTAssertFalse(harness.controller.isCapturing)

        // #when the same text is noted again without a key, as a redraw from elsewhere would
        harness.note("I want ")

        // #then it stays gone
        XCTAssertTrue(harness.panel.isHidden)

        // #when the writer types again
        idle.noteActivity()
        _ = harness.controller.observe(Self.typed("t"))

        // #then the strip is back, for the word being typed
        XCTAssertFalse(harness.panel.isHidden)
        XCTAssertEqual(harness.panel.words, ["to", "the"])
    }

    func test_keysKeepTheStripUpPastTheIdleTime() {
        // #given a strip and a short idle time
        let idle = InlinePanelIdleTimer(seconds: 0.15)
        let harness = makeHarness(precedingText: "I want ", idle: idle)
        idle.noteActivity()
        harness.note("I want ")

        // #when keys keep coming, each sooner than the idle time, for longer than it in all
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.07))
            idle.noteActivity()
        }

        // #then the strip is still up
        XCTAssertFalse(harness.panel.isHidden)
    }

    // MARK: - The same field under a new number

    func test_fieldThatOnlyChangedItsFrame_keepsItsStrip_andAPickStillTypes() {
        // #given a strip in a message box
        let harness = makeHarness(precedingText: "I want ")
        harness.note("I want ")

        // #when the box grows a line: the same element, reported under a new number
        harness.focus.publish(precedingText: "I want ", focusChangeSequence: 2, sameElement: true)

        // #then the strip stays, and Tab types its first word
        XCTAssertFalse(harness.panel.isHidden)
        XCTAssertTrue(harness.controller.observe(Self.key(48)))
        flushMainQueue()
        XCTAssertEqual(harness.inserter.insertedChunks, ["to "])
    }

    func test_fieldThatOnlyChangedItsFrame_keepsTheTextTypedSoFar() {
        // #given a word begun, then the box grows a line
        let harness = makeHarness(precedingText: "I want ")
        harness.note("I want ")
        harness.focus.publish(precedingText: "I want ", focusChangeSequence: 2, sameElement: true)

        // #when the next letter is typed before the field is read again
        _ = harness.controller.observe(Self.typed("t"))

        // #then the strip follows the key, which it can only do if the text was not forgotten
        XCTAssertEqual(harness.panel.words, ["to", "the"])
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
        // #given the caret in the middle of a line, with a space after it (right in front of a
        // letter there would be no strip to step aside)
        let harness = makeHarness(precedingText: "I want to ", trailingText: " today")
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
        _ = harness.controller.observe(Self.typed("g"))
        harness.focus.setPrecedingText("I want to g")
        harness.note("I want to g")

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
        harness.controller.onSentenceSettled = { sentence, _ in settled.append(sentence) }
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

    // MARK: - Editing inside existing text

    func test_caretInsideAWord_showsNoStrip() {
        // #given the caret inside a word: `I want to g|old`
        let harness = makeHarness(precedingText: "I want to g", trailingText: "old")

        // #when the text settles
        harness.note("I want to g")

        // #then no strip: a pick would cut the word in two
        XCTAssertTrue(harness.panel.isHidden)
    }

    func test_caretBeforeAnApostropheInsideAWord_showsNoStrip() {
        // #given the caret before the apostrophe of a word: `I want to g|'s`
        let harness = makeHarness(precedingText: "I want to g", trailingText: "'s")

        // #when the text settles
        harness.note("I want to g")

        // #then no strip, as for any other place inside a word
        XCTAssertTrue(harness.panel.isHidden)
    }

    func test_pickBeforeAnExistingSpace_typesTheWordWithoutASpace() {
        // #given a word being finished in front of text that is already there: `I want to g| home`
        let harness = makeHarness(precedingText: "I want to g", trailingText: " home")
        harness.note("I want to g")

        // #when Tab is pressed
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        // #then the word is typed alone; the space after it is already in the field
        XCTAssertEqual(harness.inserter.replacements.map(\.text), ["go"])
    }

    func test_pickBeforeClosingPunctuation_typesTheWordWithoutASpace() {
        // #given a word being finished in front of a full stop: `I want to g|.`
        let harness = makeHarness(precedingText: "I want to g", trailingText: ".")
        harness.note("I want to g")

        // #when Tab is pressed
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        // #then no space is put between the word and the full stop
        XCTAssertEqual(harness.inserter.replacements.map(\.text), ["go"])
    }

    func test_pickAtTheEndOfALineWithLinesBelow_keepsItsSpace() {
        // #given the caret at the end of a line that has another line under it
        let harness = makeHarness(precedingText: "I want to g", trailingText: "\nNext line")
        harness.note("I want to g")

        // #when Tab is pressed
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        // #then the pick ends in a space, as at the end of the text
        XCTAssertEqual(harness.inserter.replacements.map(\.text), ["go "])
    }

    func test_spaceAfterAPickThatAddedNoSpace_reachesTheApp() {
        // #given a pick in front of existing text, which typed no space of its own
        let harness = makeHarness(precedingText: "I want to g", trailingText: ".")
        harness.note("I want to g")
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        // #when Space is pressed
        let claimed = harness.controller.observe(Self.typed(" ", keyCode: 49))

        // #then it is the writer's space; there is no picked space for it to double
        XCTAssertFalse(claimed)
    }

    func test_caretInsideAWordByTheTimeOfThePick_typesNothing() {
        // #given a strip drawn at the end of the text, and a field that now has letters after the caret
        let harness = makeHarness(precedingText: "I want to g")
        harness.note("I want to g")
        harness.focus.setTrailingText("old")

        // #when Tab is pressed
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        // #then nothing is typed into the middle of the word
        XCTAssertTrue(harness.typedNothing)
    }

    // MARK: - A field that is not what the strip was drawn for

    func test_pickWhileTheHostHasNotPublishedTheLastKey_waits_andTypesOnceTheFieldShowsIt() {
        // #given a strip for `I want to g`, an `e` typed since, and a host that still reports the old text
        let harness = makeHarness(precedingText: "I want to g")
        harness.note("I want to g")
        _ = harness.controller.observe(Self.typed("e"))
        XCTAssertEqual(harness.panel.words, ["get"])

        // #when Tab is pressed
        XCTAssertTrue(harness.controller.observe(Self.key(48)))
        flushMainQueue()

        // #then no letter is deleted yet: one backspace counted against the old text would take the `e`
        XCTAssertTrue(harness.typedNothing)

        // #when the host publishes the `e`
        harness.focus.setPrecedingText("I want to ge")
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        // #then the pick is typed against the text the field now shows
        XCTAssertEqual(harness.inserter.replacements.first?.deleteCount, 2)
        XCTAssertEqual(harness.inserter.replacements.first?.text, "get ")
    }

    func test_pickWhileTheHostNeverPublishesTheLastKey_typesNothing() {
        // #given the same, and a host that never shows the `e`
        let harness = makeHarness(precedingText: "I want to g")
        harness.note("I want to g")
        _ = harness.controller.observe(Self.typed("e"))

        // #when Tab is pressed and the wait (1.2 s) runs out
        _ = harness.controller.observe(Self.key(48))
        RunLoop.main.run(until: Date().addingTimeInterval(1.6))

        // #then nothing was typed and the strip is gone
        XCTAssertTrue(harness.typedNothing)
        XCTAssertTrue(harness.panel.isHidden)
    }

    func test_pickWaitingForTheHost_isDroppedWhenTheWriterTypesOn() {
        // #given a pick waiting for the host to show the last key
        let harness = makeHarness(precedingText: "I want to g")
        harness.note("I want to g")
        _ = harness.controller.observe(Self.typed("e"))
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        // #when the writer types another letter, and the host then shows both
        _ = harness.controller.observe(Self.typed("t"))
        harness.focus.setPrecedingText("I want to get")
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        // #then the pick that was asked for before that letter is not typed over it
        XCTAssertTrue(harness.typedNothing)
    }

    func test_stripHeldBackWhileAKeyWasTyped_isNotPickedFromAgainstTheOldText() {
        // #given a strip held back for the language model, a key typed during the wait, and a host
        // that still reports the text before that key
        let harness = makeHarness(precedingText: "I want to g", isLanguageModelPending: { _ in true })
        harness.note("I want to g")
        _ = harness.controller.observe(Self.typed("e"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))

        // #when Tab is pressed on the strip that was drawn after the wait
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        // #then nothing is typed
        XCTAssertTrue(harness.typedNothing)
    }

    func test_caretMovedWithinTheFieldSinceTheStripWasDrawn_pickTypesNothing() {
        // #given a strip for `I want ` and a caret the writer has since put elsewhere in the field
        let harness = makeHarness(precedingText: "I want ")
        harness.note("I want ")
        harness.focus.setPrecedingText("I w")

        // #when Tab is pressed
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        // #then the word predicted for the old place is not typed at the new one
        XCTAssertTrue(harness.typedNothing)
    }

    func test_pickRightAfterAPick_beforeTheHostPublishes_isPlannedFromTheTextThePickLeaves() {
        // #given two picks in a row, the second before the host has published the first
        let harness = makeHarness(precedingText: "I want ")
        harness.note("I want ")
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()
        XCTAssertEqual(harness.inserter.insertedChunks, ["to ", "go "])
        harness.focus.setPrecedingText("I want to go ")

        // #when a full stop is typed
        _ = harness.controller.observe(Self.typed(".", keyCode: 47))
        let fence = expectation(description: "space moved")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { fence.fulfill() }
        wait(for: [fence], timeout: 1)

        // #then the controller knows what the field holds, and moves the picked space behind it
        XCTAssertEqual(harness.inserter.replacements.map(\.text), [". "])
    }

    func test_optionDigit_typesTheWordThatWasInTheSlotWhenPressed() {
        // #given Option+2 pressed on `be`, and the language model reordering the strip before the
        // pick is typed (it waits for Option to be let go)
        let answer = LanguageModelFixture.scores(textBefore: "I want to ", ["be": 0.6, "go": 0.2, "get": 0.05])
        var isReady = false
        let harness = makeHarness(precedingText: "I want to ", languageModel: { _ in isReady ? answer : nil })
        harness.note("I want to ")
        XCTAssertEqual(Array(harness.panel.words.prefix(2)), ["go", "be"])
        XCTAssertTrue(harness.controller.observe(Self.key(19, flags: .maskAlternate)))
        XCTAssertEqual(harness.controller.decideCaptureKey(InputMonitorKeyEvent(keyCode: 19)), .consume)

        // #when the model's answer puts another word in that slot
        isReady = true
        harness.controller.redrawWithLanguageModel()
        XCTAssertTrue(waitFor(timeout: 2) { !harness.inserter.insertedChunks.isEmpty })

        // #then the word the writer chose is typed, not the one that took its place
        XCTAssertEqual(harness.inserter.insertedChunks, ["be "])
    }

    // MARK: - Leaving a field

    func test_escapeInOneField_doesNotSilenceTheStripInTheNext() {
        // #given Escape pressed on the strip
        let harness = makeHarness(precedingText: "I want ")
        harness.note("I want ")
        _ = harness.controller.observe(Self.key(53))

        // #when the writer moves to another field and types there
        harness.focus.publish(precedingText: "I want ", focusChangeSequence: 2)
        harness.controller.noteTypedText("I want ", caretRect: .zero, focusChangeSequence: 2)

        // #then the strip is back for the first word
        XCTAssertFalse(harness.panel.isHidden)
    }

    func test_stripHeldBackForTheLanguageModel_isDroppedWhenFocusMoves() {
        // #given a strip held back while the language model works
        let harness = makeHarness(precedingText: "I want to ", isLanguageModelPending: { _ in true })
        harness.note("I want to ")

        // #when focus moves to another field before the wait runs out
        harness.focus.publish(precedingText: "", focusChangeSequence: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))

        // #then the old field's strip is never drawn over the new one
        XCTAssertTrue(harness.panel.isHidden)
    }

    func test_spaceInAnotherFieldAfterAPick_isNotSwallowed() {
        // #given a pick, whose space would swallow a Space typed next
        let harness = makeHarness(precedingText: "I want ")
        harness.note("I want ")
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        // #when the writer moves to another field and presses Space there
        harness.focus.publish(precedingText: "", focusChangeSequence: 2)
        let claimed = harness.controller.observe(Self.typed(" ", keyCode: 49))

        // #then the key is theirs
        XCTAssertFalse(claimed)
    }

    func test_returnInAnotherField_learnsNothing() {
        // #given a line typed in one field and not sent
        let harness = makeHarness(precedingText: "see you at the gym")
        harness.note("see you at the gym")

        // #when Return is pressed in another field
        harness.focus.publish(precedingText: "", focusChangeSequence: 2)
        _ = harness.controller.observe(Self.key(36))

        // #then the first field's line is not learned as sent
        XCTAssertEqual(harness.learned.values, [])
    }

    func test_returnBeforeTheLastKeysWereRead_learnsTheLineWithItsLastLetters() {
        // #given a line whose last letters were typed after the field was last read, as when a
        // message ends with a word followed at once by Return in a host that publishes late
        let harness = makeHarness(precedingText: "see you at the gy")
        harness.note("see you at the gy")
        _ = harness.controller.observe(Self.typed("m"))

        // #when Return sends the line
        _ = harness.controller.observe(Self.key(36))

        // #then the line is learned whole: the key itself says which letter the field had not
        // reported yet
        XCTAssertEqual(harness.learned.values, ["see you at the gym"])
    }

    func test_shiftReturn_learnsTheLineItEnds() {
        // #given the first line of a message in a chat box
        let harness = makeHarness(precedingText: "see you at the gym")
        harness.note("see you at the gym")

        // #when Shift+Return starts the next line of the same message
        _ = harness.controller.observe(Self.key(36, flags: .maskShift))

        // #then the line it ended is learned, as one sent with Return would be
        XCTAssertEqual(harness.learned.values, ["see you at the gym"])
    }

    func test_dotInsideAFileName_doesNotStartTheSentenceThere() {
        // #given a line that names a file
        let harness = makeHarness(precedingText: "please open report.txt and read it")
        harness.note("please open report.txt and read it")

        // #when it is sent
        _ = harness.controller.observe(Self.key(36))

        // #then the whole line is learned, not the part after the dot
        XCTAssertEqual(harness.learned.values, ["please open report.txt and read it"])
    }

    func test_sentenceEndingInSeveralMarks_isLearned() {
        // #given a sentence finished with three exclamation marks and a space
        let harness = makeHarness(precedingText: "we finally shipped it!!! ")
        harness.note("we finally shipped it!!! ")
        flushMainQueue()

        // #then it is learned without them
        XCTAssertEqual(harness.learned.values, ["we finally shipped it"])
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
        /// No pick reached the field, neither as an insertion nor as a replacement.
        var typedNothing: Bool { inserter.insertedChunks.isEmpty && inserter.replacements.isEmpty }

        func note(_ text: String) {
            controller.noteTypedText(text, caretRect: .zero, focusChangeSequence: 1)
        }
    }

    private func makeHarness(
        precedingText: String,
        trailingText: String = "",
        isSpellingPending: @escaping () -> Bool = { false },
        languageModel: @escaping (String) -> LanguageModelScores? = { _ in nil },
        isLanguageModelPending: @escaping (String) -> Bool = { _ in false },
        isAnotherPanelUp: @escaping () -> Bool = { false },
        idle: InlinePanelIdleTimer? = nil
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
            languageModelWait: 0.03,
            isAnotherPanelUp: isAnotherPanelUp,
            idle: idle
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
                + "\n" + SymSpellCorrector.englishSupplement() + "\n" + TechnicalVocabulary.spellingLines()
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

    func test_realModel_engineeringTerms_areOfferedWhereTheTextCallsForThem_withTheirCapitals() throws {
        // #given sentences about software, heading for terms the general dictionary lacks
        let (harness, _) = try makeRealHarness()
        type("We deploy the service to kube", after: "", into: harness)
        XCTAssertTrue(waitFor { harness.panel.words.first == "Kubernetes" }, "strip shows \(harness.panel.words)")

        type("The API returns js", after: "", into: harness)
        XCTAssertTrue(waitFor { harness.panel.words.first == "JSON" }, "strip shows \(harness.panel.words)")

        // #and an ordinary sentence is not given a programming language for a word about weather
        type("The spring is here and the weather is sw", after: "", into: harness)
        XCTAssertTrue(waitFor { !harness.panel.words.isEmpty && harness.panel.words.allSatisfy { $0.hasPrefix("sw") } })
        XCTAssertFalse(harness.panel.words.contains { $0.lowercased() == "swift" }, "strip shows \(harness.panel.words)")
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

    /// A key that types `characters`. The key code only matters for Space and the closing marks,
    /// which the controller tells apart by it; any letter can use the default.
    private static func typed(_ characters: String, keyCode: CGKeyCode = 0) -> CapturedInputEvent {
        CapturedInputEvent(kind: .textMutation, keyCode: keyCode, characters: characters, flags: [])
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
    /// How many times a strip was drawn: a redraw is a round trip to the window server.
    private(set) var timesShown = 0

    func show(offer: CandidateOffer, selectedIndex: Int, acceptKeyLabel: String) {}
    func setSelectedIndex(_ index: Int) { selectedIndex = index }
    private(set) var selectedIndex: Int?

    func showWordStrip(words: [String], selectedIndex: Int?, caretRect: CGRect) {
        isHidden = false
        timesShown += 1
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

    /// Puts `text` after the caret and leaves the text before it as it is.
    func setTrailingText(_ text: String) {
        snapshot = Self.make(
            precedingText: snapshot.context?.precedingText ?? "",
            trailingText: text,
            focusChangeSequence: 1,
            role: role,
            bundleIdentifier: bundleIdentifier
        )
    }

    /// Another field unless `sameElement` says the field only got a new number (its frame changed).
    func publish(precedingText: String, focusChangeSequence: UInt64, sameElement: Bool = false) {
        snapshot = Self.make(
            precedingText: precedingText, focusChangeSequence: focusChangeSequence, role: role, bundleIdentifier: bundleIdentifier,
            elementIdentifier: sameElement ? "field-1" : "field-\(focusChangeSequence)"
        )
        subject.send(snapshot)
    }

    private static func make(
        precedingText: String,
        trailingText: String = "",
        focusChangeSequence: UInt64,
        role: String,
        bundleIdentifier: String,
        elementIdentifier: String = "field-1"
    ) -> FocusSnapshot {
        FocusSnapshot(
            applicationName: "TestApp",
            bundleIdentifier: "com.test.app",
            capability: .supported,
            context: CotabbyTestFixtures.focusedInputSnapshot(
                bundleIdentifier: bundleIdentifier,
                elementIdentifier: elementIdentifier,
                role: role,
                precedingText: precedingText,
                trailingText: trailingText,
                focusChangeSequence: focusChangeSequence
            )
        )
    }
}
