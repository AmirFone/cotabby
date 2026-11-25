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
    /// Called on the main thread with how long one pass of the model took, in milliseconds. The
    /// opt-in training record keeps the slowest per word: on a Mac short of memory a pass that
    /// takes 12 ms elsewhere takes many times that, and nothing in a recorded day used to say so.
    var onPassTimed: ((Int) -> Void)? {
        didSet { worker.onPassTimed = onPassTimed }
    }

    private let worker: Worker
    private var latest: LanguageModelScores?
    /// True from the model's first answer until it fails to give one. Before that (still loading,
    /// or no model at all) nobody should wait for it.
    private var isAnswering = false
    /// The answer worked out ahead for the text as it will be once the current word is finished
    /// (`lookAheadKey`), and the text it was last asked for, so each is asked once.
    private var ahead: LanguageModelScores?
    private var aheadAsked: LanguageModelContext.Key?
    /// The text whose answer the strip is waiting for; an answer worked out ahead for it is used
    /// the moment it lands.
    private var awaited: LanguageModelContext.Key?
    /// The exact pass that has been asked for and not answered yet: the text and the letters typed
    /// it is for. While it is out, the order in hand for those letters is about to change
    /// (`isAnswerPending`).
    private var refinementAsked: RefinementRequest?
    /// The last exact pass the model could not give (it had moved on, or cannot take a piece
    /// back out of its memory). Not asked for again: every draw of the strip would wait for it.
    private var refinementDeclined: RefinementRequest?

    private struct RefinementRequest: Equatable {
        let key: LanguageModelContext.Key
        let prefix: String
    }

    /// What the writer finished lately, read by the model before the field's own text; nil reads
    /// the field alone.
    private let recentWriting: RecentWriting?

    /// - Parameter wordListURLs: see `WordLanguageModelCore.init`. Empty means no model.
    init(modelURL: URL?, wordListURLs: [URL], recentWriting: RecentWriting? = nil) {
        worker = Worker(modelURL: modelURL, wordListURLs: wordListURLs)
        self.recentWriting = recentWriting
    }

    /// The text the model is asked about for a field holding `text` before the caret.
    func textRead(forTextBefore text: String) -> String {
        (recentWriting?.preamble(for: text) ?? "") + text
    }

    /// The word lists in the app bundle, in the order the model reads them.
    static func bundledWordListURLs(in bundle: Bundle = .main) -> [URL] {
        ["frequency_dictionary_en_82_765", "prediction_words_en"].compactMap {
            bundle.url(forResource: $0, withExtension: "txt")
        } + [TechnicalVocabulary.stripListURL(in: bundle)].compactMap { $0 }
    }

    /// A model the app can use for this, best first. All are files the app already installs for
    /// other features, so this feature downloads nothing of its own.
    struct Candidate: Equatable {
        let fileName: String
        /// Macs with less memory than this skip the model: it would crowd out the writer's apps.
        let minimumMemoryBytes: UInt64
    }

    /// Measured on the held-back long test documents (`Tools/prediction/README.md`): first
    /// suggestion right while a word is being typed / right verb form first, and the time of one
    /// pass alone on an M3 Max.
    /// - Gemma 4 E2B (3.8 GB): 83% / 94%, 11 ms.
    /// - Qwen 3.5 2B base (1.3 GB): 79% / 90%, 8 ms.
    /// - Qwen 3.5 0.8B base (0.6 GB): 76% / 89%, 6 ms.
    /// - the sentence model's own file (already loaded): 69% / 84%, 5 ms. Always there in a release.
    ///
    /// Larger models were measured and left out: up to twice Gemma 4 E2B's size they add a point
    /// or less, and a 12B model adds about three points for two and a half times the time per word.
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
    func scores(forTextBefore fieldText: String) -> LanguageModelScores? {
        let text = textRead(forTextBefore: fieldText)
        guard let context = LanguageModelContext.make(textBefore: text) else { return nil }
        guard let latest, latest.key == context.key else {
            awaited = context.key
            // The model still reads the text itself (its memory has to move on to this word for
            // the refinements), but the strip does not wait for that when the look-ahead got here
            // first.
            request(context.key)
            guard let ahead, ahead.key == context.key else { return nil }
            self.latest = ahead
            CotabbyLogger.suggestion.debug("Word language model: ready ahead in 0 ms")
            return ahead
        }
        let prefix = context.prefix.lowercased()
        let refinement = RefinementRequest(key: context.key, prefix: prefix)
        if refinement != refinementAsked, refinement != refinementDeclined, !latest.piecesWorthRefining(prefix: prefix).isEmpty {
            refinementAsked = refinement
            worker.request(.refinement(latest, prefix: prefix)) { [weak self] in
                self?.acceptRefinement($0, for: refinement)
            }
        }
        if let next = Self.lookAheadKey(textBefore: text, context: context, scores: latest), next != aheadAsked {
            aheadAsked = next
            worker.request(.lookAhead(next)) { [weak self] in self?.acceptAhead($0) }
        }
        return latest
    }

    /// The text the look-ahead answer in hand is for, if any. Tests wait on this instead of a fixed
    /// time, which a busy machine would not keep to.
    var lookAheadText: String? { ahead?.key.text }

    /// The text the model will be asked about next if the writer finishes the current word the
    /// likely way: the letters typed when they already spell a word (every word typed out in full
    /// passes through this just before its space), otherwise the first word of the strip, which
    /// is what a pick types. Nil before any letter, or when neither gives a word.
    nonisolated static func lookAheadKey(
        textBefore text: String, context: LanguageModelContext, scores: LanguageModelScores
    ) -> LanguageModelContext.Key? {
        let typed = context.prefix
        guard !typed.isEmpty else { return nil }
        let lowercased = typed.lowercased()
        let finished: String
        if scores.lexicon.index(of: lowercased) != nil {
            finished = typed
        } else if let best = scores.best(prefix: lowercased, limit: 1).first?.word {
            // A pick keeps the letters the writer typed and adds the rest of the word.
            finished = typed + best.dropFirst(lowercased.count)
        } else {
            return nil
        }
        return LanguageModelContext.make(textBefore: text.dropLast(typed.count) + finished + " ")?.key
    }

    /// True when an answer for this text has been asked for and is on its way: the strip holds its
    /// redraw for a moment instead of showing an order it is about to replace.
    ///
    /// That is the first answer for a new word, and also the exact pass for the letters typed so
    /// far. The exact pass used to be left out: the strip was drawn from the first estimate and
    /// drawn again some ten milliseconds later with two words swapped, which is the kind of
    /// change a writer sees without being able to say what moved. It is one pass of the model now
    /// (`WordLanguageModelCore.refine`), so waiting for it costs less than a frame of the display.
    func isAnswerPending(forTextBefore text: String) -> Bool {
        guard isAnswering, let context = LanguageModelContext.make(textBefore: textRead(forTextBefore: text)) else { return false }
        guard latest?.key == context.key else { return true }
        return refinementAsked == RefinementRequest(key: context.key, prefix: context.prefix.lowercased())
    }

    private func request(_ key: LanguageModelContext.Key) {
        // The worker drops an exact pass that is still waiting when a new text is asked about, so
        // that pass will never report back.
        refinementAsked = nil
        refinementDeclined = nil
        worker.request(.answer(key)) { [weak self] in self?.accept($0) }
    }

    private func acceptAhead(_ scores: LanguageModelScores?) {
        guard let scores else { return }
        ahead = scores
        // The writer got there before the look-ahead finished: the strip is waiting for this.
        guard awaited == scores.key, latest?.key != scores.key else { return }
        latest = scores
        onReady?()
    }

    /// An exact pass came back. `onReady` fires even when it had nothing to give (the model had
    /// moved on to another text): a strip may be held back for exactly this, and it should be
    /// drawn now and not when its wait runs out.
    private func acceptRefinement(_ scores: LanguageModelScores?, for request: RefinementRequest) {
        if refinementAsked == request { refinementAsked = nil }
        guard scores != nil else {
            refinementDeclined = request
            onReady?()
            return
        }
        accept(scores, wasRefinement: true)
    }

    private func accept(_ scores: LanguageModelScores?, wasRefinement: Bool = false) {
        // A refinement with nothing to refine is not a failure of the model.
        if !wasRefinement { isAnswering = scores != nil }
        guard let scores else { return }
        // A refinement that arrives after the writer started another word is of no use.
        if !scores.refinedPieces.isEmpty, let latest, latest.key != scores.key { return }
        // The same answer the look-ahead already gave the strip: nothing new to draw.
        if !wasRefinement, let latest, latest.key == scores.key, awaited == scores.key { return }
        latest = scores
        onReady?()
    }

    enum Job {
        case answer(LanguageModelContext.Key)
        case refinement(LanguageModelScores, prefix: String)
        case lookAhead(LanguageModelContext.Key)
    }

    /// How an answer gets back to the main thread.
    typealias Delivery = @MainActor (LanguageModelScores?) -> Void

    /// The queue side. It keeps at most one answer, one refinement and one look-ahead waiting.
    ///
    /// Only the newest answer request is worth working on: by the time an older one could finish,
    /// the writer has typed on and nobody will read it. A refinement never takes an answer's place
    /// (the answer is what the next word's strip is waiting for), and a new answer request drops a
    /// waiting refinement, which belonged to the word before. A look-ahead is a guess about the
    /// word after this one, so it runs last, when nothing the strip is showing now is waiting.
    private final class Worker: @unchecked Sendable {
        private let modelURL: URL?
        private let wordListURLs: [URL]
        private let queue = DispatchQueue(label: "com.cotabby.word-language-model", qos: .userInitiated)
        private let lock = NSLock()
        private var wantedAnswer: (key: LanguageModelContext.Key, deliver: Delivery)?
        private var wantedRefinement: (job: Job, deliver: Delivery)?
        private var wantedLookAhead: (key: LanguageModelContext.Key, deliver: Delivery)?
        private var isRunning = false
        /// Set and read on the main thread only (it is called there).
        var onPassTimed: ((Int) -> Void)?
        /// Touched only on `queue`.
        private var core: WordLanguageModelCore?
        private var didTryLoading = false

        init(modelURL: URL?, wordListURLs: [URL]) {
            self.modelURL = modelURL
            self.wordListURLs = wordListURLs
        }

        func request(_ job: Job, deliver: @escaping Delivery) {
            lock.lock()
            switch job {
            case .answer(let key):
                wantedAnswer = (key, deliver)
                wantedRefinement = nil
                wantedLookAhead = nil
            case .refinement:
                wantedRefinement = (job, deliver)
            case .lookAhead(let key):
                wantedLookAhead = (key, deliver)
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
                let lookAhead = answer == nil && refinement == nil ? wantedLookAhead : nil
                if answer != nil {
                    wantedAnswer = nil
                } else if refinement != nil {
                    wantedRefinement = nil
                } else {
                    wantedLookAhead = nil
                }
                if answer == nil, refinement == nil, lookAhead == nil { isRunning = false }
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
                } else if let lookAhead {
                    scores = loadedCore()?.lookAhead(to: lookAhead.key)
                    (kind, deliver) = (scores == nil ? "no look-ahead" : "look-ahead", lookAhead.deliver)
                } else {
                    return
                }
                let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                CotabbyLogger.suggestion.debug("Word language model: \(kind) in \(String(format: "%.1f", milliseconds)) ms")
                DispatchQueue.main.async { [weak self] in
                    self?.onPassTimed?(Int(milliseconds))
                    deliver(scores)
                }
            }
        }

        private func loadedCore() -> WordLanguageModelCore? {
            if !didTryLoading {
                didTryLoading = true
                guard let modelURL, !wordListURLs.isEmpty else { return nil }
                let started = DispatchTime.now().uptimeNanoseconds
                core = WordLanguageModelCore(modelURL: modelURL, wordListURLs: wordListURLs)
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
