import XCTest
@testable import Cotabby

/// An auto-fix teaches the personal history only once the writer's next keystrokes settle it.
final class AutoFixOutcomeTrackerTests: XCTestCase {
    func test_typingPastTheFix_confirmsIt() {
        // #given "teh " auto-fixed to "the "
        var tracker = AutoFixOutcomeTracker()
        tracker.noteAutoFix(typo: "teh", fix: "the", precedingText: "I saw teh ")

        // #when the writer finishes another word
        XCTAssertEqual(tracker.observe("I saw the ca"), [])
        let outcomes = tracker.observe("I saw the cat ")

        // #then the fix is confirmed
        XCTAssertEqual(outcomes, [.init(kind: .confirmed, typo: "teh", fix: "the")])
        XCTAssertEqual(tracker.pendingCount, 0)
    }

    func test_originalSpellingComingBack_revertsIt() {
        var tracker = AutoFixOutcomeTracker()
        tracker.noteAutoFix(typo: "Kubernets", fix: "Kubernetes", precedingText: "deploy to Kubernets ")
        XCTAssertEqual(tracker.observe("deploy to Kubernetes "), [])

        let outcomes = tracker.observe("deploy to Kubernets ")

        XCTAssertEqual(outcomes, [.init(kind: .reverted, typo: "kubernets", fix: "kubernetes")])
    }

    func test_textInAnotherField_isNotAVerdictOnTheFix() {
        // #given a fix of the first word in one field (nothing stands before it)
        var tracker = AutoFixOutcomeTracker()
        tracker.noteAutoFix(typo: "teh", fix: "the", precedingText: "teh ", field: 7)

        // #when another field happens to begin with the fixed word and goes on
        let elsewhere = tracker.observe("the meeting is at noon ", field: 8)

        // #then that says nothing about the fix, and it is no longer waited for
        XCTAssertEqual(elsewhere, [])
        XCTAssertEqual(tracker.pendingCount, 0)
    }

    func test_typoStillStandingBeforeTheFixWasEverSeen_isNotAnUndo() {
        // #given a fix whose keys have not reached the field yet, or never did
        var tracker = AutoFixOutcomeTracker()
        tracker.noteAutoFix(typo: "recieve", fix: "receive", precedingText: "did you recieve ")

        // #when the field is read and still holds what was typed
        let early = tracker.observe("did you recieve ")

        // #then nothing is concluded: the writer undid nothing, and the slip must not be marked
        // as a word they meant
        XCTAssertEqual(early, [])
        XCTAssertEqual(tracker.pendingCount, 1)

        // #and once the fix shows up and is typed past, it counts as kept
        XCTAssertEqual(tracker.observe("did you receive "), [])
        XCTAssertEqual(tracker.observe("did you receive it today ").first?.kind, .confirmed)
    }

    func test_backspacingIntoTheFix_waits() {
        var tracker = AutoFixOutcomeTracker()
        tracker.noteAutoFix(typo: "teh", fix: "the", precedingText: "I saw teh ")

        XCTAssertEqual(tracker.observe("I saw th"), [])
        XCTAssertEqual(tracker.observe("I saw teh"), [], "the retyped word is not finished yet")
        XCTAssertEqual(tracker.observe("I saw teh ").first?.kind, .reverted)
    }

    func test_editingEarlierText_dropsTheFixWithoutAVerdict() {
        var tracker = AutoFixOutcomeTracker()
        tracker.noteAutoFix(typo: "teh", fix: "the", precedingText: "I saw teh ")

        XCTAssertEqual(tracker.observe("We saw the cat "), [])
        XCTAssertEqual(tracker.pendingCount, 0)
    }

    func test_capitalizationFix_isNotTracked() {
        var tracker = AutoFixOutcomeTracker()
        tracker.noteAutoFix(typo: "it", fix: "It", precedingText: "Done. it ")

        XCTAssertEqual(tracker.pendingCount, 0)
        XCTAssertEqual(tracker.observe("Done. It "), [])
    }

    func test_mismatchedTypo_isIgnored() {
        var tracker = AutoFixOutcomeTracker()
        tracker.noteAutoFix(typo: "teh", fix: "the", precedingText: "I saw it ")

        XCTAssertEqual(tracker.pendingCount, 0)
    }

    func test_thirdWordWhereTheFixWas_isAReplacedFix() {
        // #given `thay ` fixed to `they `, seen in the field
        var tracker = AutoFixOutcomeTracker()
        tracker.noteAutoFix(typo: "thay", fix: "they", precedingText: "I think thay ")
        XCTAssertEqual(tracker.observe("I think they "), [])

        // #when the writer deletes the fix and types another word
        XCTAssertEqual(tracker.observe("I think the"), [])
        XCTAssertEqual(tracker.observe("I think tha"), [])
        let outcomes = tracker.observe("I think that ")

        // #then the fix is reported as replaced, with the word that was meant
        XCTAssertEqual(outcomes, [.init(kind: .replaced, typo: "thay", fix: "they", replacement: "that")])
        XCTAssertEqual(tracker.pendingCount, 0)
    }

    func test_thirdWordBeforeTheFixWasEverSeen_isNoVerdict() {
        // #given a fix that the field has not shown yet
        var tracker = AutoFixOutcomeTracker()
        tracker.noteAutoFix(typo: "thay", fix: "they", precedingText: "I think thay ")

        // #then other text in that place settles nothing
        XCTAssertEqual(tracker.observe("I think that "), [])
        XCTAssertEqual(tracker.pendingCount, 1)
    }

    func test_wordStillBeingRetyped_isNotAReplacementYet() {
        var tracker = AutoFixOutcomeTracker()
        tracker.noteAutoFix(typo: "thay", fix: "they", precedingText: "I think thay ")
        XCTAssertEqual(tracker.observe("I think they "), [])

        XCTAssertEqual(tracker.observe("I think tha"), [])
        XCTAssertEqual(tracker.pendingCount, 1)
    }
}

/// The global auto-fix bar rises only for a writer who keeps undoing auto-fixes.
final class AdaptiveAutoApplyThresholdTests: XCTestCase {
    func test_fewAutoFixes_keepTheBaseBar() {
        XCTAssertEqual(TypoGate.Settings.adaptedAutoApplyMinimumScore(autoApplied: 10, reverted: 5), 1.12)
    }

    func test_rareUndos_keepTheBaseBar() {
        XCTAssertEqual(TypoGate.Settings.adaptedAutoApplyMinimumScore(autoApplied: 100, reverted: 2), 1.12)
    }

    func test_frequentUndos_raiseTheBarWithACap() {
        let tenPercent = TypoGate.Settings.adaptedAutoApplyMinimumScore(autoApplied: 100, reverted: 10)
        let half = TypoGate.Settings.adaptedAutoApplyMinimumScore(autoApplied: 100, reverted: 50)

        XCTAssertEqual(tenPercent, 1.40, accuracy: 0.001)
        XCTAssertEqual(half, 1.72, accuracy: 0.001)
    }
}

final class SentenceFixOutcomeTrackerTests: XCTestCase {
    func test_wordChanges_ignoreCaseAndPunctuationFixes() {
        let changes = SentenceFixOutcomeTracker.wordChanges(original: "i saw teh cat", corrected: "I saw the cat.")

        XCTAssertEqual(changes.map { "\($0.typed)>\($0.fixed)" }, ["teh>the"])
    }

    func test_wordChanges_skipMergedWords() {
        XCTAssertTrue(SentenceFixOutcomeTracker.wordChanges(original: "a lot of", corrected: "alot of").isEmpty)
    }

    func test_sentenceFix_isUndoneOnlyAfterItWasSeenInTheField() {
        // #given a sentence fix just sent to the field
        var tracker = SentenceFixOutcomeTracker()
        tracker.noteApplied(original: "Did you recieve it.", corrected: "Did you receive it.")

        // #when the next read still shows the sentence as typed (the fix has not landed, or was lost)
        XCTAssertEqual(tracker.observe("Did you recieve it. "), [])

        // #then it is undone only if it lands and the original then comes back
        XCTAssertEqual(tracker.observe("Did you receive it. "), [])
        XCTAssertEqual(
            tracker.observe("Did you recieve it. "),
            [.reverted(original: "Did you recieve it.", corrected: "Did you receive it.")]
        )
    }

    func test_sentenceFixThatNeverLanded_isNeverCalledUndone() {
        var tracker = SentenceFixOutcomeTracker()
        tracker.noteApplied(original: "Did you recieve it.", corrected: "Did you receive it.")

        for text in ["Did you recieve it. ", "Did you recieve it. And", "Did you recieve it. And then some more."] {
            XCTAssertEqual(tracker.observe(text), [], text)
        }
    }

    func test_removedSentence_isDroppedWithoutAVerdict() {
        var tracker = SentenceFixOutcomeTracker()
        tracker.noteApplied(original: "I saw teh cat.", corrected: "I saw the cat.")

        XCTAssertEqual(tracker.observe("I saw the cat. "), [])
        XCTAssertEqual(tracker.observe(""), [])
        XCTAssertEqual(tracker.observe("I saw the cat. and much more text"), [])
    }
}
