import XCTest
@testable import Cotabby

/// What the word model is shown of the writer's earlier texts before the field's own.
@MainActor
final class RecentWritingTests: XCTestCase {
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
        recent.add("an older message")
        recent.add("the nightly job failed again")

        // #when the field asks with that sentence in it
        let preamble = recent.preamble(for: "the nightly job failed again. Please ")

        // #then the model does not read it twice
        XCTAssertEqual(preamble, "an older message\n")
    }

    func test_preamble_isEmptyWhenTheFieldHasEnoughTextOfItsOwn() {
        // #given a kept text and a long document
        let recent = RecentWriting()
        recent.add("an older message")
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
        let texts = (0..<13).map { String(repeating: Character(UnicodeScalar(UInt8(97 + $0))), count: 99) }

        // #when they are added one by one
        texts.forEach(recent.add)

        // #then the newest two thirds of a page are left, so the next sentences do not move its beginning
        XCTAssertEqual(recent.texts, Array(texts.suffix(8)))
    }

    func test_belowTheLimit_nothingIsDropped() {
        // #given texts that stay under the limit
        let recent = RecentWriting()
        let texts = (0..<11).map { String(repeating: Character(UnicodeScalar(UInt8(97 + $0))), count: 99) }

        texts.forEach(recent.add)

        XCTAssertEqual(recent.texts, texts)
    }

    func test_aPastedBlock_isNotKept() {
        // #given a text longer than any typed message
        let recent = RecentWriting()
        recent.add("a short message")

        // #when it is added
        recent.add(String(repeating: "pasted ", count: 100))

        // #then what was there stays and the block is left out
        XCTAssertEqual(recent.texts, ["a short message"])
    }

    func test_theSameTextTwiceInARow_isKeptOnce() {
        let recent = RecentWriting()
        recent.add("thanks, will do")
        recent.add("thanks, will do")

        XCTAssertEqual(recent.texts, ["thanks, will do"])
    }

    func test_clear_forgetsEverything() {
        let recent = RecentWriting()
        recent.add("an older message")

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
