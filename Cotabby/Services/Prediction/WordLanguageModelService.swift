import Foundation
import Logging

/// File overview:
/// Runs the word language model (see `Support/Prediction/WordLanguageModel.swift`): for the text
/// before the word being typed, how likely is each dictionary word to come next.
///
/// `WordLanguageModelCore` does the work; this service is what the app holds. It keeps the core on
/// its own queue, answers the main thread from the last finished result, and calls `onReady` when a
/// newer one arrives.
///
/// Why the app never waits for it: a pass takes several milliseconds and the word strip is shown
/// within one. So the strip is drawn at once from the n-gram table and redrawn when the model's
/// answer lands. In practice the model is asked when a word is finished (the space), and its answer
/// is there before the first letter of the next word.

/// The app's handle on the word language model. Owned by `CotabbyAppEnvironment` for the life of
/// the app; with no model file installed it answers nil forever and the strip runs on the n-gram
/// table alone, so no caller handles "missing model" as a case.
@MainActor
final class WordLanguageModelService {
    /// Called on the main thread when a requested answer is ready, so the strip can be redrawn.
    var onReady: (() -> Void)?

    private let worker: Worker
    private var latest: LanguageModelScores?
    /// True from the model's first answer until it fails to give one. Before that (still loading,
    /// or no model at all) nobody should wait for it.
    private var isAnswering = false

    init(modelURL: URL?, dictionaryURL: URL?) {
        worker = Worker(modelURL: modelURL, dictionaryURL: dictionaryURL)
    }

    /// A model the app can use for this, best first. All are files the app already installs for
    /// other features, so this feature downloads nothing of its own.
    struct Candidate: Equatable {
        let fileName: String
        /// Macs with less memory than this skip the model: it would crowd out the writer's apps.
        let minimumMemoryBytes: UInt64
    }

    /// Measured on the held-back test passages (`Tools/prediction/README.md`): first suggestion
    /// right at all typing moments / right verb form first, and the time of one pass alone on an
    /// M3 Max.
    /// - Gemma 4 E2B (3.8 GB): 70% / 93%, 11 ms.
    /// - Qwen 3.5 2B base (1.3 GB): 67% / 91%, about 13 ms.
    /// - Qwen 3.5 0.8B base (0.6 GB): 65% / 91%, 6 ms.
    /// - the sentence model's own file (already loaded): 58% / 84%, 5 ms. Always there in a release.
    static let ghostTextCandidates = [
        Candidate(fileName: "gemma-4-E2B.i1-Q6_K.gguf", minimumMemoryBytes: 16 << 30),
        Candidate(fileName: "Qwen3.5-2B-Base.i1-Q4_K_M.gguf", minimumMemoryBytes: 12 << 30),
        Candidate(fileName: "Qwen3.5-0.8B-Base.i1-Q6_K.gguf", minimumMemoryBytes: 0)
    ]

    /// The first candidate that is installed and fits in memory, in the folder of the ghost-text
    /// models; nil when none is.
    nonisolated static func bestCandidate(
        among candidates: [Candidate] = ghostTextCandidates,
        memoryBytes: UInt64,
        isInstalled: (String) -> Bool
    ) -> Candidate? {
        candidates.first { memoryBytes >= $0.minimumMemoryBytes && isInstalled($0.fileName) }
    }

    /// The model file to use: the best installed ghost-text model, otherwise the sentence model's.
    static func defaultModelURL(bundle: Bundle = .main) -> URL? {
        let folder = BundledRuntimeLocator.userRuntimeDirectoryURL(bundle: bundle)
        let best = bestCandidate(memoryBytes: ProcessInfo.processInfo.physicalMemory) {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        if let best { return folder.appendingPathComponent(best.fileName) }
        let sentenceModel = SentenceModelService.defaultModelURL(bundle: bundle)
        return FileManager.default.fileExists(atPath: sentenceModel.path) ? sentenceModel : nil
    }

    /// Loads the model ahead of the first word, so that word does not pay for the load.
    func warmUp() {
        request(LanguageModelContext.Key(text: "", isSpaced: false))
    }

    /// The model's answer for the text before the caret, when it is the one already worked out.
    /// Otherwise nil, and the answer is requested: `onReady` fires when it is there. With letters
    /// typed, the exact numbers for the words those letters single out are requested too, once.
    func scores(forTextBefore text: String) -> LanguageModelScores? {
        guard let context = LanguageModelContext.make(textBefore: text) else { return nil }
        guard let latest, latest.key == context.key else {
            worker.request(.answer(context.key)) { [weak self] in self?.accept($0) }
            return nil
        }
        let prefix = context.prefix.lowercased()
        if !latest.piecesWorthRefining(prefix: prefix).isEmpty {
            worker.request(.refinement(latest, prefix: prefix)) { [weak self] in self?.accept($0, wasRefinement: true) }
        }
        return latest
    }

    /// True when an answer for this text has been asked for and is on its way: the strip holds its
    /// redraw for a moment instead of showing an order it is about to replace.
    func isAnswerPending(forTextBefore text: String) -> Bool {
        guard isAnswering, let context = LanguageModelContext.make(textBefore: text) else { return false }
        return latest?.key != context.key
    }

    private func request(_ key: LanguageModelContext.Key) {
        worker.request(.answer(key)) { [weak self] in self?.accept($0) }
    }

    private func accept(_ scores: LanguageModelScores?, wasRefinement: Bool = false) {
        // A refinement with nothing to refine is not a failure of the model.
        if !wasRefinement { isAnswering = scores != nil }
        guard let scores else { return }
        // A refinement that arrives after the writer started another word is of no use.
        if !scores.refinedPieces.isEmpty, let latest, latest.key != scores.key { return }
        latest = scores
        onReady?()
    }

    enum Job {
        case answer(LanguageModelContext.Key)
        case refinement(LanguageModelScores, prefix: String)
    }

    /// How an answer gets back to the main thread.
    typealias Delivery = @MainActor (LanguageModelScores?) -> Void

    /// The queue side. It keeps at most one answer and one refinement waiting.
    ///
    /// Only the newest answer request is worth working on: by the time an older one could finish,
    /// the writer has typed on and nobody will read it. A refinement never takes an answer's place
    /// (the answer is what the next word's strip is waiting for), and a new answer request drops a
    /// waiting refinement, which belonged to the word before.
    private final class Worker: @unchecked Sendable {
        private let modelURL: URL?
        private let dictionaryURL: URL?
        private let queue = DispatchQueue(label: "com.cotabby.word-language-model", qos: .userInitiated)
        private let lock = NSLock()
        private var wantedAnswer: (key: LanguageModelContext.Key, deliver: Delivery)?
        private var wantedRefinement: (job: Job, deliver: Delivery)?
        private var isRunning = false
        /// Touched only on `queue`.
        private var core: WordLanguageModelCore?
        private var didTryLoading = false

        init(modelURL: URL?, dictionaryURL: URL?) {
            self.modelURL = modelURL
            self.dictionaryURL = dictionaryURL
        }

        func request(_ job: Job, deliver: @escaping Delivery) {
            lock.lock()
            switch job {
            case .answer(let key):
                wantedAnswer = (key, deliver)
                wantedRefinement = nil
            case .refinement:
                wantedRefinement = (job, deliver)
            }
            let shouldStart = !isRunning
            if shouldStart { isRunning = true }
            lock.unlock()
            if shouldStart { queue.async { self.drain() } }
        }

        private func drain() {
            while true {
                lock.lock()
                let answer = wantedAnswer
                let refinement = answer == nil ? wantedRefinement : nil
                if answer != nil { wantedAnswer = nil } else { wantedRefinement = nil }
                if answer == nil, refinement == nil { isRunning = false }
                lock.unlock()

                let started = DispatchTime.now().uptimeNanoseconds
                let scores: LanguageModelScores?
                let kind: String
                let deliver: Delivery
                if let answer {
                    scores = loadedCore()?.scores(for: answer.key)
                    (kind, deliver) = ("answer", answer.deliver)
                } else if let refinement, case .refinement(let earlier, let prefix) = refinement.job {
                    scores = loadedCore()?.refine(earlier, forPrefix: prefix)
                    (kind, deliver) = (scores == nil ? "nothing to refine" : "refinement", refinement.deliver)
                } else {
                    return
                }
                let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                CotabbyLogger.suggestion.debug("Word language model: \(kind) in \(String(format: "%.1f", milliseconds)) ms")
                DispatchQueue.main.async { deliver(scores) }
            }
        }

        private func loadedCore() -> WordLanguageModelCore? {
            if !didTryLoading {
                didTryLoading = true
                guard let modelURL, let dictionaryURL else { return nil }
                let started = DispatchTime.now().uptimeNanoseconds
                core = WordLanguageModelCore(modelURL: modelURL, dictionaryURL: dictionaryURL)
                let milliseconds = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                if core == nil {
                    CotabbyLogger.runtime.error("Word language model: could not load \(modelURL.lastPathComponent)")
                } else {
                    CotabbyLogger.runtime.info("Word language model: loaded \(modelURL.lastPathComponent) in \(milliseconds) ms")
                }
            }
            return core
        }
    }
}
