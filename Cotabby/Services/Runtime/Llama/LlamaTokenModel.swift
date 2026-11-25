import Accelerate
import Foundation
import llama

/// File overview:
/// A llama.cpp model with one context of its own, driven piece by piece. Two features use it: the
/// sentence model (`SentenceModelService`, which asks for the model's first choice at every position
/// of a pass) and the word language model (`WordLanguageModelService`, which asks how likely every
/// piece is to come next).
///
/// Why it is not the ghost-text engine's wrapper (`CotabbyInference` behind `LlamaRuntimeCore`):
/// that wrapper exposes generation, not the model's scores, and neither feature generates. Both
/// need the raw prediction at chosen positions and the ability to roll the memory back, so this
/// class talks to llama.cpp directly, through the same llama framework the app already ships.
///
/// Not thread-safe: a llama.cpp context must be used from one thread at a time, so each owner keeps
/// its instance on a serial queue.

/// A llama.cpp model with one context, driven as a "pieces in, first choices out" machine.
///
/// `OpaquePointer` is how Swift imports a C pointer to a struct it cannot see inside; llama.cpp
/// hands these out for the model, its vocabulary, and the context (the model's working memory), and
/// the matching `free` calls in `deinit` give them back.
nonisolated final class LlamaTokenModel: SentenceTokenModel {
    /// Pieces the memory holds. A finished sentence is at most 320 characters and the word language
    /// model reads about 1,600 characters back (some 400 pieces of English, more for text that
    /// splits badly), so both stay below this.
    static let contextSize: Int32 = 2_048
    private static let batchCapacity: Int32 = 512
    /// How many different next pieces one pass can try after the text in memory (`scoresAfterEach`).
    static let branchCapacity = 8
    /// llama.cpp asks for one process-wide setup call; a `static let` runs exactly once. The log
    /// callback is silenced the same way the ghost-text engine does it, or every load would print
    /// hundreds of lines to stderr.
    private static let backend: Void = {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocabulary: OpaquePointer
    private let vocabularySize: Int
    private var batch: llama_batch
    /// Pieces currently in the context's memory; also the position of the next piece.
    private var count: Int32 = 0
    private var pieceCache: [Int32: [UInt8]] = [:]
    private var scratch: [Float]

    init?(url: URL) {
        _ = Self.backend
        var modelParameters = llama_model_default_params()
        // Negative means every layer on the GPU, which is where a pass over a whole sentence is fast.
        modelParameters.n_gpu_layers = -1
        guard let model = llama_model_load_from_file(url.path, modelParameters) else { return nil }
        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = UInt32(Self.contextSize)
        contextParameters.n_batch = UInt32(Self.batchCapacity)
        contextParameters.n_ubatch = UInt32(Self.batchCapacity)
        contextParameters.no_perf = true
        // Sequence 0 is the text. The others are branches: each shares the text and adds one piece
        // of its own, so one pass answers "what follows the text plus this piece" for several
        // pieces at once. One shared buffer (`kv_unified`) means a branch points at the text's
        // entries instead of copying them, and the text keeps the whole context size.
        contextParameters.n_seq_max = UInt32(1 + Self.branchCapacity)
        contextParameters.kv_unified = true
        guard let context = llama_init_from_model(model, contextParameters) else {
            llama_model_free(model)
            return nil
        }
        self.model = model
        self.context = context
        vocabulary = llama_model_get_vocab(model)
        vocabularySize = Int(llama_vocab_n_tokens(vocabulary))
        batch = llama_batch_init(Self.batchCapacity, 0, 1)
        scratch = [Float](repeating: 0, count: vocabularySize)
    }

    deinit {
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    func tokens(for text: String, parsingSpecial: Bool) -> [Int32] {
        let byteCount = Int32(text.utf8.count)
        // A piece covers at least one byte, so the byte count bounds the piece count.
        var buffer = [llama_token](repeating: 0, count: Int(byteCount) + 8)
        let produced = llama_tokenize(vocabulary, text, byteCount, &buffer, Int32(buffer.count), false, parsingSpecial)
        return produced > 0 ? Array(buffer.prefix(Int(produced))) : []
    }

    func bytes(for token: Int32) -> [UInt8] {
        if let cached = pieceCache[token] { return cached }
        var buffer = [CChar](repeating: 0, count: 64)
        var length = llama_token_to_piece(vocabulary, token, &buffer, Int32(buffer.count), 0, false)
        if length < 0 {
            // A negative answer is the size the piece needs.
            buffer = [CChar](repeating: 0, count: Int(-length))
            length = llama_token_to_piece(vocabulary, token, &buffer, Int32(buffer.count), 0, false)
        }
        let bytes = buffer.prefix(Int(max(length, 0))).map { UInt8(bitPattern: $0) }
        pieceCache[token] = bytes
        return bytes
    }

    /// How many pieces are in the memory.
    var pieceCount: Int { Int(count) }

    /// How many different pieces the model knows; their ids are 0 up to this.
    var vocabularyCount: Int { vocabularySize }

    /// The piece that opens a text for this model, for when there is nothing else to put first.
    /// Models without one (Qwen) use their end-of-text piece the same way.
    var startToken: Int32 {
        let start = llama_vocab_bos(vocabulary)
        return start >= 0 ? start : llama_vocab_eos(vocabulary)
    }

    func isEnd(_ token: Int32) -> Bool {
        llama_vocab_is_eog(vocabulary, token)
    }

    func append(_ tokens: [Int32], predictionsFrom first: Int) -> [SentenceModelPrediction]? {
        guard !tokens.isEmpty, tokens.count <= Int(Self.batchCapacity),
              count + Int32(tokens.count) <= Self.contextSize else { return nil }
        batch.n_tokens = Int32(tokens.count)
        for (index, token) in tokens.enumerated() {
            batch.token[index] = token
            batch.pos[index] = count + Int32(index)
            batch.n_seq_id[index] = 1
            batch.seq_id[index]?[0] = 0
            // llama.cpp calls this flag "logits": whether to compute the prediction after this piece.
            batch.logits[index] = index >= first ? 1 : 0
        }
        guard llama_decode(context, batch) == 0 else { return nil }
        count += Int32(tokens.count)
        var predictions: [SentenceModelPrediction] = []
        predictions.reserveCapacity(tokens.count - first)
        for index in first..<tokens.count {
            guard let prediction = prediction(atBatchIndex: Int32(index)) else { return nil }
            predictions.append(prediction)
        }
        return predictions
    }

    /// Adds pieces to the memory and hands `body` the model's raw score for every vocabulary piece
    /// coming next, with the value that turns a score into a log-probability
    /// (`log P(piece) = score - normalizer`). The scores belong to llama.cpp and are only valid
    /// inside `body`. Nil when the model could not run.
    ///
    /// Scores instead of a finished array of log-probabilities because the caller reads a few
    /// thousand of the 150,000 entries; subtracting one number per read is cheaper than a pass over
    /// all of them.
    func appendForNextPieceScores<Result>(
        _ tokens: [Int32],
        _ body: (_ scores: UnsafeBufferPointer<Float>, _ normalizer: Float) -> Result
    ) -> Result? {
        guard !tokens.isEmpty, count + Int32(tokens.count) <= Self.contextSize else { return nil }
        // A long text (the word language model re-reading up to a few hundred words) goes in as
        // several batches; only the very last piece's prediction is wanted. If a batch fails the
        // memory holds part of the text, and the caller resets it.
        var start = 0
        var lastBatchCount = 0
        while start < tokens.count {
            let end = min(start + Int(Self.batchCapacity), tokens.count)
            lastBatchCount = end - start
            batch.n_tokens = Int32(lastBatchCount)
            for offset in 0..<lastBatchCount {
                batch.token[offset] = tokens[start + offset]
                batch.pos[offset] = count + Int32(offset)
                batch.n_seq_id[offset] = 1
                batch.seq_id[offset]?[0] = 0
                batch.logits[offset] = start + offset == tokens.count - 1 ? 1 : 0
            }
            guard llama_decode(context, batch) == 0 else { return nil }
            count += Int32(lastBatchCount)
            start = end
        }
        guard let scores = llama_get_logits_ith(context, Int32(lastBatchCount - 1)) else { return nil }
        return body(UnsafeBufferPointer(start: scores, count: vocabularySize), normalizer(of: scores))
    }

    /// For each of `pieces`: the model's scores for what comes after the text in memory with that
    /// one piece added, handed to `body` in order with the piece's place in `pieces`. The memory
    /// is left exactly as it was. False when the model could not run; the memory is then still the
    /// text, with no branch left behind.
    ///
    /// Why one pass instead of one per piece: a pass over a single piece costs the same ten
    /// milliseconds on the GPU whether it carries one piece or eight, because nearly all of that
    /// is the fixed cost of running the layers at all. Each piece goes in at the same position on
    /// a sequence of its own that shares the text (`llama_memory_seq_cp` marks the text's entries
    /// as belonging to that sequence too; nothing is copied), and the sequences are dropped again
    /// afterwards. Nothing is appended to the text itself, so there is nothing to roll back.
    func scoresAfterEach(
        of pieces: [Int32],
        _ body: (_ index: Int, _ scores: UnsafeBufferPointer<Float>, _ normalizer: Float) -> Void
    ) -> Bool {
        guard !pieces.isEmpty, pieces.count <= Self.branchCapacity, (1..<Self.contextSize).contains(count) else { return false }
        let memory = llama_get_memory(context)
        for branch in 1...pieces.count { llama_memory_seq_cp(memory, 0, Int32(branch), -1, -1) }
        // Negative bounds mean the whole sequence, which llama.cpp can always remove.
        defer { for branch in 1...pieces.count { _ = llama_memory_seq_rm(memory, Int32(branch), -1, -1) } }
        batch.n_tokens = Int32(pieces.count)
        for (index, piece) in pieces.enumerated() {
            batch.token[index] = piece
            batch.pos[index] = count
            batch.n_seq_id[index] = 1
            batch.seq_id[index]?[0] = Int32(index + 1)
            batch.logits[index] = 1
        }
        guard llama_decode(context, batch) == 0 else { return false }
        for index in pieces.indices {
            guard let scores = llama_get_logits_ith(context, Int32(index)) else { return false }
            body(index, UnsafeBufferPointer(start: scores, count: vocabularySize), normalizer(of: scores))
        }
        return true
    }

    /// The number that turns a raw score into a log-probability: log Σ exp(score), worked out
    /// relative to the best score so the exponentials stay in range. Accelerate does the sweeps
    /// with vector instructions; a Swift loop over 150,000 scores would cost more than the pass.
    private func normalizer(of scores: UnsafePointer<Float>) -> Float {
        var best: Float = 0
        var bestIndex: vDSP_Length = 0
        vDSP_maxvi(scores, 1, &best, &bestIndex, vDSP_Length(vocabularySize))
        var shift = -best
        var size = Int32(vocabularySize)
        var sum: Float = 0
        scratch.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_vsadd(scores, 1, &shift, base, 1, vDSP_Length(vocabularySize))
            vvexpf(base, base, &size)
            vDSP_sve(base, 1, &sum, vDSP_Length(vocabularySize))
        }
        return best + log(max(sum, 1))
    }

    func forget(last removed: Int) {
        _ = rollBack(last: removed)
    }

    /// Drops the last `removed` pieces from the memory and says whether the model could do it.
    /// Some models keep a running state that cannot be wound back (llama.cpp then refuses); the
    /// memory is emptied instead, so it is never left holding pieces the caller believes are gone.
    func rollBack(last removed: Int) -> Bool {
        guard removed > 0 else { return true }
        let kept = max(count - Int32(removed), 0)
        // Removes positions [kept, end) of sequence 0; -1 means "to the end".
        guard llama_memory_seq_rm(llama_get_memory(context), 0, kept, -1) else {
            reset()
            return false
        }
        count = kept
        return true
    }

    func reset() {
        count = 0
        llama_memory_clear(llama_get_memory(context), true)
    }

    /// The most likely next piece and its log-probability, from the raw scores llama.cpp returns
    /// (one per vocabulary entry, about 150,000). log P(best) = best − log Σ exp(score), computed
    /// relative to the best score so the exponentials stay in range. Accelerate does both sweeps
    /// with vector instructions; a Swift loop here would cost more than the model pass.
    private func prediction(atBatchIndex index: Int32) -> SentenceModelPrediction? {
        guard let scores = llama_get_logits_ith(context, index) else { return nil }
        var best: Float = 0
        var bestIndex: vDSP_Length = 0
        vDSP_maxvi(scores, 1, &best, &bestIndex, vDSP_Length(vocabularySize))
        var shift = -best
        var size = Int32(vocabularySize)
        var sum: Float = 0
        scratch.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_vsadd(scores, 1, &shift, base, 1, vDSP_Length(vocabularySize))
            vvexpf(base, base, &size)
            vDSP_sve(base, 1, &sum, vDSP_Length(vocabularySize))
        }
        return SentenceModelPrediction(token: Int32(bestIndex), logProbability: -log(max(sum, 1)))
    }
}
