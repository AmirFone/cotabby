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

        let outcomes = tracker.observe("deploy to Kubernets ")

        XCTAssertEqual(outcomes, [.init(kind: .reverted, typo: "kubernets", fix: "kubernetes")])
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

    func test_removedSentence_isDroppedWithoutAVerdict() {
        var tracker = SentenceFixOutcomeTracker()
        tracker.noteApplied(original: "I saw teh cat.", corrected: "I saw the cat.")

        XCTAssertEqual(tracker.observe("I saw the cat. "), [])
        XCTAssertEqual(tracker.observe(""), [])
        XCTAssertEqual(tracker.observe("I saw the cat. and much more text"), [])
    }
}
