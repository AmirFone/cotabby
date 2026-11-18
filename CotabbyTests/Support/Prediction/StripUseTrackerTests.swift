import XCTest
@testable import Cotabby

/// What the word strip showed for a word and what the writer did, as the training record keeps it.
final class StripUseTrackerTests: XCTestCase {
    func test_wordTypedOut_reportsWhatWasShownBeforeAndAtTheEnd() {
        // #given a strip shown before the word, and again after two letters
        var tracker = StripUseTracker()
        XCTAssertNil(tracker.typed("We met "))
        tracker.shown(["the", "a", "at"], for: "We met ")
        XCTAssertNil(tracker.typed("We met y"))
        tracker.shown(["you", "yesterday", "your"], for: "We met ye")

        // #when the writer finishes the word themselves
        let use = tracker.typed("We met yesterday ")

        // #then both lists are kept, with how far the word had got when the last one was up
        XCTAssertEqual(use, StripUse(
            before: "We met", word: "yesterday", shownFirst: ["the", "a", "at"],
            shownLast: ["you", "yesterday", "your"], lettersTyped: 2, pickedSlot: nil
        ))
    }

    func test_pick_reportsTheSlotAndTheLettersTyped() {
        var tracker = StripUseTracker()
        _ = tracker.typed("We met ")
        tracker.shown(["the", "a"], for: "We met ")
        tracker.shown(["yesterday", "you"], for: "We met ye")

        let use = tracker.picked(slot: 0, word: "yesterday", shown: ["yesterday", "you"], textBefore: "We met ye")

        XCTAssertEqual(use.pickedSlot, 0)
        XCTAssertEqual(use.lettersTyped, 2)
        XCTAssertEqual(use.shownFirst, ["the", "a"])
        XCTAssertEqual(use.before, "We met")
        // The space the pick typed is not a second finished word.
        XCTAssertNil(tracker.typed("We met yesterday "))
    }

    func test_onlyTheCurrentSentence_isKeptAsWhatCameBefore() {
        var tracker = StripUseTracker()
        _ = tracker.typed("It rained. Then we ")
        tracker.shown(["went"], for: "It rained. Then we ")

        XCTAssertEqual(tracker.typed("It rained. Then we left ")?.before, "Then we")
    }

    func test_wordWithNoStripShown_isNotReported() {
        var tracker = StripUseTracker()
        _ = tracker.typed("We met ")

        XCTAssertNil(tracker.typed("We met yesterday "))
    }

    func test_deletionPasteOrAnotherField_startsOverWithoutAReport() {
        var tracker = StripUseTracker()
        _ = tracker.typed("We met ")
        tracker.shown(["the"], for: "We met ")

        // #when text is removed, several words arrive at once, or the field changes
        XCTAssertNil(tracker.typed("We "))
        tracker.shown(["are"], for: "We ")
        XCTAssertNil(tracker.typed("We are going home "))
        XCTAssertNil(tracker.typed("Another field "))
    }

    func test_fixedWord_isReportedAsItStandsWhenTheNextWordStarts() {
        // #given a word whose strip was up while it was typed, then fixed in place by the spelling engine
        var tracker = StripUseTracker()
        _ = tracker.typed("I will ")
        tracker.shown(["be", "go"], for: "I will ")
        tracker.shown(["receive", "recall"], for: "I will rec")

        // #when the next text the strip hears of already has the fixed word and its space
        let use = tracker.typed("I will receive ")

        // #then the use is for the word as it stands, against what the strip had shown
        XCTAssertEqual(use?.word, "receive")
        XCTAssertEqual(use?.shownLast, ["receive", "recall"])
    }
}
