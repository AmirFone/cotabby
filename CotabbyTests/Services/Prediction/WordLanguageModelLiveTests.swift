import XCTest
@testable import Cotabby

/// The word language model service with a real model file: load, answer, refine, and keep up with
/// requests that arrive faster than it answers. Needs no screen or typing, so it can run where the
/// live typing test cannot. Runs only with TEST_RUNNER_WORD_LM_FILE set to a GGUF the app can use.
/// The dictionary is the one in the app bundle the tests run inside.
@MainActor
final class WordLanguageModelLiveTests: XCTestCase {
    private func makeService() throws -> WordLanguageModelService {
        let environment = ProcessInfo.processInfo.environment
        guard let model = environment["WORD_LM_FILE"] else {
            throw XCTSkip("Set TEST_RUNNER_WORD_LM_FILE to run against a real model")
        }
        let dictionary = try XCTUnwrap(Bundle.main.url(forResource: "frequency_dictionary_en_82_765", withExtension: "txt"))
        return WordLanguageModelService(modelURL: URL(fileURLWithPath: model), dictionaryURL: dictionary)
    }

    /// Asks until the service has an answer for `text`, the way the strip does: ask, get nil, be
    /// called back, ask again.
    private func answer(_ service: WordLanguageModelService, for text: String, timeout: TimeInterval = 30) -> LanguageModelScores? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let scores = service.scores(forTextBefore: text) { return scores }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return nil
    }

    func test_pastTenseContext_putsThePastFormFirst() throws {
        // #given a real model and a sentence set in the past
        let service = try makeService()

        // #when the strip asks with the letters `walk` typed
        let scores = answer(service, for: "Yesterday we walk")

        // #then the past form is the likeliest of the forms that start with those letters
        XCTAssertEqual(scores?.best(prefix: "walk", limit: 1).first?.word, "walked")
    }

    func test_answerIsReadyCallback_firesAndNothingStaysPending() throws {
        // #given a service that has not loaded its model yet
        let service = try makeService()
        var callbacks = 0
        service.onReady = { callbacks += 1 }

        // #when an answer is asked for and waited on
        XCTAssertNil(service.scores(forTextBefore: "She is still walk"))
        let scores = answer(service, for: "She is still walk")

        // #then the callback fired, the answer is there, and the strip has nothing left to wait for
        XCTAssertNotNil(scores)
        XCTAssertGreaterThan(callbacks, 0)
        XCTAssertFalse(service.isAnswerPending(forTextBefore: "She is still walk"))
    }

    func test_requestsFasterThanAnswers_endOnTheNewestText() throws {
        // #given a service with its model loaded
        let service = try makeService()
        XCTAssertNotNil(answer(service, for: "I would like "))

        // #when a writer types three words faster than the model answers, with letters in between
        // (each of which asks for a refinement of the answer it has)
        for text in ["I would like t", "I would like to ", "I would like to g", "I would like to go ", "I would like to go h"] {
            _ = service.scores(forTextBefore: text)
        }

        // #then the answer for the newest text arrives; a refinement never took its place
        let newest = answer(service, for: "I would like to go h", timeout: 10)
        XCTAssertEqual(newest?.key.text, "I would like to go")
        XCTAssertFalse(service.isAnswerPending(forTextBefore: "I would like to go h"))
    }

    func test_refinement_leavesTheServiceAnsweringWhateverTheModelCanDo() throws {
        // #given an answer, and letters that single out words sharing a first piece
        let service = try makeService()
        let text = "After the long run my shin"
        guard let first = answer(service, for: text) else { return XCTFail("no answer") }

        // #when the strip keeps asking for the same text, as it does after every redraw, until
        // nothing is left to refine or the model has declined (some cannot take a piece back out of
        // their memory, and are not asked again)
        let deadline = Date().addingTimeInterval(3)
        var latest = first
        while Date() < deadline, !latest.piecesWorthRefining(prefix: "shin").isEmpty {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            latest = service.scores(forTextBefore: text) ?? latest
        }

        // #then the answer is still there for the same text, and the next word is answered too:
        // a refused rollback empties the model's memory, and the next answer must read the text afresh
        XCTAssertEqual(service.scores(forTextBefore: text)?.key, first.key)
        XCTAssertNotNil(answer(service, for: "After the long run my shins were ", timeout: 10))
    }
}
