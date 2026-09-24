import XCTest
@testable import Cotabby

/// Pins which text counts as a just-finished sentence, the minimal keystroke edit that applies a fix,
/// and the word diff the proofreading card highlights.
final class SentenceCheckPlanningTests: XCTestCase {
    func test_extract_returnsTheSentenceFinishedByTheLastSpace() {
        let finished = FinishedSentenceExtractor.extract(from: "Hi Sarah. I recieved there email yesterday. ")

        XCTAssertEqual(finished?.sentence, "I recieved there email yesterday.")
        XCTAssertEqual(finished?.trailingWhitespace, " ")
        XCTAssertEqual(finished?.precedingContext, "Hi Sarah. ")
    }

    func test_extract_keepsAbbreviationsInsideOneSentence() {
        XCTAssertEqual(
            FinishedSentenceExtractor.extract(from: "We met Dr. Smith at the clinic today. ")?.sentence,
            "We met Dr. Smith at the clinic today."
        )
    }

    func test_extract_ignoresUnfinishedShortAndMachineText() {
        XCTAssertNil(FinishedSentenceExtractor.extract(from: "I recieved there email yesterday."), "no finishing space yet")
        XCTAssertNil(FinishedSentenceExtractor.extract(from: "Sounds good. "), "too short to check")
        XCTAssertNil(FinishedSentenceExtractor.extract(from: "Open https://example.com/a for the doc. "))
        XCTAssertNil(FinishedSentenceExtractor.extract(from: "Set the value to x == y in the config file. "))
        XCTAssertNil(FinishedSentenceExtractor.extract(from: "I am still typing this sentence "))
    }

    func test_plan_retypesOnlyFromTheFirstChangedCharacter() {
        let finished = FinishedSentence(sentence: "I recieved there email yesterday.", trailingWhitespace: " ", precedingContext: "")

        let plan = SentenceRewritePlanner.plan(
            precedingText: "Hi. I recieved there email yesterday. ",
            finished: finished,
            corrected: "I received their email yesterday."
        )

        XCTAssertEqual(plan?.replacementText, "eived their email yesterday. ")
        XCTAssertEqual(plan?.deletingUTF16Count, "ieved there email yesterday. ".utf16.count)
    }

    func test_plan_failsClosedWhenTheFieldMovedOn() {
        let finished = FinishedSentence(sentence: "I recieved there email yesterday.", trailingWhitespace: " ", precedingContext: "")

        XCTAssertNil(SentenceRewritePlanner.plan(
            precedingText: "I recieved there email yesterday. Then",
            finished: finished,
            corrected: "I received their email yesterday."
        ))
        XCTAssertNil(SentenceRewritePlanner.plan(
            precedingText: "I recieved there email yesterday. ",
            finished: finished,
            corrected: "I recieved there email yesterday."
        ), "an unchanged sentence has nothing to apply")
    }

    func test_plan_refusesRewritesTooLongToTypeSafely() {
        let sentence = "a" + String(repeating: " word", count: 30) + "."
        let finished = FinishedSentence(sentence: sentence, trailingWhitespace: " ", precedingContext: "")

        XCTAssertNil(SentenceRewritePlanner.plan(precedingText: sentence + " ", finished: finished, corrected: "A" + sentence.dropFirst()))
    }

    func test_wordDiff_marksOnlyChangedWords() {
        let segments = SentenceWordDiff.segments(
            original: "I recieved there email yesterday.",
            corrected: "I received their email yesterday."
        )

        XCTAssertEqual(segments.filter(\.isChanged).map(\.text), ["received", "their"])
        XCTAssertEqual(segments.map(\.text).joined(separator: " "), "I received their email yesterday.")
    }
}
