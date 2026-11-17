import XCTest
@testable import Cotabby

/// Which installed model the word language model uses.
@MainActor
final class WordLanguageModelServiceTests: XCTestCase {
    private let gemma = "gemma-4-E2B.i1-Q6_K.gguf"
    private let qwen = "Qwen3.5-0.8B-Base.i1-Q6_K.gguf"

    func test_bestCandidate_isTheStrongestInstalledModelThatFits() {
        // #given a Mac with plenty of memory and both models installed
        let best = WordLanguageModelService.bestCandidate(memoryBytes: 64 << 30) { _ in true }

        // #then the stronger one is used
        XCTAssertEqual(best?.fileName, gemma)
    }

    func test_bestCandidate_onASmallMac_skipsTheLargeModel() {
        // #given 8 GB of memory, where a 3.8 GB model would crowd out the writer's apps
        let best = WordLanguageModelService.bestCandidate(memoryBytes: 8 << 30) { _ in true }

        // #then the small base model is used
        XCTAssertEqual(best?.fileName, qwen)
    }

    func test_bestCandidate_onAMidSizedMac_usesTheMidSizedModel() {
        // #given 12 GB of memory: too little for the 3.8 GB model, enough for the 1.3 GB one
        let best = WordLanguageModelService.bestCandidate(memoryBytes: 12 << 30) { _ in true }

        XCTAssertEqual(best?.fileName, "Qwen3.5-2B-Base.i1-Q4_K_M.gguf")
    }

    func test_bestCandidate_usesWhatIsInstalled() {
        let onlyQwen = WordLanguageModelService.bestCandidate(memoryBytes: 64 << 30) { $0 == self.qwen }
        let nothing = WordLanguageModelService.bestCandidate(memoryBytes: 64 << 30) { _ in false }

        XCTAssertEqual(onlyQwen?.fileName, qwen)
        XCTAssertNil(nothing)
    }

    func test_serviceWithNoModel_answersNothingAndNeverCallsBack() {
        // #given no model file at all
        let service = WordLanguageModelService(modelURL: nil, wordListURLs: [])
        var calls = 0
        service.onReady = { calls += 1 }

        // #when the strip asks
        let answer = service.scores(forTextBefore: "I want to ")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        // #then there is no answer, no redraw, and nothing for the strip to wait for
        XCTAssertNil(answer)
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(service.isAnswerPending(forTextBefore: "I want to "))
    }

    func test_wordLists_areReadInOrderAndAWordListedTwiceTakesItsLargerCount() throws {
        // #given a dictionary and a supplement that repeats two of its words, one with a larger count
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let dictionary = folder.appendingPathComponent("dictionary.txt")
        let supplement = folder.appendingPathComponent("supplement.txt")
        try "the 900\nneighbour 40\nthat's 3\n".write(to: dictionary, atomically: true, encoding: .utf8)
        try "neighbor 30\nthe 5\nthat's 250\nnot a line\n".write(to: supplement, atomically: true, encoding: .utf8)

        // #when both are read, with a file that does not exist between them
        let entries = WordLanguageModelCore.entries(in: [dictionary, folder.appendingPathComponent("missing.txt"), supplement])

        // #then the supplement adds its new word and corrects the count the dictionary understated
        XCTAssertEqual(entries.map(\.word), ["the", "neighbour", "that's", "neighbor"])
        XCTAssertEqual(entries.map(\.count), [900, 40, 250, 30])
    }

    func test_bundledSupplement_hasEverydayWordsTheDictionaryLacks() throws {
        // #given the two lists in the app bundle
        let urls = WordLanguageModelService.bundledWordListURLs()
        XCTAssertEqual(urls.count, 2)
        let dictionary = Set(WordLanguageModelCore.entries(in: [urls[0]]).map(\.word))
        let supplement = WordPredictionController.supplementWords()

        // #then the supplement holds the American and current words, and repeats only the
        // dictionary's contractions (to give them their real counts)
        for word in ["neighbor", "favorite", "traveling", "mom", "you've", "dataset"] {
            XCTAssertTrue(supplement.contains(word), word)
        }
        XCTAssertTrue(supplement.contains("that's"))
        XCTAssertTrue(supplement.intersection(dictionary).allSatisfy { $0.contains("'") })
    }

    private func lookAheadKey(_ text: String, _ probabilities: [String: Float]) -> LanguageModelContext.Key? {
        let scores = LanguageModelFixture.scores(textBefore: text, probabilities)
        guard let context = LanguageModelContext.make(textBefore: text) else { return nil }
        return WordLanguageModelService.lookAheadKey(textBefore: text, context: context, scores: scores)
    }

    func test_lookAheadKey_forAWordTypedInFull_isTheTextWithThatWord() {
        // #given letters that already spell a word, though a longer word is likelier
        let key = lookAheadKey("Yesterday we walk", ["walk": 0.1, "walked": 0.8])

        // #then the look-ahead is for the word as typed: the space may come next
        XCTAssertEqual(key, .init(text: "Yesterday we walk", isSpaced: true))
    }

    func test_lookAheadKey_forLettersThatAreNotAWord_isTheTextWithTheStripsFirstWord() {
        // #given letters that spell no word yet, capitalized by the writer
        let key = lookAheadKey("Yesterday we went. Wal", ["walk": 0.1, "walked": 0.8])

        // #then the look-ahead is for what a pick would type, keeping the writer's letters
        XCTAssertEqual(key, .init(text: "Yesterday we went. Walked", isSpaced: true))
    }

    func test_lookAheadKey_beforeAnyLetterOrWithNoWordToFinish_isNothing() {
        XCTAssertNil(lookAheadKey("Yesterday we ", ["walk": 0.1]))
        XCTAssertNil(lookAheadKey("Yesterday we zz", ["walk": 0.1]))
    }
}
