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
    /// model reads a few sentences back, so both stay far below this.
    static let contextSize: Int32 = 1_024
    private static let batchCapacity: Int32 = 512
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
        guard !tokens.isEmpty, tokens.count <= Int(Self.batchCapacity),
              count + Int32(tokens.count) <= Self.contextSize else { return nil }
        batch.n_tokens = Int32(tokens.count)
        for (index, token) in tokens.enumerated() {
            batch.token[index] = token
            batch.pos[index] = count + Int32(index)
            batch.n_seq_id[index] = 1
            batch.seq_id[index]?[0] = 0
            batch.logits[index] = index == tokens.count - 1 ? 1 : 0
        }
        guard llama_decode(context, batch) == 0 else { return nil }
        count += Int32(tokens.count)
        guard let scores = llama_get_logits_ith(context, Int32(tokens.count - 1)) else { return nil }
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
        return body(UnsafeBufferPointer(start: scores, count: vocabularySize), best + log(max(sum, 1)))
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
