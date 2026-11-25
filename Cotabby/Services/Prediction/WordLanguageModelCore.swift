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
    /// Whether the model can take pieces back out of its memory, which the exact pass and the
    /// look-ahead need (they read a piece or a word and then put the memory back). Some models keep
    /// a running state that cannot be wound back (Qwen 3.5). Asked once when the model loads, with
    /// two throwaway pieces, so the answer does not cost a real text its place in the memory; set
    /// false later too if the model ever refuses.
    private(set) var canRollBack: Bool
    /// Whether the model reads several next pieces in one pass, each on a branch of the text
    /// (`LlamaTokenModel.scoresAfterEach`). Asked once at load, like `canRollBack`.
    let canBranch: Bool

    /// Nil when the model file cannot be loaded or no word list can be read.
    ///
    /// - Parameter wordListURLs: files of one "word count" pair per line. The first is the file the
    ///   spelling dictionary is built from; `prediction_words_en.txt` follows it with the everyday
    ///   words that dictionary lacks (`neighbor`, `favorite`, `you've`, `dataset`), because the
    ///   model can only put a word first that is in its list. A word listed twice takes the larger
    ///   count: the dictionary carries every contraction at one placeholder count (`that's` and
    ///   `don't` at 300,000), and the second file lists them again with their real ones.
    /// - Parameter readsPiecesInOnePass: false makes the exact pass read its pieces one at a time,
    ///   as a model that cannot branch does; the harness and the tests use it to compare the two.
    init?(modelURL: URL, wordListURLs: [URL], readsPiecesInOnePass: Bool = true) {
        guard let model = LlamaTokenModel(url: modelURL) else { return nil }
        let entries = Self.entries(in: wordListURLs)
        guard !entries.isEmpty else { return nil }
        self.model = model
        let start = model.startToken
        let couldRead = model.appendForNextPieceScores([start, start]) { _, _ in true } ?? false
        canRollBack = couldRead && model.rollBack(last: 1)
        canBranch = couldRead && readsPiecesInOnePass && model.scoresAfterEach(of: [start, start]) { _, _, _ in }
        model.reset()
        lexicon = LanguageModelLexicon(entries: entries) { model.tokens(for: $0, parsingSpecial: false) }
        endsWord = (0..<model.vocabularyCount).map { piece in
            guard let first = model.bytes(for: Int32(piece)).first else { return 1 }
            let isLetter = (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A)
            // A byte of 0x80 or more starts a non-ASCII letter far more often than anything else.
            return isLetter || first == 0x27 || first >= 0x80 ? 0 : 1
        }
        scratch = [Float](repeating: 0, count: model.vocabularyCount)
    }

    /// The words of every list that can be read, each once, in the order first seen, with the
    /// largest count any list gives it.
    static func entries(in wordListURLs: [URL]) -> [(word: String, count: Double)] {
        var entries: [(word: String, count: Double)] = []
        var position: [String: Int] = [:]
        for url in wordListURLs {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in contents.split(separator: "\n") {
                let fields = line.split(separator: " ")
                guard fields.count >= 2, let count = Double(fields[1]) else { continue }
                let word = String(fields[0])
                if let index = position[word] {
                    entries[index].count = max(entries[index].count, count)
                } else {
                    position[word] = entries.count
                    entries.append((word, count))
                }
            }
        }
        return entries
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
            answer(for: key, scores: scores, normalizer: normalizer)
        }
        guard let result else {
            forgetEverything()
            return nil
        }
        memory = pieces
        memoryKey = key
        return result
    }

    /// One pass's scores turned into an answer: every dictionary word, and the writer's own words
    /// found in the text.
    private func answer(
        for key: LanguageModelContext.Key, scores: UnsafeBufferPointer<Float>, normalizer: Float
    ) -> LanguageModelScores {
        LanguageModelScores(
            key: key,
            lexicon: lexicon,
            probabilities: lexicon.probabilities(scores: scores, normalizer: normalizer, isSpaced: key.isSpaced),
            textWords: textWords(for: key, scores: scores, normalizer: normalizer)
        )
    }

    /// The writer's own words in the text (`TextVocabulary`) with the model's estimate for each.
    ///
    /// The estimate is the probability of the word's first piece, halved when the word has more
    /// pieces: the model has read this word in this very text and will most likely finish it the
    /// same way, and `refine` replaces the guess with the model's own number once the typed letters
    /// make the word a candidate. A word written in lowercase is also read capitalized, as it would
    /// stand at a sentence start.
    private func textWords(
        for key: LanguageModelContext.Key, scores: UnsafeBufferPointer<Float>, normalizer: Float
    ) -> [LanguageModelScores.TextWord] {
        let lead = key.isSpaced ? " " : ""
        func estimate(_ pieces: [Int32]) -> (first: Float, word: Float) {
            guard let first = pieces.first, Int(first) < scores.count else { return (-.infinity, -.infinity) }
            let logProbability = scores[Int(first)] - normalizer
            return (logProbability, logProbability + (pieces.count > 1 ? Self.unreadPiecesLogProbability : 0))
        }
        return TextVocabulary.read(key.text) { lexicon.index(of: $0) != nil }.map { word in
            guard word.isNew else { return .init(display: word.display, lowercased: word.lowercased) }
            let pieces = model.tokens(for: lead + word.display, parsingSpecial: false)
            let written = estimate(pieces)
            var logProbability = written.word
            let capitalized = LanguageModelLexicon.capitalized(word.display)
            if capitalized != word.display {
                let other = estimate(model.tokens(for: lead + capitalized, parsingSpecial: false)).word
                let high = max(logProbability, other)
                if high > -.infinity { logProbability = high + log1p(exp(min(logProbability, other) - high)) }
            }
            return .init(
                display: word.display, lowercased: word.lowercased, logProbability: logProbability,
                pieces: pieces, firstPieceLogProbability: written.first
            )
        }
    }

    /// log of what the pieces after the first are taken to be worth before an exact pass.
    private static let unreadPiecesLogProbability = Float(log(0.5))

    /// The answer for a text the writer has not reached yet: the current text plus the word they
    /// are about to finish. Worked out while they type that word's last letters, so the next
    /// word's list is there the moment the space is pressed instead of one pass later.
    ///
    /// The model's memory is left exactly as it was (the extra pieces are read and taken out
    /// again), because the refinements for the word still being typed need it where it is. Nil
    /// when `key` does not continue the text in memory, or the model cannot take pieces back out.
    func lookAhead(to key: LanguageModelContext.Key) -> LanguageModelScores? {
        guard canRollBack, memoryKey != nil, memoryKey != key else { return nil }
        let pieces = [model.startToken] + model.tokens(for: key.text, parsingSpecial: false)
        guard pieces.count > memory.count, pieces.count < Int(LlamaTokenModel.contextSize) - 8,
              pieces.starts(with: memory) else { return nil }
        let added = Array(pieces[memory.count...])
        let result = model.appendForNextPieceScores(added) { scores, normalizer in
            answer(for: key, scores: scores, normalizer: normalizer)
        }
        guard let result else {
            forgetEverything()
            return nil
        }
        guard model.rollBack(last: added.count) else {
            canRollBack = false
            memory = []
            memoryKey = nil
            return nil
        }
        return result
    }

    /// `scores` with the model's exact numbers for the words that matter now that `prefix` has
    /// been typed (see `LanguageModelLexicon`), or nil when there is nothing to gain or the model
    /// has moved on to another text.
    ///
    /// All the pieces are read in one pass (`LlamaTokenModel.scoresAfterEach`), which costs about
    /// what one of them used to. A model that cannot branch reads them one at a time instead: each
    /// is added to the text, read, and taken out of the memory again.
    func refine(_ scores: LanguageModelScores, forPrefix prefix: String) -> LanguageModelScores? {
        guard canBranch || canRollBack, memoryKey == scores.key else { return nil }
        let pieces = scores.piecesWorthRefining(prefix: prefix, limit: canBranch ? LlamaTokenModel.branchCapacity : 3)
        guard !pieces.isEmpty else { return nil }
        var probabilities = scores.probabilities
        var refined = scores.refinedPieces
        var textWords = scores.textWords
        func take(_ piece: Int32, _ continuation: UnsafeBufferPointer<Float>, _ normalizer: Float) {
            let logEnd = logEndProbability(continuation, normalizer: normalizer)
            // The writer's own words starting with this piece get the model's number too.
            for index in textWords.indices where textWords[index].pieces.first == piece && textWords[index].logProbability != nil {
                let word = textWords[index]
                if word.pieces.count == 1 {
                    textWords[index].logProbability = word.firstPieceLogProbability + logEnd
                } else if Int(word.pieces[1]) < continuation.count {
                    textWords[index].logProbability = word.firstPieceLogProbability
                        + continuation[Int(word.pieces[1])] - normalizer
                        + (word.pieces.count > 2 ? Self.unreadPiecesLogProbability : 0)
                }
            }
            probabilities = lexicon.refined(
                probabilities, piece: piece, isSpaced: scores.key.isSpaced,
                after: .init(scores: continuation, normalizer: normalizer, logEnd: logEnd)
            )
            refined.insert(piece)
        }
        if canBranch {
            guard model.scoresAfterEach(of: pieces, { take(pieces[$0], $1, $2) }) else {
                forgetEverything()
                return nil
            }
        } else {
            for piece in pieces {
                guard model.appendForNextPieceScores([piece], { take(piece, $0, $1) }) != nil else {
                    forgetEverything()
                    return nil
                }
                // The piece has to come out again. A model that cannot do that has lost its memory
                // of the text (the next answer re-reads it) and is not asked again.
                guard model.rollBack(last: 1) else {
                    canRollBack = false
                    memory = []
                    memoryKey = nil
                    break
                }
            }
        }
        return LanguageModelScores(
            key: scores.key, lexicon: lexicon, probabilities: probabilities, refinedPieces: refined, textWords: textWords
        )
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
