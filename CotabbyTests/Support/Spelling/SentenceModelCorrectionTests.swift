import XCTest
@testable import Cotabby

/// The sentence model's decoder and gate, driven by a scripted model: one piece per character, and
/// a fixed answer the "model" wants to write. No weights are loaded.
final class SentenceModelCorrectionTests: XCTestCase {
    // MARK: - Decoder

    func test_correctSentence_isConfirmedInOnePass() {
        // #given a sentence the model would write back unchanged
        let model = ScriptedModel(typed: "I went to the store.", answer: "I went to the store.")

        // #when it is decoded
        let output = SentenceModelDecoder.correct("I went to the store.", model: model)

        // #then one pass confirms every word
        XCTAssertEqual(output?.words.map(\.text), ["I", "went", "to", "the", "store."])
        XCTAssertEqual(output?.passes, 1)
    }

    func test_oneWrongWord_isRewrittenAndTheRestConfirmedInOnePass() {
        // #given a misspelled name in the middle of a sentence
        let typed = "I drive a Tyoda to work."
        let model = ScriptedModel(typed: typed, answer: "I drive a Toyota to work.")

        // #when it is decoded
        let output = SentenceModelDecoder.correct(typed, model: model)

        // #then the answer is the model's, in far fewer passes than one per character:
        // the first pass, the five pieces after `T`, and one pass for ` to work.`
        XCTAssertEqual(output?.words.map(\.text), ["I", "drive", "a", "Toyota", "to", "work."])
        XCTAssertEqual(output?.passes, 7)
    }

    func test_neighboringWrongWords_areBothRewritten() {
        let typed = "teh cta sat down."
        let model = ScriptedModel(typed: typed, answer: "the cat sat down.")

        let output = SentenceModelDecoder.correct(typed, model: model)

        XCTAssertEqual(output?.words.map(\.text), ["the", "cat", "sat", "down."])
    }

    func test_wordProbability_isTheLowestOfItsPieces() {
        // #given a model that is unsure of one letter of the word it changes
        let typed = "I drive a Tyoda to work."
        let model = ScriptedModel(typed: typed, answer: "I drive a Toyota to work.")
        model.logProbabilities[12] = Float(log(0.5)) // the `y` of `Toyota`

        // #when it is decoded
        let output = SentenceModelDecoder.correct(typed, model: model)

        // #then that word carries the low probability and its neighbors do not
        XCTAssertEqual(output?.words[3].probability ?? 0, 0.5, accuracy: 0.01)
        XCTAssertGreaterThan(output?.words[2].probability ?? 0, 0.95)
        XCTAssertGreaterThan(output?.words[4].probability ?? 0, 0.95)
    }

    func test_answerThatKeepsGoing_stopsAndIsRejectedByTheGate() {
        // #given a model that adds words instead of correcting
        let typed = "It works."
        let model = ScriptedModel(typed: typed, answer: "It works. And then some more words follow here.")

        // #when it is decoded and gated
        let output = SentenceModelDecoder.correct(typed, model: model)
        let result = output.flatMap { SentenceModelGate.result(typed: typed, output: $0, isKnownWord: Self.isRealWord) }

        // #then decoding stops within its budget and nothing is changed
        XCTAssertNotNil(output)
        XCTAssertNil(result)
    }

    func test_modelThatCannotRun_givesNoAnswer() {
        let model = ScriptedModel(typed: "It works fine.", answer: "It works fine.")
        model.isBroken = true

        XCTAssertNil(SentenceModelDecoder.correct("It works fine.", model: model))
    }

    // MARK: - Gate

    func test_sureFixOfAMisspelling_isApplied() {
        let typed = "I drive a Tyoda Corola to work."
        let output = Self.output(["I", "drive", "a", "Toyota", "Corolla", "to", "work."], probabilities: [3: 0.97, 4: 0.93])

        let result = SentenceModelGate.result(typed: typed, output: output, isKnownWord: Self.isRealWord)

        XCTAssertEqual(result?.autoCorrected, "I drive a Toyota Corolla to work.")
        XCTAssertEqual(result?.flags.count, 0)
    }

    func test_lessSureFix_isOfferedForReviewAtTheRightPlace() {
        // #given one sure fix that lengthens the sentence, then one unsure fix after it
        let typed = "My Tyoda is thier car."
        let output = Self.output(["My", "Toyota", "is", "their", "car."], probabilities: [1: 0.97, 3: 0.7])

        let result = SentenceModelGate.result(typed: typed, output: output, isKnownWord: Self.isRealWord)

        // #then the sure one is applied and the flag points at the typed word in the new sentence
        XCTAssertEqual(result?.autoCorrected, "My Toyota is thier car.")
        XCTAssertEqual(result?.flags.map(\.options), [["their"]])
        XCTAssertEqual(result.map { String($0.autoCorrected[$0.flags[0].range]) }, "thier")
        XCTAssertEqual(result?.suggested, "My Toyota is their car.")
    }

    func test_replacingAKnownWord_needsASurerModel() {
        let typed = "I want to go their now."
        let isKnownWord: (String) -> Bool = { ["their", "there"].contains($0) }

        let fairlySure = Self.output(["I", "want", "to", "go", "there", "now."], probabilities: [4: 0.92])
        let verySure = Self.output(["I", "want", "to", "go", "there", "now."], probabilities: [4: 0.97])

        XCTAssertEqual(SentenceModelGate.result(typed: typed, output: fairlySure, isKnownWord: isKnownWord)?.autoCorrected, typed)
        XCTAssertEqual(SentenceModelGate.result(typed: typed, output: fairlySure, isKnownWord: isKnownWord)?.flags.count, 1)
        XCTAssertEqual(
            SentenceModelGate.result(typed: typed, output: verySure, isKnownWord: isKnownWord)?.autoCorrected,
            "I want to go there now."
        )
    }

    func test_unsureChange_isDropped() {
        let output = Self.output(["I", "saw", "then", "cat."], probabilities: [2: 0.3])

        XCTAssertNil(SentenceModelGate.result(typed: "I saw teh cat.", output: output, isKnownWord: Self.isRealWord))
    }

    func test_punctuationIsNeverTheGatesBusiness() {
        // #given an answer that changes a word's punctuation, and one that fixes a word inside brackets
        let changedMark = Self.output(["It", "does", "work!"], probabilities: [2: 0.99])
        let insideBrackets = Self.output(["See", "(the", "note)."], probabilities: [1: 0.99])

        // #then the first is ignored and the second keeps its bracket
        XCTAssertNil(SentenceModelGate.result(typed: "It does work.", output: changedMark, isKnownWord: Self.isRealWord))
        XCTAssertEqual(
            SentenceModelGate.result(typed: "See (teh note).", output: insideBrackets, isKnownWord: Self.isRealWord)?.autoCorrected,
            "See (the note)."
        )
    }

    func test_judgments_sayHowSureTheModelWasOfEveryWordItWouldChange() {
        // #given a sentence with a sure fix, a less sure one, a doubtful one, and a changed mark
        let typed = "My Tyoda is thier bset car."
        let output = Self.output(["My", "Toyota", "is", "their", "best", "car!"], probabilities: [1: 0.97, 3: 0.7, 4: 0.3])

        let judgments = SentenceModelGate.judgments(typed: typed, output: output, isKnownWord: Self.isRealWord)

        // #then each changed word is there with its probability and what was done, the one the
        // gate left alone included; punctuation is not a spelling change
        XCTAssertEqual(judgments, [
            SentencePassWord(typed: "Tyoda", written: "Toyota", probability: 0.97, action: "fixed"),
            SentencePassWord(typed: "thier", written: "their", probability: 0.7, action: "asked"),
            SentencePassWord(typed: "bset", written: "best", probability: 0.3, action: "left"),
        ])
    }

    func test_judgments_agreeWithWhatTheGateDoes() {
        // #given the same answer handed to both
        let typed = "My Tyoda is thier bset car."
        let output = Self.output(["My", "Toyota", "is", "their", "best", "car."], probabilities: [1: 0.97, 3: 0.7, 4: 0.3])

        let result = SentenceModelGate.result(typed: typed, output: output, isKnownWord: Self.isRealWord)
        let judgments = SentenceModelGate.judgments(typed: typed, output: output, isKnownWord: Self.isRealWord)

        // #then the fixed words are the ones typed in place and the asked ones the ones flagged
        XCTAssertEqual(result?.autoCorrected, "My Toyota is thier bset car.")
        XCTAssertEqual(result?.flags.map(\.typed), judgments.filter { $0.action == "asked" }.map(\.typed))
    }

    func test_judgments_ofAnAnswerThatCannotBeLinedUp_areEmpty() {
        let output = Self.output(["I", "saw", "the", "big", "cat."], probabilities: [:])

        XCTAssertEqual(SentenceModelGate.judgments(typed: "I saw teh cat.", output: output, isKnownWord: Self.isRealWord), [])
    }

    func test_unknownWordTurnedIntoAnotherUnknownWord_isAskedAbout_notTyped() {
        // #given a term the dictionary lacks, which a very sure model shortens to another it lacks
        let typed = "Check it with kubectl for now."
        let output = Self.output(["Check", "it", "with", "kubelet", "for", "now."], probabilities: [3: 0.99])
        // The system checker accepts `kubelet`, so it counts as known; the app's dictionary lacks it.
        let isKnownWord: (String) -> Bool = { $0 != "kubectl" }
        let words = SentenceModelGate.WordChecks(isInDictionary: { !["kubectl", "kubelet"].contains($0) })

        let result = SentenceModelGate.result(typed: typed, output: output, isKnownWord: isKnownWord, words: words)
        let judgments = SentenceModelGate.judgments(typed: typed, output: output, isKnownWord: isKnownWord, words: words)

        // #then the sentence is left as typed and the change is only put to the writer
        XCTAssertEqual(result?.autoCorrected, typed)
        XCTAssertEqual(result?.flags.map(\.options), [["kubelet"]])
        XCTAssertEqual(judgments.map(\.action), ["asked"])
    }

    func test_wordTheWriterKeptOrMadeTheirOwn_isNeverChangedOrAskedAbout() {
        // #given the same change, to a word the writer has already said they mean
        let typed = "Check it with kubectl for now."
        let output = Self.output(["Check", "it", "with", "kubelet", "for", "now."], probabilities: [3: 0.99])

        let words = SentenceModelGate.WordChecks(isInDictionary: { _ in true }, isWritersOwn: { $0 == "kubectl" })
        let result = SentenceModelGate.result(typed: typed, output: output, isKnownWord: { _ in true }, words: words)
        let judgments = SentenceModelGate.judgments(typed: typed, output: output, isKnownWord: { _ in true }, words: words)

        // #then nothing is done, and the record says the model saw it and left it
        XCTAssertNil(result)
        XCTAssertEqual(judgments.map(\.action), ["left"])
    }

    func test_answerWithADifferentWordCount_isRejected() {
        let output = Self.output(["I", "saw", "the", "big", "cat."], probabilities: [:])

        XCTAssertNil(SentenceModelGate.result(typed: "I saw teh cat.", output: output, isKnownWord: Self.isRealWord))
    }

    /// The dictionary for these tests: the right spellings, and none of the slips.
    private static let isRealWord: (String) -> Bool = {
        ["toyota", "corolla", "their", "there", "the", "best", "big", "cat", "works", "it", "does", "work", "note", "see"]
            .contains($0.lowercased())
    }

    private static func output(_ words: [String], probabilities: [Int: Double]) -> SentenceModelOutput {
        SentenceModelOutput(
            words: words.enumerated().map { SentenceModelOutput.Word(text: $1, probability: probabilities[$0] ?? 0.99) },
            passes: 1
        )
    }
}

/// A stand-in language model: every character is one piece, and after the prompt it always wants to
/// write the next character of `answer`, whatever was fed. That is enough to check the decoder,
/// because the decoder is only correct if it keeps the model's memory in step with what it accepted.
private final class ScriptedModel: SentenceTokenModel {
    private static let end: Int32 = 0
    private let frameLength: Int
    private let answer: [Int32]
    private var memoryCount = 0
    /// Log-probability the model reports for the answer piece at an index (default: nearly certain).
    var logProbabilities: [Int: Float] = [:]
    var isBroken = false

    init(typed: String, answer: String) {
        frameLength = SentenceModelDecoder.prompt(for: typed).unicodeScalars.count
        self.answer = answer.unicodeScalars.map { Int32($0.value) }
    }

    func tokens(for text: String, parsingSpecial: Bool) -> [Int32] {
        text.unicodeScalars.map { Int32($0.value) }
    }

    func bytes(for token: Int32) -> [UInt8] {
        Unicode.Scalar(UInt32(token)).map { Array(String($0).utf8) } ?? []
    }

    func isEnd(_ token: Int32) -> Bool { token == Self.end }

    func append(_ tokens: [Int32], predictionsFrom first: Int) -> [SentenceModelPrediction]? {
        guard !isBroken else { return nil }
        let predictions = (first..<tokens.count).map { index -> SentenceModelPrediction in
            // After `memoryCount + index + 1` pieces, the next answer piece is this one.
            let position = memoryCount + index + 1 - frameLength
            let token = position >= 0 && position < answer.count ? answer[position] : Self.end
            return SentenceModelPrediction(token: token, logProbability: logProbabilities[position] ?? -0.001)
        }
        memoryCount += tokens.count
        return predictions
    }

    func forget(last count: Int) { memoryCount -= count }

    func reset() { memoryCount = 0 }
}
