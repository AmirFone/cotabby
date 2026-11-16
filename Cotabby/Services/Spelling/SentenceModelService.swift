import Accelerate
import Foundation
import Logging
import llama

/// File overview:
/// Runs the sentence model (see `SentenceModelCorrection.swift`) on a finished sentence.
///
/// Two types, one boundary:
/// - `SentenceModelService` is what the app holds. It finds the model file, loads it once on its own
///   queue, and answers `correct(_:)` off the main thread. When the file is not installed the service
///   answers nil and the sentence pass simply has one stage fewer, so no caller handles "missing
///   model" as an error.
/// - `LlamaSentenceTokenModel` is the `SentenceTokenModel` the decoder drives: a llama.cpp model and
///   context of its own, separate from the ghost-text engine in `LlamaRuntimeCore`. It needs calls
///   the ghost-text wrapper (`CotabbyInference`) does not expose (the model's prediction at every
///   position of a pass, and rolling the memory back), so it talks to llama.cpp directly. Both use
///   the same llama framework the app already ships.
///
/// Owned by `CotabbyAppEnvironment` for the life of the app. The model (about 640 MB) stays loaded
/// once used; a sentence check must not wait on a load.
nonisolated final class SentenceModelService: @unchecked Sendable {
    static let modelFileName = "spelling-qwen3-0.6b-q8_0.gguf"

    /// Where the model file is: `Application Support/<app>/SentenceModel/<file>` (next to the
    /// ghost-text models' folder) when a file is there, otherwise the copy inside the app bundle.
    ///
    /// A downloaded release carries the file in its bundle so it works without a setup step
    /// (`Tools/release/package-dmg.sh` puts it there). The Application Support copy wins so a
    /// retrained model can be tried by dropping one file, with no rebuild or re-signing.
    /// `Tools/sentence-model/README.md` describes how the file is produced.
    @MainActor
    static func defaultModelURL(bundle: Bundle = .main) -> URL {
        let installed = BundledRuntimeLocator.userRuntimeDirectoryURL(bundle: bundle)
            .deletingLastPathComponent()
            .appendingPathComponent("SentenceModel", isDirectory: true)
            .appendingPathComponent(modelFileName)
        if !FileManager.default.fileExists(atPath: installed.path),
           let bundled = bundle.url(forResource: modelFileName, withExtension: nil) {
            return bundled
        }
        return installed
    }

    private let modelURL: URL
    /// llama.cpp contexts are not thread-safe; every use of `model` happens on this queue.
    private let queue = DispatchQueue(label: "com.cotabby.sentence-model", qos: .userInitiated)
    private var model: LlamaSentenceTokenModel?
    private var didTryLoading = false

    init(modelURL: URL) {
        self.modelURL = modelURL
    }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: modelURL.path) }

    /// Loads the model and runs it once ahead of the first sentence, so that sentence is not the one
    /// that pays for the load or for the GPU setting up on first use (the first run is several times
    /// slower than the ones after it).
    func warmUp() {
        queue.async {
            guard let model = self.loadedModel() else { return }
            _ = SentenceModelDecoder.correct("This is a sentance to warm up.", model: model)
        }
    }

    /// The model's corrected version of `sentence`, or nil when no model is installed or it failed.
    func correct(_ sentence: String) async -> SentenceModelOutput? {
        await withCheckedContinuation { continuation in
            queue.async {
                let output = self.loadedModel().flatMap { SentenceModelDecoder.correct(sentence, model: $0) }
                continuation.resume(returning: output)
            }
        }
    }

    private func loadedModel() -> LlamaSentenceTokenModel? {
        if !didTryLoading {
            didTryLoading = true
            guard isInstalled else { return nil }
            let started = DispatchTime.now().uptimeNanoseconds
            model = LlamaSentenceTokenModel(url: modelURL)
            let milliseconds = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            if model == nil {
                CotabbyLogger.runtime.error("Sentence model: could not load \(modelURL.lastPathComponent)")
            } else {
                let place = modelURL.path.contains(".app/Contents/") ? "the app bundle" : "Application Support"
                CotabbyLogger.runtime.info(
                    "Sentence model: loaded \(modelURL.lastPathComponent) from \(place) in \(milliseconds) ms"
                )
            }
        }
        return model
    }
}

/// A llama.cpp model with one context, driven as a "pieces in, first choices out" machine.
///
/// `OpaquePointer` is how Swift imports a C pointer to a struct it cannot see inside; llama.cpp
/// hands these out for the model, its vocabulary, and the context (the model's working memory), and
/// the matching `free` calls in `deinit` give them back.
nonisolated final class LlamaSentenceTokenModel: SentenceTokenModel {
    /// A finished sentence is at most 320 characters, so frame + guess stays far below this.
    private static let contextSize: Int32 = 1_024
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

    func forget(last removed: Int) {
        count = max(count - Int32(removed), 0)
        // Removes positions [count, end) of sequence 0; -1 means "to the end".
        _ = llama_memory_seq_rm(llama_get_memory(context), 0, count, -1)
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
