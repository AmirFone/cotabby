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

    func test_undoneLocalFix_isNotAppliedAgainAndIsLearned() {
        // #given a sentence the pass fixes on its own
        let harness = makeHarness(sentence: "I saw teh cat. ", proofread: { finished in
            let fixed = finished.sentence.replacingOccurrences(of: "teh", with: "the")
            return LocalProofreadResult(original: finished.sentence, autoCorrected: fixed, flags: [])
        })
        var outcomes: [(changes: [String], kept: Bool)] = []
        harness.controller.onLocalFixOutcome = { original, corrected, kept in
            let changes = SentenceFixOutcomeTracker.wordChanges(original: original, corrected: corrected)
            outcomes.append((changes.map { "\($0.typed)>\($0.fixed)" }, kept))
        }
        harness.controller.noteTypedText("I saw teh cat. ", caretRect: .zero, focusChangeSequence: 1)
        flushMainQueue()
        harness.controller.noteTypedText("I saw the cat. ", caretRect: .zero, focusChangeSequence: 1)

        // #when Cmd+Z brings the original back
        harness.controller.noteTypedText("I saw teh cat. ", caretRect: .zero, focusChangeSequence: 1)
        flushMainQueue()

        // #then it stays as written and the typed word is remembered as intended
        XCTAssertEqual(harness.inserter.replacements.count, 1)
        XCTAssertEqual(outcomes.first?.changes, ["teh>the"])
        XCTAssertEqual(outcomes.first?.kept, false)
    }

    func test_typingPastALocalFix_confirmsIt() {
        let harness = makeHarness(sentence: "I saw teh cat. ", proofread: { finished in
            let fixed = finished.sentence.replacingOccurrences(of: "teh", with: "the")
            return LocalProofreadResult(original: finished.sentence, autoCorrected: fixed, flags: [])
        })
        var kept: [Bool] = []
        harness.controller.onLocalFixOutcome = { _, _, wasKept in kept.append(wasKept) }
        harness.controller.noteTypedText("I saw teh cat. ", caretRect: .zero, focusChangeSequence: 1)
        flushMainQueue()

        harness.controller.noteTypedText("I saw the cat. ", caretRect: .zero, focusChangeSequence: 1)
        harness.controller.noteTypedText("I saw the cat. It ran off", caretRect: .zero, focusChangeSequence: 1)

        XCTAssertEqual(kept, [true])
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

    func test_review_reportsEachChoiceWithTheWordBeforeIt() {
        let harness = makeHarness(sentence: "I went their with adres book. ", proofread: Self.twoFlags)
        var choices: [String] = []
        harness.controller.onReviewChoice = { typed, previous, chosen in
            choices.append("\(previous ?? "-") | \(typed) → \(chosen)")
        }
        harness.controller.noteTypedText(harness.focus.snapshot.context!.precedingText, caretRect: .zero, focusChangeSequence: 1)

        // Escape keeps the first word, Tab takes the fix for the second.
        _ = harness.controller.observe(Self.key(53))
        _ = harness.controller.observe(Self.key(48))
        flushMainQueue()

        XCTAssertEqual(choices, ["went | their → their", "with | adres → address"])
    }

    func test_review_leftHalfway_teachesNothing() {
        // #given a review with two words to decide
        let harness = makeHarness(sentence: "I went their with adres book. ", proofread: Self.twoFlags)
        var choices: [String] = []
        harness.controller.onReviewChoice = { typed, _, chosen in choices.append("\(typed) → \(chosen)") }
        harness.controller.noteTypedText(harness.focus.snapshot.context!.precedingText, caretRect: .zero, focusChangeSequence: 1)

        // #when the writer decides the first and then types on, which closes the card unchanged
        _ = harness.controller.observe(Self.key(53))
        _ = harness.controller.observe(CapturedInputEvent(kind: .textMutation, keyCode: 0, characters: "a", flags: []))
        flushMainQueue()

        // #then the sentence was not changed, and the half-made review is not remembered either
        XCTAssertEqual(harness.inserter.replacements.count, 0)
        XCTAssertEqual(choices, [])
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

    // MARK: - A line the writer has not ended

    /// Long enough for the pause check to wake, look, and type.
    private func waitOutThePause() async {
        try? await Task.sleep(nanoseconds: SentenceCheckController.pauseDelayNanoseconds + 250_000_000)
        await settleModelPass()
    }

    func test_unfinishedLine_isCheckedWhenTheWriterPauses() async {
        // #given a chat line with no closing mark and a wrong word early in it
        let line = "can you send teh report over when you get "
        let harness = makeHarness(sentence: line, proofread: { finished in
            LocalProofreadResult(
                original: finished.sentence, autoCorrected: finished.sentence.replacingOccurrences(of: "teh", with: "the"), flags: []
            )
        })

        // #when the text is noted and no key follows
        harness.controller.noteTypedText(line, caretRect: .zero, focusChangeSequence: 1)
        await settleModelPass()
        XCTAssertTrue(harness.inserter.replacements.isEmpty, "nothing is changed while the writer may still be typing")
        await waitOutThePause()

        // #then the word is fixed in place, from its first changed letter to the caret
        XCTAssertEqual(harness.inserter.replacements.map(\.text), ["he report over when you get "])
    }

    func test_unfinishedLine_isNotCheckedWhileKeysKeepComing() async {
        // #given the same line, and a key before the pause is over
        let line = "can you send teh report over when you get "
        let harness = makeHarness(sentence: line, proofread: { finished in
            LocalProofreadResult(
                original: finished.sentence, autoCorrected: finished.sentence.replacingOccurrences(of: "teh", with: "the"), flags: []
            )
        })
        harness.controller.noteTypedText(line, caretRect: .zero, focusChangeSequence: 1)

        // #when the writer types on
        _ = harness.controller.observe(CapturedInputEvent(kind: .textMutation, keyCode: 0, characters: "a", flags: []))
        await waitOutThePause()

        // #then nothing was typed behind their caret
        XCTAssertTrue(harness.inserter.replacements.isEmpty)
    }

    func test_unfinishedLine_shorterThanFiveWords_isLeftAlone() async {
        // #given four words
        var asked = 0
        let harness = makeHarness(sentence: "can you send teh ", proofread: { _ in
            asked += 1
            return nil
        })

        // #when the writer pauses
        harness.controller.noteTypedText("can you send teh ", caretRect: .zero, focusChangeSequence: 1)
        await waitOutThePause()

        // #then the line is not looked at yet
        XCTAssertEqual(asked, 0)
    }

    func test_unfinishedLine_theLastWordIsNotChanged() async {
        // #given a line whose only change would be to its last word, which nothing follows yet
        let line = "yesterday after lunch I went their "
        let harness = makeHarness(sentence: line, proofread: { finished in
            LocalProofreadResult(
                original: finished.sentence, autoCorrected: finished.sentence.replacingOccurrences(of: "their", with: "there"), flags: []
            )
        })

        // #when the writer pauses
        harness.controller.noteTypedText(line, caretRect: .zero, focusChangeSequence: 1)
        await waitOutThePause()

        // #then the word stays: `their way home` may still be coming
        XCTAssertTrue(harness.inserter.replacements.isEmpty)
    }

    func test_unfinishedLine_fixTheWriterUndid_isNotMadeAgainWhenTheLineHasGrown() async {
        // #given a fix made at a pause and undone by the writer
        let line = "can you send teh report over when you get "
        let harness = makeHarness(sentence: line, proofread: { finished in
            LocalProofreadResult(
                original: finished.sentence, autoCorrected: finished.sentence.replacingOccurrences(of: "teh", with: "the"), flags: []
            )
        })
        harness.controller.noteTypedText(line, caretRect: .zero, focusChangeSequence: 1)
        await waitOutThePause()
        XCTAssertEqual(harness.inserter.replacements.count, 1)
        let fixed = line.replacingOccurrences(of: "teh", with: "the")
        harness.controller.noteTypedText(fixed, caretRect: .zero, focusChangeSequence: 1)
        harness.controller.noteTypedText(line, caretRect: .zero, focusChangeSequence: 1)

        // #when the line has two more words and the writer pauses again
        let longer = line + "a chance "
        harness.focus.setPrecedingText(longer)
        harness.controller.noteTypedText(longer, caretRect: .zero, focusChangeSequence: 1)
        await waitOutThePause()

        // #then the word they put back is left as they wrote it
        XCTAssertEqual(harness.inserter.replacements.count, 1)
    }

    func test_unfinishedLine_wordAskedAboutOnce_isNotAskedAboutAtTheNextPause() async {
        // #given a review card for a word in an unfinished line, which the writer types past
        let line = "I think we went their after the long "
        let flagged: (FinishedSentence) -> LocalProofreadResult? = { finished in
            guard let range = finished.sentence.range(of: "their") else { return nil }
            return LocalProofreadResult(
                original: finished.sentence, autoCorrected: finished.sentence,
                flags: [SentenceFlag(range: range, typed: "their", options: ["there"])]
            )
        }
        let harness = makeHarness(sentence: line, proofread: flagged)
        harness.controller.noteTypedText(line, caretRect: .zero, focusChangeSequence: 1)
        await waitOutThePause()
        XCTAssertEqual(harness.panel.reviews.count, 1)
        _ = harness.controller.observe(CapturedInputEvent(kind: .textMutation, keyCode: 0, characters: "m", flags: []))
        XCTAssertFalse(harness.controller.isShowingFix)

        // #when the line has grown and the writer pauses again
        let longer = line + "meeting on "
        harness.focus.setPrecedingText(longer)
        harness.controller.noteTypedText(longer, caretRect: .zero, focusChangeSequence: 1)
        await waitOutThePause()

        // #then the same word is not put to them a second time
        XCTAssertEqual(harness.panel.reviews.count, 1)
        XCTAssertFalse(harness.controller.isShowingFix)
    }

    func test_unfinishedLine_theModelReadsItWhenTheRulesHaveNothing() async {
        // #given a line the rules leave alone and the model corrects
        let line = "we drove the Tyoda to the office this "
        let harness = makeHarness(sentence: line, proofread: { _ in nil }, model: { finished in
            LocalProofreadResult(
                original: finished.sentence, autoCorrected: finished.sentence.replacingOccurrences(of: "Tyoda", with: "Toyota"), flags: []
            )
        })

        // #when the writer pauses
        harness.controller.noteTypedText(line, caretRect: .zero, focusChangeSequence: 1)
        await waitOutThePause()

        // #then the model's fix is typed in place
        XCTAssertEqual(harness.inserter.replacements.map(\.text), ["oyota to the office this "])
    }

    // MARK: - Sentence model stage

    func test_sentenceModelFix_isTypedInPlace() async {
        // #given a sentence the local rules leave alone and the model corrects with certainty
        let harness = makeHarness(sentence: "I drive a Tyoda to work. ", proofread: { _ in nil }, model: { finished in
            LocalProofreadResult(original: finished.sentence, autoCorrected: "I drive a Toyota to work.", flags: [])
        })

        // #when the sentence is finished and the model answers
        harness.controller.noteTypedText("I drive a Tyoda to work. ", caretRect: .zero, focusChangeSequence: 1)
        await settleModelPass()

        // #then the sentence is retyped from the first changed letter, with the usual flash
        XCTAssertEqual(harness.inserter.replacements.map(\.text), ["oyota to work. "])
        XCTAssertEqual(harness.panel.flashes, 1)
    }

    func test_sentenceModelAnswer_afterTheWriterTypedOn_isDropped() async {
        // #given a model whose answer arrives after the writer started the next sentence
        var harness: Harness!
        harness = makeHarness(sentence: "I drive a Tyoda to work. ", proofread: { _ in nil }, model: { finished in
            harness.focus.setPrecedingText("I drive a Tyoda to work. It")
            return LocalProofreadResult(original: finished.sentence, autoCorrected: "I drive a Toyota to work.", flags: [])
        })

        // #when the sentence is finished
        harness.controller.noteTypedText("I drive a Tyoda to work. ", caretRect: .zero, focusChangeSequence: 1)
        await settleModelPass()

        // #then nothing is typed over what the writer is doing now
        XCTAssertTrue(harness.inserter.replacements.isEmpty)
    }

    func test_sentenceModel_readsEachSentenceOnce_includingItsOwnFix() async {
        // #given a model that fixes the sentence
        var asked: [String] = []
        let harness = makeHarness(sentence: "I drive a Tyoda to work. ", proofread: { _ in nil }, model: { finished in
            asked.append(finished.sentence)
            return LocalProofreadResult(original: finished.sentence, autoCorrected: "I drive a Toyota to work.", flags: [])
        })
        harness.controller.noteTypedText("I drive a Tyoda to work. ", caretRect: .zero, focusChangeSequence: 1)
        await settleModelPass()

        // #when the field then reports the corrected sentence, and reports it again
        harness.controller.noteTypedText("I drive a Toyota to work. ", caretRect: .zero, focusChangeSequence: 1)
        harness.controller.noteTypedText("I drive a Toyota to work. ", caretRect: .zero, focusChangeSequence: 1)
        await settleModelPass()

        // #then the model was asked about the typed sentence only
        XCTAssertEqual(asked, ["I drive a Tyoda to work."])
    }

    func test_sentenceModel_readsTheSentenceTheLocalPassLeftBehind() async {
        // #given a local pass that fixes one word and a model that would fix another
        var asked: [String] = []
        let harness = makeHarness(sentence: "I saw teh Tyoda today. ", proofread: { finished in
            let fixed = finished.sentence.replacingOccurrences(of: "teh", with: "the")
            return fixed == finished.sentence ? nil : LocalProofreadResult(original: finished.sentence, autoCorrected: fixed, flags: [])
        }, model: { finished in
            asked.append(finished.sentence)
            return nil
        })

        // #when the local fix lands and the field reports the corrected sentence
        harness.controller.noteTypedText("I saw teh Tyoda today. ", caretRect: .zero, focusChangeSequence: 1)
        await settleModelPass()
        harness.focus.setPrecedingText("I saw the Tyoda today. ")
        harness.controller.noteTypedText("I saw the Tyoda today. ", caretRect: .zero, focusChangeSequence: 1)
        await settleModelPass()

        // #then the model is asked about the locally corrected sentence, not the one it replaced
        XCTAssertEqual(asked, ["I saw the Tyoda today."])
    }

    func test_sentenceModelUnsureWord_opensTheReviewCard() async {
        // #given a model that is not sure enough to type its fix
        let sentence = "I want to go their now."
        let harness = makeHarness(sentence: sentence + " ", proofread: { _ in nil }, model: { finished in
            let their = finished.sentence.range(of: "their")!
            return LocalProofreadResult(original: finished.sentence, autoCorrected: finished.sentence, flags: [
                SentenceFlag(range: their, typed: "their", options: ["there"])
            ])
        })

        // #when the sentence is finished and the model answers
        harness.controller.noteTypedText(sentence + " ", caretRect: .zero, focusChangeSequence: 1)
        await settleModelPass()

        // #then nothing is typed and the word is offered for review
        XCTAssertTrue(harness.inserter.replacements.isEmpty)
        XCTAssertEqual(harness.panel.reviews.count, 1)
    }

    // MARK: - Review card keys

    func test_review_arrowWithAModifier_isLeftToTheField() {
        for flags: CGEventFlags in [.maskShift, .maskAlternate, .maskCommand, .maskControl] {
            // #given an open review card
            let harness = makeHarness(sentence: "I went their with adres book. ", proofread: Self.twoFlags)
            harness.controller.noteTypedText(harness.focus.snapshot.context!.precedingText, caretRect: .zero, focusChangeSequence: 1)

            // #when the writer presses Left with a modifier, which selects or jumps in their text
            let involved = harness.controller.observe(
                CapturedInputEvent(kind: .navigation, keyCode: 123, characters: "", flags: flags)
            )

            // #then the card does not claim the key
            XCTAssertFalse(involved, "Left with modifier flags \(flags.rawValue) was swallowed")
        }
    }

    func test_review_arrowWithAModifier_closesTheCardLikeAnyOtherKey() {
        // #given an open review card
        let harness = makeHarness(sentence: "I went their with adres book. ", proofread: Self.twoFlags)
        harness.controller.noteTypedText(harness.focus.snapshot.context!.precedingText, caretRect: .zero, focusChangeSequence: 1)

        // #when the writer starts selecting with Shift+Right
        _ = harness.controller.observe(CapturedInputEvent(kind: .navigation, keyCode: 124, characters: "", flags: .maskShift))

        // #then the card is gone and the sentence is theirs again
        XCTAssertFalse(harness.controller.isShowingFix)
    }

    func test_review_plainArrow_stillMovesTheHighlightWithTheFlagsARealArrowKeyCarries() {
        // #given an open review card on its first word, where the fix is highlighted
        let harness = makeHarness(sentence: "I went their with adres book. ", proofread: Self.twoFlags)
        harness.controller.noteTypedText(harness.focus.snapshot.context!.precedingText, caretRect: .zero, focusChangeSequence: 1)

        // #when Left arrives the way the keyboard sends it: no modifier held, but with the keypad
        // and fn bits macOS sets on every arrow key
        _ = harness.controller.observe(
            CapturedInputEvent(kind: .navigation, keyCode: 123, characters: "", flags: [.maskNumericPad, .maskSecondaryFn])
        )

        // #then the highlight moved to the typed word
        XCTAssertEqual(harness.panel.reviews.last?.selectedIndex, 0)
    }

    // MARK: - Cloud check and the cards of the other stages

    func test_reviewCard_isStillTheControllersAfterTheCloudCheckItOvertookWakes() async throws {
        // #given the cloud check on, and a sentence model that flags a word while that check is
        // still in its pause
        let sentence = "I want to go their now."
        let harness = makeHarness(sentence: sentence + " ", proofread: { _ in nil }, model: { finished in
            let their = finished.sentence.range(of: "their")!
            return LocalProofreadResult(original: finished.sentence, autoCorrected: finished.sentence, flags: [
                SentenceFlag(range: their, typed: "their", options: ["there"])
            ])
        }, cloud: CloudCheckProbe())
        harness.controller.noteTypedText(sentence + " ", caretRect: .zero, focusChangeSequence: 1)
        await settleModelPass()

        // #when the pause is over
        try await Task.sleep(nanoseconds: SentenceCheckController.idleDelayNanoseconds + 200_000_000)

        // #then the card on screen is still owned, so Tab, Escape and a click outside reach it
        XCTAssertTrue(harness.controller.isShowingFix)
    }

    func test_cloudCheckCancelledOnTheWire_doesNotCauseASecondCheckOfTheNextSentence() async throws {
        // #given a cloud check held back by the rate budget (a request has just gone out) at the
        // moment the writer finishes the next sentence, which cancels it
        let cloud = CloudCheckProbe()
        let governor = EndpointRateGovernor(tokensPerMinute: 100_000, now: { cloud.now() })
        _ = governor.decide(estimatedTokens: 1, isAtWordBoundary: true)
        let harness = makeHarness(sentence: "It was late. ", proofread: { _ in nil }, cloud: cloud, rateGovernor: governor)
        retained.append(governor)
        harness.controller.noteTypedText("It was late. ", caretRect: .zero, focusChangeSequence: 1)
        try await Task.sleep(nanoseconds: SentenceCheckController.idleDelayNanoseconds + 100_000_000)
        harness.focus.setPrecedingText("It was late. We went home. ")
        harness.controller.noteTypedText("It was late. We went home. ", caretRect: .zero, focusChangeSequence: 1)
        await settleModelPass()

        // #when the budget frees up and the next prediction cycle reports the same text
        cloud.isBudgetHeld = false
        harness.controller.noteTypedText("It was late. We went home. ", caretRect: .zero, focusChangeSequence: 1)
        try await Task.sleep(nanoseconds: SentenceCheckController.idleDelayNanoseconds + 300_000_000)

        // #then the cancelled check did not clear the way for a duplicate: one request went out
        XCTAssertEqual(cloud.requests, 1)
    }

    private struct Harness {
        let controller: SentenceCheckController
        let panel: ReviewRecordingPanel
        let focus: StaticFocus
        let inserter: RigInserter
    }

    private func makeHarness(
        sentence: String,
        proofread: @escaping (FinishedSentence) -> LocalProofreadResult?,
        model: (@MainActor (FinishedSentence) async -> LocalProofreadResult?)? = nil,
        cloud: CloudCheckProbe? = nil,
        rateGovernor: EndpointRateGovernor? = nil
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
            configurationProvider: {
                // Reached only when a check is about to go on the wire; no test lets it leave the Mac.
                cloud?.requests += 1
                throw CancellationError()
            },
            apiKeyProvider: { nil },
            rateGovernor: rateGovernor,
            isEnabled: { cloud != nil },
            knownTerms: { nil },
            acceptKeyLabel: { "Tab" },
            isWordAcceptKey: { $0.keyCode == 48 },
            qualityMetricsStore: metrics,
            localProofread: proofread,
            modelProofread: model,
            isLocalEnabled: { true },
            appliesLocalFixes: { true }
        )
        controller.start()
        retained.append(contentsOf: [controller, panel, focus, inserter, metrics] as [AnyObject])
        return Harness(controller: controller, panel: panel, focus: focus, inserter: inserter)
    }

    /// Lets the controller's model task run to its end: it resumes on the main actor after the
    /// model's answer, then queues the edit one more main-queue turn later.
    private func settleModelPass() async {
        for _ in 0..<4 {
            await Task.yield()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
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

/// Stands in for the cloud endpoint: counts the checks that got as far as building a request, and
/// is the clock of the rate budget, which holds every request back while `isBudgetHeld` is set
/// (time stands still right after a request went out) and lets them through once it is cleared.
@MainActor
private final class CloudCheckProbe {
    var requests = 0
    var isBudgetHeld = true
    private var date = Date()

    func now() -> Date {
        if !isBudgetHeld { date += 1 }
        return date
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
    func showWordStrip(words: [String], selectedIndex: Int?, caretRect: CGRect) {}
    func showSentenceFlash(segments: [SentenceFixSegment], caretRect: CGRect) { flashes += 1 }
    func showSentenceReview(_ review: SentenceReviewPresentation, caretRect: CGRect, acceptKeyLabel: String) {
        reviews.append(review)
    }
    func showSentenceFix(segments: [SentenceFixSegment], caretRect: CGRect, acceptKeyLabel: String) {}
    func hide() {}
}

@MainActor
private final class StaticFocus: SuggestionFocusProviding {
    private(set) var snapshot: FocusSnapshot
    var snapshotPublisher: AnyPublisher<FocusSnapshot, Never> { Empty().eraseToAnyPublisher() }

    init(precedingText: String) {
        snapshot = Self.snapshot(precedingText: precedingText)
    }

    /// The field after the writer typed more.
    func setPrecedingText(_ precedingText: String) {
        snapshot = Self.snapshot(precedingText: precedingText)
    }

    private static func snapshot(precedingText: String) -> FocusSnapshot {
        FocusSnapshot(
            applicationName: "TestApp",
            bundleIdentifier: "com.test.app",
            capability: .supported,
            context: CotabbyTestFixtures.focusedInputSnapshot(precedingText: precedingText, focusChangeSequence: 1)
        )
    }

    func refreshNow() {}
}
