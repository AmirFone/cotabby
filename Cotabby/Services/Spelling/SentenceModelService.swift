import Foundation
import Logging

/// File overview:
/// Runs the sentence model (see `SentenceModelCorrection.swift`) on a finished sentence.
///
/// Two types, one boundary:
/// - `SentenceModelService` is what the app holds. It finds the model file, loads it once on its own
///   queue, and answers `correct(_:)` off the main thread. When the file is not installed the service
///   answers nil and the sentence pass simply has one stage fewer, so no caller handles "missing
///   model" as an error.
/// - `LlamaTokenModel` (`Services/Runtime/Llama`) is the `SentenceTokenModel` the decoder drives: a
///   llama.cpp model and context of its own, separate from the ghost-text engine.
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
    private var model: LlamaTokenModel?
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

    private func loadedModel() -> LlamaTokenModel? {
        if !didTryLoading {
            didTryLoading = true
            guard isInstalled else { return nil }
            let started = DispatchTime.now().uptimeNanoseconds
            model = LlamaTokenModel(url: modelURL)
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
