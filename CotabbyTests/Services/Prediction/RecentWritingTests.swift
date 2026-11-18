import XCTest
@testable import Cotabby

/// What the word model is shown of the writer's earlier texts before the field's own.
@MainActor
final class RecentWritingTests: XCTestCase {
    /// A text of `length` characters in three words, all of one letter, so texts differ entirely.
    private static func text(of length: Int, letter: Int) -> String {
        let character = Character(UnicodeScalar(UInt8(97 + letter)))
        let word = String(repeating: character, count: (length - 2) / 3)
        return [word, word, String(repeating: character, count: length - 2 - 2 * word.count)].joined(separator: " ")
    }

    func test_preamble_isTheKeptTextsOnePerLine() {
        // #given two finished texts
        let recent = RecentWriting()
        recent.add("the nightly job failed again")
        recent.add("please rerun it after lunch")

        // #when a new, empty field asks
        let preamble = recent.preamble(for: "")

        // #then both come first, oldest first, each on its own line
        XCTAssertEqual(preamble, "the nightly job failed again\nplease rerun it after lunch\n")
    }

    func test_preamble_leavesOutATextTheFieldStillShows() {
        // #given a sentence finished in a document, which is still in the field
        let recent = RecentWriting()
        recent.add("an older message here")
        recent.add("the nightly job failed again")

        // #when the field asks with that sentence in it
        let preamble = recent.preamble(for: "the nightly job failed again. Please ")

        // #then the model does not read it twice
        XCTAssertEqual(preamble, "an older message here\n")
    }

    func test_preamble_isEmptyWhenTheFieldHasEnoughTextOfItsOwn() {
        // #given a kept text and a long document
        let recent = RecentWriting()
        recent.add("an older message here")
        let document = String(repeating: "word ", count: RecentWriting.fieldTextThatNeedsNone / 5 + 1)

        // #then the document is read alone
        XCTAssertEqual(recent.preamble(for: document), "")
    }

    func test_nothingKept_readsTheFieldAlone() {
        XCTAssertEqual(RecentWriting().preamble(for: "I want to "), "")
    }

    func test_pastTheLimit_theOldestTextsGoInOneStep() {
        // #given texts of 100 characters, enough to pass the limit
        let recent = RecentWriting()
        let texts = (0..<13).map { Self.text(of: 99, letter: $0) }

        // #when they are added one by one
        texts.forEach(recent.add)

        // #then the newest two thirds of a page are left, so the next sentences do not move its beginning
        XCTAssertEqual(recent.texts, Array(texts.suffix(8)))
    }

    func test_belowTheLimit_nothingIsDropped() {
        // #given texts that stay under the limit
        let recent = RecentWriting()
        let texts = (0..<11).map { Self.text(of: 99, letter: $0) }

        texts.forEach(recent.add)

        XCTAssertEqual(recent.texts, texts)
    }

    func test_aPastedBlock_isNotKept() {
        // #given a text longer than any typed message
        let recent = RecentWriting()
        recent.add("a short message here")

        // #when it is added
        recent.add(String(repeating: "pasted ", count: 100))

        // #then what was there stays and the block is left out
        XCTAssertEqual(recent.texts, ["a short message here"])
    }

    func test_theSameTextTwiceInARow_isKeptOnce() {
        let recent = RecentWriting()
        recent.add("thanks, will do")
        recent.add("thanks, will do")

        XCTAssertEqual(recent.texts, ["thanks, will do"])
    }

    func test_aSentenceWithAWordFixed_replacesTheCopyBeforeTheFix() {
        // #given a sentence kept with a slip in it
        let recent = RecentWriting()
        recent.add("it will effect the result")

        // #when the same sentence comes by again with the word fixed
        recent.add("it will affect the result")

        // #then the model is shown the fixed one only
        XCTAssertEqual(recent.texts, ["it will affect the result"])
    }

    func test_aDifferentSentenceOfTheSameLength_isKeptBesideTheOther() {
        // #given two sentences of five words that share only one
        let recent = RecentWriting()
        recent.add("it will affect the result")

        recent.add("please rerun the nightly job")

        XCTAssertEqual(recent.texts, ["it will affect the result", "please rerun the nightly job"])
    }

    func test_aLineOfOneOrTwoWords_isNotKept() {
        // #given a line too short to say what the writer is working on
        let recent = RecentWriting()

        recent.add("Thanks")
        recent.add("Sounds good")

        XCTAssertEqual(recent.texts, [])
    }

    func test_preamble_doesNotChangeWhileAWordThatCompletesAKeptLineIsTyped() {
        // #given a kept line, and a field in which the writer is typing the same line again
        let recent = RecentWriting()
        recent.add("sounds good to me")

        // #when the last word is typed out but not yet finished with a space
        let whileTyping = recent.preamble(for: "sounds good to me")

        // #then the line is still shown, as it was for every letter before
        XCTAssertEqual(whileTyping, recent.preamble(for: "sounds good to m"))
    }

    func test_preamble_dropsAKeptLineOnceTheFieldHoldsItAsFinishedWords() {
        let recent = RecentWriting()
        recent.add("sounds good to me")

        XCTAssertEqual(recent.preamble(for: "sounds good to me "), "")
    }

    func test_clear_forgetsEverything() {
        let recent = RecentWriting()
        recent.add("an older message here")

        recent.clear()

        XCTAssertEqual(recent.preamble(for: ""), "")
    }

    func test_service_readsTheKeptTextsBeforeTheField() {
        // #given a service that was handed the writer's recent texts
        let recent = RecentWriting()
        recent.add("the nightly job failed again")
        let service = WordLanguageModelService(modelURL: nil, wordListURLs: [], recentWriting: recent)

        // #then the text it asks the model about starts with them
        XCTAssertEqual(service.textRead(forTextBefore: "please re"), "the nightly job failed again\nplease re")
    }

    func test_serviceWithoutRecentTexts_readsTheFieldAlone() {
        let service = WordLanguageModelService(modelURL: nil, wordListURLs: [])

        XCTAssertEqual(service.textRead(forTextBefore: "please re"), "please re")
    }
}
