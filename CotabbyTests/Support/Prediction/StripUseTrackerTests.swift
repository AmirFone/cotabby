import XCTest
@testable import Cotabby

/// What the word strip showed for a word and what the writer did, as the training record keeps it.
final class StripUseTrackerTests: XCTestCase {
    func test_wordTypedOut_reportsWhatWasShownBeforeAndAtTheEnd() {
        // #given a strip shown before the word, and again after two letters
        var tracker = StripUseTracker()
        XCTAssertNil(tracker.typed("We met "))
        _ = tracker.shown(["the", "a", "at"], for: "We met ")
        XCTAssertNil(tracker.typed("We met y"))
        _ = tracker.shown(["you", "yesterday", "your"], for: "We met ye")

        // #when the writer finishes the word themselves
        let use = tracker.typed("We met yesterday ")

        // #then both lists are kept, with how far the word had got when the last one was up
        XCTAssertEqual(use, StripUse(
            before: "We met", word: "yesterday", shownFirst: ["the", "a", "at"],
            shownLast: ["you", "yesterday", "your"], lettersTyped: 2, pickedSlot: nil,
            draws: [.init(typed: "", shown: ["the", "a", "at"]), .init(typed: "ye", shown: ["you", "yesterday", "your"])]
        ))
    }

    func test_slowestMomentsOfAWord_areKeptWithIt() {
        // #given a word whose second key waited 120 ms, whose strips took 3 and 40 ms, and a
        // field read of 95 ms on the way
        var tracker = StripUseTracker()
        _ = tracker.typed("We met ")
        tracker.note(keyHeardAfter: 2)
        _ = tracker.shown(["yes", "you"], for: "We met y")
        tracker.note(stripShownAfter: 3)
        tracker.note(keyHeardAfter: 120)
        tracker.note(readTook: 95)
        _ = tracker.shown(["yesterday", "yes"], for: "We met ye")
        tracker.note(stripShownAfter: 40)

        // #when the word is finished
        let use = tracker.typed("We met yesterday ")

        // #then the record holds the slowest of each
        XCTAssertEqual(use?.timing, StripUse.Timing(key: 120, strip: 40, read: 95))
    }

    func test_readsTheAppLeftUnanswered_areCountedForTheWord() {
        // #given a word during which the app in front missed two reads, then one more
        var tracker = StripUseTracker()
        _ = tracker.typed("We met ")
        _ = tracker.shown(["yes", "you"], for: "We met y")
        tracker.note(readsLeftUnanswered: 2)
        tracker.note(readsLeftUnanswered: 0)
        tracker.note(readsLeftUnanswered: 1)

        // #when the word is finished
        let use = tracker.typed("We met yesterday ")

        // #then the record holds how many
        XCTAssertEqual(use?.timing, StripUse.Timing(missed: 3))
    }

    func test_timingOfOneWord_doesNotCarryOverToTheNext() {
        var tracker = StripUseTracker()
        _ = tracker.typed("We met ")
        _ = tracker.shown(["yes"], for: "We met y")
        tracker.note(keyHeardAfter: 300)
        _ = tracker.typed("We met yesterday ")

        // #when the next word is typed with nothing timed
        _ = tracker.shown(["and"], for: "We met yesterday a")
        let use = tracker.typed("We met yesterday and ")

        XCTAssertNil(use?.timing)
    }

    func test_pick_reportsTheSlotAndTheLettersTyped() {
        var tracker = StripUseTracker()
        _ = tracker.typed("We met ")
        _ = tracker.shown(["the", "a"], for: "We met ")
        _ = tracker.shown(["yesterday", "you"], for: "We met ye")

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
        _ = tracker.shown(["went"], for: "It rained. Then we ")

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
        _ = tracker.shown(["the"], for: "We met ")

        // #when text is removed, several words arrive at once, or the field changes
        XCTAssertNil(tracker.typed("We "))
        _ = tracker.shown(["are"], for: "We ")
        XCTAssertNil(tracker.typed("We are going home "))
        XCTAssertNil(tracker.typed("Another field "))
    }

    func test_fixedWord_isReportedAsItStandsWhenTheNextWordStarts() {
        // #given a word whose strip was up while it was typed, then fixed in place by the spelling engine
        var tracker = StripUseTracker()
        _ = tracker.typed("I will ")
        _ = tracker.shown(["be", "go"], for: "I will ")
        _ = tracker.shown(["receive", "recall"], for: "I will rec")

        // #when the next text the strip hears of already has the fixed word and its space
        let use = tracker.typed("I will receive ")

        // #then the use is for the word as it stands, against what the strip had shown
        XCTAssertEqual(use?.word, "receive")
        XCTAssertEqual(use?.shownLast, ["receive", "recall"])
    }

    func test_stripForTheNextWord_drawnBeforeTheFieldIsRead_reportsTheWordBeforeIt() {
        // #given a word typed out with a strip up, as the keys draw it: every letter gets its
        // strip, and the strip for the word after it is drawn at the space, before any read
        var tracker = StripUseTracker()
        _ = tracker.typed("We ")
        _ = tracker.shown(["are", "have"], for: "We ")
        _ = tracker.shown(["met", "may"], for: "We m")
        _ = tracker.shown(["met", "mean"], for: "We me")
        _ = tracker.shown(["meta"], for: "We met")

        // #when the strip for the next word is drawn
        let use = tracker.shown(["the", "a"], for: "We met ")

        // #then the finished word is reported there, with every strip it had
        XCTAssertEqual(use?.word, "met")
        XCTAssertEqual(use?.draws.map(\.typed), ["", "m", "me", "met"])
        XCTAssertEqual(use?.draws.first { $0.shown.contains("met") }?.typed, "m")
        // And the read that follows does not report it a second time.
        XCTAssertNil(tracker.typed("We met "))
    }

    func test_sameStripDrawnAgain_isKeptOnce() {
        var tracker = StripUseTracker()
        _ = tracker.typed("We ")
        _ = tracker.shown(["are"], for: "We ")
        _ = tracker.shown(["are"], for: "We ")
        _ = tracker.shown(["all"], for: "We a")

        XCTAssertEqual(tracker.typed("We are ")?.draws.count, 2)
    }

    func test_pick_carriesTheStripsDrawnForTheWord() {
        var tracker = StripUseTracker()
        _ = tracker.typed("We met ")
        _ = tracker.shown(["the", "a"], for: "We met ")
        _ = tracker.shown(["yesterday", "you"], for: "We met ye")

        let use = tracker.picked(slot: 0, word: "yesterday", shown: ["yesterday", "you"], textBefore: "We met ye")

        XCTAssertEqual(use.draws.map(\.typed), ["", "ye"])
    }
}
