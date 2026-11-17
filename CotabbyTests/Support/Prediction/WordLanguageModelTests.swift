import XCTest
@testable import Cotabby

/// The pure half of the word language model, with a made-up model: every "piece" is a whole word
/// with an id from a small table, and the model's scores are written by hand.
final class WordLanguageModelTests: XCTestCase {
    // MARK: - Context

    func test_context_afterASpace_readsTheTextWithoutItAndHasNoLetters() {
        // #given a finished word and its space
        // #when the text is split
        let context = LanguageModelContext.make(textBefore: "Yesterday I ")

        // #then the model reads up to the word, and knows a space follows
        XCTAssertEqual(context?.key, .init(text: "Yesterday I", isSpaced: true))
        XCTAssertEqual(context?.prefix, "")
    }

    func test_context_midWord_isTheSameAnswerAsBeforeTheWord() {
        // #given the same sentence with one, then four letters of the next word typed
        let atSpace = LanguageModelContext.make(textBefore: "Yesterday I ")
        let oneLetter = LanguageModelContext.make(textBefore: "Yesterday I w")
        let fourLetters = LanguageModelContext.make(textBefore: "Yesterday I walk")

        // #then the model's answer is shared by all three; only the letters differ
        XCTAssertEqual(oneLetter?.key, atSpace?.key)
        XCTAssertEqual(fourLetters?.key, atSpace?.key)
        XCTAssertEqual(fourLetters?.prefix, "walk")
    }

    func test_context_atTheStartOfALine_isNotSpaced() {
        let context = LanguageModelContext.make(textBefore: "First line.\nTh")

        XCTAssertEqual(context?.key, .init(text: "First line.\n", isSpaced: false))
        XCTAssertEqual(context?.prefix, "Th")
    }

    func test_context_rightAfterPunctuationOrADigit_isNothingToPredict() {
        XCTAssertNil(LanguageModelContext.make(textBefore: "It works."))
        XCTAssertNil(LanguageModelContext.make(textBefore: "the 3rd"))
        XCTAssertNil(LanguageModelContext.make(textBefore: "mail @jo"))
    }

    func test_context_textWithinReach_isReadWhole() {
        // #given a text of many sentences that is shorter than the model's reach
        let text = "One is here. Two is here. Three is here. Four is here. Five is here. Six is here. Seven "

        // #when the text is split
        let context = LanguageModelContext.make(textBefore: text)

        // #then the model reads all of it: the subject set in the first sentence still counts
        XCTAssertEqual(context?.key.text, "One is here. Two is here. Three is here. Four is here. Five is here. Six is here. Seven")
    }

    func test_context_textBeyondReach_startsAtASentenceAndFitsTheReach() {
        // #given a text several times the reach, of sentences that are each different
        let reach = LanguageModelContext.Reach(maximumCharacters: 400, step: 200)
        let text = (0..<60).map { "Sentence number \($0) is here." }.joined(separator: " ") + " And now we "

        // #when the text is split
        let read = LanguageModelContext.make(textBefore: text, reach: reach)?.key.text ?? ""

        // #then what the model reads is the end of the text, within the reach, from a sentence start
        XCTAssertTrue(text.hasSuffix(read + " "))
        XCTAssertLessThanOrEqual(read.utf8.count, reach.maximumCharacters)
        XCTAssertGreaterThan(read.utf8.count, reach.maximumCharacters - reach.step - 40)
        XCTAssertTrue(read.hasPrefix("Sentence number"), read)
    }

    func test_context_startDoesNotMoveUntilAWholeStepHasBeenTyped() {
        // #given a long text, read at every word while two more sentences are typed
        let reach = LanguageModelContext.Reach(maximumCharacters: 400, step: 200)
        var text = (0..<40).map { "Sentence number \($0) is here." }.joined(separator: " ") + " "
        var starts: [String] = []
        for word in "And now we keep typing the same thought for a while. Then one more short sentence follows it".split(separator: " ") {
            text += word + " "
            let read = LanguageModelContext.make(textBefore: text, reach: reach)?.key.text ?? ""
            starts.append(String(read.prefix(24)))
        }

        // #then the start moved at most once: the model re-reads once per step, not once per word
        let moves = zip(starts, starts.dropFirst()).filter { $0 != $1 }.count
        XCTAssertLessThanOrEqual(moves, 1, "\(starts)")
    }

    func test_context_oneVeryLongSentence_isCutAtAWordInStepsNotPerKey() {
        // #given a single unbroken sentence far over the reach, at two moments one word apart
        let reach = LanguageModelContext.Reach(maximumCharacters: 400, step: 200)
        let long = (0..<250).map { "word\($0 % 7)a" }.joined(separator: " ")
        let first = LanguageModelContext.make(textBefore: long + " ", reach: reach)?.key.text ?? ""
        let second = LanguageModelContext.make(textBefore: long + " more ", reach: reach)?.key.text ?? ""

        // #then it is cut to size at the start of a word, and the cut does not move for one more word
        XCTAssertLessThanOrEqual(first.utf8.count, reach.maximumCharacters)
        XCTAssertTrue(first.hasPrefix("word"), first)
        XCTAssertTrue(second.hasPrefix(first), "the start moved by one word")
    }

    func test_context_cutInsideAnAccentedLetter_stillGivesWholeText() {
        // #given text of two-byte letters, so a cut counted in bytes can land inside one
        let reach = LanguageModelContext.Reach(maximumCharacters: 101, step: 51)
        let text = String(repeating: "\u{E9}t\u{E9} ", count: 80)

        // #when the text is split
        let read = LanguageModelContext.make(textBefore: text, reach: reach)?.key.text ?? ""

        // #then the result is made of whole words of the text
        XCTAssertFalse(read.isEmpty)
        XCTAssertTrue(read.split(separator: " ").allSatisfy { $0 == "\u{E9}t\u{E9}" }, read)
    }

    // MARK: - Lexicon

    /// The made-up model's pieces. Most words are one piece; `shins` and `shiny` are ` shin` plus
    /// an ending, and `contributing` / `contribution` share their first piece and differ after it.
    private static let pieces: [String: [Int32]] = [
        " walk": [1], " walked": [2], " walking": [3], " walks": [4], " went": [5], " the": [6], " The": [7],
        " contributing": [8, 20], " contribution": [8, 21], " con": [9], " contrary": [9, 22],
        "walk": [10], "Walk": [11],
        " shin": [12], " shins": [12, 13], " shiny": [12, 14], " shine": [15]
    ]

    private func makeLexicon() -> LanguageModelLexicon {
        LanguageModelLexicon(
            entries: [
                ("walk", 400), ("walked", 300), ("walking", 200), ("walks", 100), ("went", 500), ("the", 9000),
                ("contributing", 30), ("contribution", 90), ("con", 10), ("contrary", 40),
                ("shin", 50), ("shins", 20), ("shiny", 130), ("shine", 300)
            ],
            pieces: { Self.pieces[$0] ?? [] }
        )
    }

    /// Scores where every piece is equally unlikely except those given (as probabilities).
    private func scores(_ lexicon: LanguageModelLexicon, _ probabilities: [Int: Float], isSpaced: Bool = true) -> LanguageModelScores {
        var raw = [Float](repeating: log(1e-9), count: 32)
        for (piece, probability) in probabilities { raw[piece] = log(probability) }
        let result = raw.withUnsafeBufferPointer {
            lexicon.probabilities(scores: $0, normalizer: 0, isSpaced: isSpaced)
        }
        return LanguageModelScores(key: .init(text: "Yesterday I", isSpaced: isSpaced), lexicon: lexicon, probabilities: result)
    }

    /// `answer` after one more pass with `piece` added: the given next pieces' probabilities, and
    /// how likely the word is to end at `piece`.
    private func refine(
        _ answer: LanguageModelScores, piece: Int32, next: [Int: Float], endProbability: Float
    ) -> LanguageModelScores {
        var raw = [Float](repeating: log(1e-9), count: 32)
        for (id, probability) in next { raw[id] = log(probability) }
        let refined = raw.withUnsafeBufferPointer {
            answer.lexicon.refined(
                answer.probabilities, piece: piece, isSpaced: answer.key.isSpaced,
                after: .init(scores: $0, normalizer: 0, logEnd: log(endProbability))
            )
        }
        return LanguageModelScores(
            key: answer.key, lexicon: answer.lexicon, probabilities: refined,
            refinedPieces: answer.refinedPieces.union([piece])
        )
    }

    func test_lexicon_rangeOfPrefix_isExactlyTheWordsStartingWithIt() {
        let lexicon = makeLexicon()

        XCTAssertEqual(lexicon.range(ofPrefix: "walk").map { lexicon.words[$0] }, ["walk", "walked", "walking", "walks"])
        XCTAssertEqual(lexicon.range(ofPrefix: "walke").map { lexicon.words[$0] }, ["walked"])
        XCTAssertEqual(lexicon.range(ofPrefix: "con").map { lexicon.words[$0] }, ["con", "contrary", "contributing", "contribution"])
        XCTAssertTrue(lexicon.range(ofPrefix: "zebra").isEmpty)
        XCTAssertEqual(lexicon.range(ofPrefix: "").count, lexicon.words.count)
    }

    func test_onePieceWord_getsThePiecesProbability() {
        // #given a model that gives `walked` 60% and `walking` 5%
        let lexicon = makeLexicon()
        let answer = scores(lexicon, [2: 0.6, 3: 0.05])

        // #then each word reads its own piece
        XCTAssertEqual(exp(answer.logProbability(of: "walked") ?? 0), 0.6, accuracy: 0.001)
        XCTAssertEqual(exp(answer.logProbability(of: "walking") ?? 0), 0.05, accuracy: 0.001)
    }

    func test_wordsSharingAFirstPiece_shareItsProbabilityByHowCommonTheyAre() {
        // #given 40% on the piece that starts both `contributing` (30 uses) and `contribution` (90)
        let lexicon = makeLexicon()
        let answer = scores(lexicon, [8: 0.4])

        // #then they split it 1 to 3
        XCTAssertEqual(exp(answer.logProbability(of: "contributing") ?? 0), 0.1, accuracy: 0.001)
        XCTAssertEqual(exp(answer.logProbability(of: "contribution") ?? 0), 0.3, accuracy: 0.001)
    }

    func test_capitalizedSpelling_isAddedToTheLowercaseOne() {
        // #given a sentence start, where the model expects `The` far more than `the`
        let lexicon = makeLexicon()
        let answer = scores(lexicon, [6: 0.01, 7: 0.3])

        // #then `the` is scored as either spelling
        XCTAssertEqual(exp(answer.logProbability(of: "the") ?? 0), 0.31, accuracy: 0.001)
    }

    func test_notSpaced_readsThePiecesWithoutALeadingSpace() {
        // #given the start of a line, where words are written without the space in front
        let lexicon = makeLexicon()
        let answer = scores(lexicon, [10: 0.2, 11: 0.1, 1: 0.9], isSpaced: false)

        // #then `walk` is read from the unspaced pieces, not from ` walk`
        XCTAssertEqual(exp(answer.logProbability(of: "walk") ?? 0), 0.3, accuracy: 0.001)
    }

    func test_wordTheModelCannotSpell_hasNoProbability() {
        let lexicon = makeLexicon()
        let answer = scores(lexicon, [1: 0.5], isSpaced: false)

        XCTAssertEqual(answer.logProbability(of: "went"), -.infinity)
        XCTAssertNil(answer.logProbability(of: "lindqvist"))
    }

    // MARK: - Best words

    func test_best_ordersByProbabilityWithinThePrefix() {
        // #given a past-tense context: `walked` likeliest, then `walking`, `walks`, `walk`
        let lexicon = makeLexicon()
        let answer = scores(lexicon, [1: 0.01, 2: 0.6, 3: 0.05, 4: 0.02, 5: 0.2])

        // #then the letters `walk` list the forms in that order, and `went` is not among them
        XCTAssertEqual(answer.best(prefix: "walk", limit: 3).map(\.word), ["walked", "walking", "walks"])
        // #and with no letters the overall order is used
        XCTAssertEqual(answer.best(prefix: "", limit: 2).map(\.word), ["walked", "went"])
    }

    // MARK: - The exact pass

    func test_wordsSharingAPiece_areFirstOrderedByCommonness() {
        // #given 40% on the piece ` shin`, which starts shin (50 uses), shins (20), and shiny (130)
        let answer = scores(makeLexicon(), [12: 0.4])

        // #then before the exact pass the commonest of them is first
        XCTAssertEqual(answer.best(prefix: "shin", limit: 3).map(\.word), ["shiny", "shin", "shins"])
    }

    func test_exactPass_ordersThemByWhatTheModelExpectsNext() {
        // #given the same answer, in a text where the model expects `s` after ` shin` ("my shins")
        let answer = scores(makeLexicon(), [12: 0.4])

        // #when the piece is refined: `s` 70%, `y` 10%, the word ending there 15%
        let refined = refine(answer, piece: 12, next: [13: 0.7, 14: 0.1], endProbability: 0.15)

        // #then `shins` is first, with the model's own numbers
        XCTAssertEqual(refined.best(prefix: "shin", limit: 3).map(\.word), ["shins", "shin", "shiny"])
        XCTAssertEqual(exp(refined.logProbability(of: "shins") ?? 0), 0.28, accuracy: 0.001)
        XCTAssertEqual(exp(refined.logProbability(of: "shin") ?? 0), 0.06, accuracy: 0.001)
        XCTAssertEqual(exp(refined.logProbability(of: "shiny") ?? 0), 0.04, accuracy: 0.001)
    }

    func test_exactPass_leavesOtherWordsAlone() {
        let answer = scores(makeLexicon(), [12: 0.4, 15: 0.2])

        let refined = refine(answer, piece: 12, next: [13: 0.7], endProbability: 0.15)

        XCTAssertEqual(refined.logProbability(of: "shine"), answer.logProbability(of: "shine"))
    }

    func test_piecesWorthRefining_areThoseTheTypedLettersLeaveUndecided() {
        // #given a likely piece shared by three words, and letters that single those words out
        let answer = scores(makeLexicon(), [12: 0.4, 15: 0.2, 2: 0.3])

        // #then that piece is worth a pass once the letters are typed, and not before
        XCTAssertEqual(answer.piecesWorthRefining(prefix: "shin"), [12])
        XCTAssertEqual(answer.piecesWorthRefining(prefix: ""), [])
        // #and one-piece words that share nothing are left as they are
        XCTAssertEqual(answer.piecesWorthRefining(prefix: "walke"), [])
    }

    func test_piecesWorthRefining_areNotAskedForTwice() {
        let answer = scores(makeLexicon(), [12: 0.4])

        let refined = refine(answer, piece: 12, next: [13: 0.7], endProbability: 0.15)

        XCTAssertEqual(refined.piecesWorthRefining(prefix: "shin"), [])
    }
}
