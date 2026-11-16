import XCTest
@testable import Cotabby

/// The writer's learned phrases: keyed like the bundled table, the empty context served by initial.
@MainActor
final class PersonalPhraseModelTests: XCTestCase {
    func test_learnedSentence_countsEachWordAfterItsContexts() {
        // #given one learned sentence
        let model = PersonalPhraseModel(fileURL: nil)

        // #when it is learned
        model.learn(sentence: "We ship on Friday.")

        // #then its pairs and longer contexts are available
        XCTAssertEqual(model.pairCount(first: "ship", second: "on"), 1)
        XCTAssertEqual(model.nextWords(after: ["we", "ship"])?.counts, ["on": 1])
        XCTAssertEqual(model.nextWords(after: ["<s>"])?.counts, ["we": 1])
    }

    func test_emptyContextIsServedByPrefix() {
        let model = PersonalPhraseModel(fileURL: nil)
        model.learn(sentence: "We ship on Friday.")
        model.learn(sentence: "Ship it now.")

        XCTAssertNil(model.nextWords(after: []))
        XCTAssertEqual(model.words(startingWith: "sh")?.counts, ["ship": 2])
        XCTAssertEqual(model.words(startingWith: "sh")?.total, 6, "Friday is a name, not a word")
        XCTAssertNil(model.words(startingWith: "zz"))
    }

    func test_resetForgetsEverything() {
        let model = PersonalPhraseModel(fileURL: nil)
        model.learn(sentence: "We ship on Friday.")

        model.reset()

        XCTAssertNil(model.nextWords(after: ["we"]))
        XCTAssertNil(model.words(startingWith: "we"))
    }
}
