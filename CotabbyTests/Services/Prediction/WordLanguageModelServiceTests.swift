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
        let service = WordLanguageModelService(modelURL: nil, dictionaryURL: nil)
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
}
