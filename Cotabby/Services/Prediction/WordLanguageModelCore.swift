import Foundation

/// File overview:
/// The working half of the word language model: the llama.cpp model, the lexicon built from it, and
/// the one operation "how likely is each dictionary word after this text". Synchronous and not
/// thread-safe; `WordLanguageModelService` keeps it on a queue for the app, and the command-line
/// harness (`cotabby-spell --typing ... --lm`) calls it directly, which is why it is its own file
/// with no dependency on the app's services.
///
/// The model's memory of the text is kept between calls. Typing a word adds a piece or two to what
/// it has already read, so each call costs one short pass, not a re-read.

nonisolated final class WordLanguageModelCore {
    let lexicon: LanguageModelLexicon
    private let model: LlamaTokenModel
    /// The pieces in the model's memory, to find how much of a new text it has already read.
    private var memory: [Int32] = []
    /// The context those pieces are, when the memory holds exactly one; `refine` needs it there.
    private var memoryKey: LanguageModelContext.Key?
    /// 1 for every piece that cannot continue a word (it starts with a space, punctuation, a line
    /// break, or is a control piece), 0 for the rest. The probability that a word ends is the
    /// summed probability of these.
    private let endsWord: [Float]
    private var scratch: [Float]
    /// False once the model has refused to take a piece back out of its memory; see `refine`.
    private var canRollBack = true

    /// Nil when the model file cannot be loaded or the dictionary cannot be read.
    init?(modelURL: URL, dictionaryURL: URL) {
        guard let model = LlamaTokenModel(url: modelURL),
              let dictionary = try? String(contentsOf: dictionaryURL, encoding: .utf8) else { return nil }
        self.model = model
        // One "word count" pair per line, the same file the spelling dictionary is built from.
        let entries = dictionary.split(separator: "\n").compactMap { line -> (word: String, count: Double)? in
            let fields = line.split(separator: " ")
            guard fields.count >= 2, let count = Double(fields[1]) else { return nil }
            return (String(fields[0]), count)
        }
        lexicon = LanguageModelLexicon(entries: entries) { model.tokens(for: $0, parsingSpecial: false) }
        endsWord = (0..<model.vocabularyCount).map { piece in
            guard let first = model.bytes(for: Int32(piece)).first else { return 1 }
            let isLetter = (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A)
            // A byte of 0x80 or more starts a non-ASCII letter far more often than anything else.
            return isLetter || first == 0x27 || first >= 0x80 ? 0 : 1
        }
        scratch = [Float](repeating: 0, count: model.vocabularyCount)
    }

    /// How likely each dictionary word is to follow `key.text`, or nil when the model could not run.
    func scores(for key: LanguageModelContext.Key) -> LanguageModelScores? {
        // Every text opens with the model's start piece, so an empty text still has something to
        // predict from.
        var pieces = [model.startToken] + model.tokens(for: key.text, parsingSpecial: false)
        // A text longer than the memory keeps its end; the start piece stays first.
        let limit = Int(LlamaTokenModel.contextSize) - 8
        if pieces.count > limit {
            pieces = [pieces[0]] + pieces.suffix(limit - 1)
        }
        var shared = 0
        while shared < min(memory.count, pieces.count), memory[shared] == pieces[shared] { shared += 1 }
        // The last piece is always run again: its prediction is the answer, and llama.cpp only
        // keeps the prediction of the most recent pass.
        var kept = min(shared, pieces.count - 1)
        // A model that cannot wind its memory back has emptied it instead; read the text afresh.
        if !model.rollBack(last: memory.count - kept) { kept = 0 }
        let result = model.appendForNextPieceScores(Array(pieces[kept...])) { scores, normalizer in
            lexicon.probabilities(scores: scores, normalizer: normalizer, isSpaced: key.isSpaced)
        }
        guard let result else {
            forgetEverything()
            return nil
        }
        memory = pieces
        memoryKey = key
        return LanguageModelScores(key: key, lexicon: lexicon, probabilities: result)
    }

    /// `scores` with the model's exact numbers for the words that matter now that `prefix` has
    /// been typed (see `LanguageModelLexicon`), or nil when there is nothing to gain or the model
    /// has moved on to another text. Each piece refined costs one pass over a single piece: the
    /// piece is added to the text, read, and taken out of the memory again.
    func refine(_ scores: LanguageModelScores, forPrefix prefix: String) -> LanguageModelScores? {
        guard canRollBack, memoryKey == scores.key else { return nil }
        let pieces = scores.piecesWorthRefining(prefix: prefix)
        guard !pieces.isEmpty else { return nil }
        var probabilities = scores.probabilities
        var refined = scores.refinedPieces
        for piece in pieces {
            let next = model.appendForNextPieceScores([piece]) { continuation, normalizer in
                lexicon.refined(
                    probabilities, piece: piece, isSpaced: scores.key.isSpaced,
                    after: .init(
                        scores: continuation, normalizer: normalizer,
                        logEnd: logEndProbability(continuation, normalizer: normalizer)
                    )
                )
            }
            guard let next else {
                forgetEverything()
                return nil
            }
            probabilities = next
            refined.insert(piece)
            // The exact pass needs the added piece taken out again. A model that cannot do that has
            // lost its memory of the text (the next answer re-reads it) and is not asked again.
            guard model.rollBack(last: 1) else {
                canRollBack = false
                memory = []
                memoryKey = nil
                break
            }
        }
        return LanguageModelScores(key: scores.key, lexicon: lexicon, probabilities: probabilities, refinedPieces: refined)
    }

    /// log of the summed probability of the pieces that end a word.
    private func logEndProbability(_ scores: UnsafeBufferPointer<Float>, normalizer: Float) -> Float {
        var total: Float = 0
        for piece in 0..<min(scores.count, endsWord.count) where endsWord[piece] > 0 {
            scratch[piece] = scores[piece] - normalizer
            // Pieces far below one in a million cannot move the sum; skipping them skips most of
            // the 150,000 exponentials.
            if scratch[piece] > -16 { total += exp(scratch[piece]) }
        }
        return log(max(total, 1e-9))
    }

    private func forgetEverything() {
        model.reset()
        memory = []
        memoryKey = nil
    }
}
