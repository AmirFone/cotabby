import XCTest
@testable import Cotabby

/// Turning the training log's event stream into exported examples.
final class TrainingExampleBuilderTests: XCTestCase {
    private let day = "2026-11-15"

    func test_untouchedSentence_isItsOwnTarget() {
        // #given a sentence nothing was offered for
        let events: [TrainingLogEvent] = [.sentence(text: "The meeting starts at noon.", day: day)]

        // #when examples are built
        let examples = TrainingExampleBuilder.examples(from: events)

        // #then typed and final are the same sentence, with no changes listed
        XCTAssertEqual(examples, [
            TrainingExample(
                scope: "sentence", day: day, typed: "The meeting starts at noon.",
                final: "The meeting starts at noon.", accepted: [], rejected: []
            )
        ])
    }

    func test_keptAutomaticFix_isPutBackIntoWhatWasTyped() {
        // #given a word fixed while typing, then the finished sentence
        let events: [TrainingLogEvent] = [
            .word(how: "autoFixKept", typed: "teh", final: "the", offered: nil),
            .sentence(text: "I saw the cat.", day: day)
        ]

        // #when examples are built
        let example = TrainingExampleBuilder.examples(from: events).first

        // #then the typed sentence has the misspelling back and the fix counts as accepted
        XCTAssertEqual(example?.typed, "I saw teh cat.")
        XCTAssertEqual(example?.final, "I saw the cat.")
        XCTAssertEqual(example?.accepted, [.init(typed: "teh", fix: "the", how: "autoFix")])
    }

    func test_fixedWord_isNotLookedForInsideOtherWords() {
        let events: [TrainingLogEvent] = [
            .word(how: "autoFixKept", typed: "teh", final: "the", offered: nil),
            .sentence(text: "Another one for the others.", day: day)
        ]

        XCTAssertEqual(TrainingExampleBuilder.examples(from: events).first?.typed, "Another one for teh others.")
    }

    func test_undoneAutomaticFix_isRejectedWithWhatWasOffered() {
        // #given a fix the writer undid
        let events: [TrainingLogEvent] = [
            .word(how: "autoFixUndone", typed: "Okafor", final: "Okafor", offered: "Aquifer"),
            .sentence(text: "We met Okafor today.", day: day)
        ]

        // #when examples are built
        let example = TrainingExampleBuilder.examples(from: events).first

        // #then the sentence is unchanged and the offer is listed as rejected
        XCTAssertEqual(example?.typed, "We met Okafor today.")
        XCTAssertEqual(example?.rejected, [.init(typed: "Okafor", fix: "Aquifer", how: "autoFix")])
        XCTAssertEqual(example?.accepted, [])
    }

    func test_wordKeptFromTheBar_isRejectedAsOffered() {
        let events: [TrainingLogEvent] = [
            .word(how: "keptAsTyped", typed: "Kubernetes", final: "Kubernetes", offered: nil),
            .sentence(text: "We run Kubernetes here.", day: day)
        ]

        XCTAssertEqual(
            TrainingExampleBuilder.examples(from: events).first?.rejected,
            [.init(typed: "Kubernetes", fix: nil, how: "offered")]
        )
    }

    func test_pickedAndSelfCorrectedWords_areAccepted() {
        let events: [TrainingLogEvent] = [
            .word(how: "picked", typed: "recipt", final: "receipt", offered: nil),
            .word(how: "selfCorrected", typed: "tommorow", final: "tomorrow", offered: nil),
            .sentence(text: "Send the receipt tomorrow please.", day: day)
        ]

        let example = TrainingExampleBuilder.examples(from: events).first

        XCTAssertEqual(example?.typed, "Send the recipt tommorow please.")
        XCTAssertEqual(example?.accepted.map(\.how), ["picked", "selfCorrected"])
    }

    func test_keptSentenceFix_confirmedAfterTheSentenceWasRecorded() {
        // #given a sentence fixed at its end, recorded, and only then confirmed by typing on
        let events: [TrainingLogEvent] = [
            .sentence(text: "I drive a Toyota Corolla to work.", day: day),
            .sentenceFix(original: "I drive a Tyoda Corola to work.", corrected: "I drive a Toyota Corolla to work.", kept: true)
        ]

        // #when examples are built
        let example = TrainingExampleBuilder.examples(from: events).first

        // #then typed is the sentence before the fix, with each changed word in its own casing
        XCTAssertEqual(example?.typed, "I drive a Tyoda Corola to work.")
        XCTAssertEqual(example?.final, "I drive a Toyota Corolla to work.")
        XCTAssertEqual(example?.accepted, [
            .init(typed: "Tyoda", fix: "Toyota", how: "sentenceFix"),
            .init(typed: "Corola", fix: "Corolla", how: "sentenceFix")
        ])
    }

    func test_keptSentenceFix_confirmedBeforeTheSentenceWasRecorded() {
        let events: [TrainingLogEvent] = [
            .sentenceFix(original: "She went too the shop.", corrected: "She went to the shop.", kept: true),
            .sentence(text: "She went to the shop.", day: day)
        ]

        XCTAssertEqual(TrainingExampleBuilder.examples(from: events).first?.typed, "She went too the shop.")
    }

    func test_wordFixAndSentenceFix_areBothUndoneInTyped() {
        // #given a word fixed while typing and another fixed when the sentence was finished
        let events: [TrainingLogEvent] = [
            .word(how: "autoFixKept", typed: "teh", final: "the", offered: nil),
            .sentence(text: "I parked the Toyota outside.", day: day),
            .sentenceFix(original: "I parked the Tyoda outside.", corrected: "I parked the Toyota outside.", kept: true)
        ]

        // #when examples are built
        let example = TrainingExampleBuilder.examples(from: events).first

        // #then typed has both misspellings
        XCTAssertEqual(example?.typed, "I parked teh Tyoda outside.")
        XCTAssertEqual(example?.accepted.map(\.how), ["autoFix", "sentenceFix"])
    }

    func test_undoneSentenceFix_dropsTheCorrectedSentenceAndRejectsTheChange() {
        // #given a sentence fix that was recorded, then undone, after which the original stands
        let events: [TrainingLogEvent] = [
            .sentence(text: "Ask Lundqvist about it.", day: day),
            .sentenceFix(original: "Ask Lindqvist about it.", corrected: "Ask Lundqvist about it.", kept: false),
            .sentence(text: "Ask Lindqvist about it.", day: day)
        ]

        // #when examples are built
        let examples = TrainingExampleBuilder.examples(from: events)

        // #then only the writer's sentence remains, with the fix listed as rejected
        XCTAssertEqual(examples.map(\.final), ["Ask Lindqvist about it."])
        XCTAssertEqual(examples.first?.typed, "Ask Lindqvist about it.")
        XCTAssertEqual(examples.first?.rejected, [.init(typed: "Lindqvist", fix: "Lundqvist", how: "sentenceFix")])
    }

    func test_wordEventSettledLate_goesToTheSentenceItFits() {
        // #given a fix whose outcome was only settled after the next sentence began
        let events: [TrainingLogEvent] = [
            .sentence(text: "I saw the cat.", day: day),
            .word(how: "autoFixKept", typed: "teh", final: "the", offered: nil),
            .sentence(text: "It ran off quickly.", day: day)
        ]

        // #when examples are built
        let examples = TrainingExampleBuilder.examples(from: events)

        // #then it lands on the sentence that holds the word
        XCTAssertEqual(examples.map(\.typed), ["I saw teh cat.", "It ran off quickly."])
    }

    func test_wordEventWithNoSentence_isAWordExample() {
        // #given a fix in text that never became a recorded sentence (a search box, a short reply)
        let events: [TrainingLogEvent] = [.word(how: "picked", typed: "recieve", final: "receive", offered: nil)]

        // #when examples are built
        let examples = TrainingExampleBuilder.examples(from: events)

        // #then it is still exported, as a word pair
        XCTAssertEqual(examples, [
            TrainingExample(
                scope: "word", day: nil, typed: "recieve", final: "receive",
                accepted: [.init(typed: "recieve", fix: "receive", how: "picked")], rejected: []
            )
        ])
    }

    func test_jsonLines_areOneSortedObjectPerLine() throws {
        // #given two examples
        let examples = TrainingExampleBuilder.examples(from: [
            .word(how: "autoFixKept", typed: "teh", final: "the", offered: nil),
            .sentence(text: "I saw the cat.", day: day),
            .sentence(text: "It ran off quickly.", day: day)
        ])

        // #when they are written out
        let lines = String(decoding: TrainingExampleBuilder.jsonLines(examples), as: UTF8.self)
            .split(separator: "\n").map(String.init)

        // #then each line is one JSON object that reads back as the example
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(try JSONDecoder().decode(TrainingExample.self, from: Data(lines[0].utf8)), examples[0])
        XCTAssertTrue(lines[0].hasPrefix(#"{"accepted":[{"fix":"the","how":"autoFix","typed":"teh"}],"day":"2026-11-15","final":"I saw the cat.""#))
    }

    func test_logEvent_survivesItsJSONForm() {
        let events: [TrainingLogEvent] = [
            .sentence(text: "I saw the cat.", day: day),
            .word(how: "autoFixUndone", typed: "Okafor", final: "Okafor", offered: "Aquifer"),
            .word(how: "picked", typed: "recipt", final: "receipt", offered: nil),
            .sentenceFix(original: "a", corrected: "b", kept: false)
        ]

        XCTAssertEqual(events.compactMap { TrainingLogEvent(json: $0.json) }, events)
    }

    func test_unknownLogLine_isSkipped() {
        XCTAssertNil(TrainingLogEvent(json: ["event": "somethingNewer", "text": "x"]))
    }
}
