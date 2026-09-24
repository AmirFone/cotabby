import Foundation
import Logging

/// File overview:
/// Decides when a spelling decision is worth a Jev call, makes it off the keystroke path, and
/// caches the answer so the next pass of the typo gate can use it.
///
/// The typo gate is synchronous and always answers from local evidence first, so the bar appears
/// instantly. When the local answer is unsure (several close candidates, or a suspected real-word
/// slip) the coordinator calls `request`, and a verdict usually lands 100–400 ms later. `onRefined`
/// then re-runs the gate, which finds the cached verdict and reorders the bar, or applies the fix if
/// Jev is now confident and the word is still exactly where it was.
///
/// Calls are rationed: confident local fixes never reach Jev, bursts of typing are debounced, and a
/// hard per-minute cap protects a small plan. Without an API key this class does nothing and the app
/// stays fully local.
@MainActor
final class WordIntentRefiner {
    struct Key: Hashable {
        let word: String
        let leftContext: String

        init(word: String, textBefore: String) {
            self.word = word.lowercased()
            leftContext = String(textBefore.suffix(80)).lowercased()
        }
    }

    enum Status: Equatable {
        case noKey
        case ready
        case unauthorized
        case coolingDown
    }

    static let debounceNanoseconds: UInt64 = 120_000_000
    static let maximumRequestsPerMinute = 40
    static let cacheLimit = 256
    static let rateLimitCooldown: TimeInterval = 30

    var onRefined: (() -> Void)?
    private(set) var status: Status = .noKey
    private(set) var lastLatencyMilliseconds: Int?

    private let apiKeyProvider: () -> String?
    private let fetch: @Sendable (JevWordIntentRequest, String) async throws -> JevWordIntentVerdict
    private let now: () -> Date
    private var apiKey: String?
    private var cache: [Key: JevWordIntentVerdict] = [:]
    private var cacheOrder: [Key] = []
    private var inFlight: Set<Key> = []
    private var pendingTask: Task<Void, Never>?
    private var sentTimestamps: [Date] = []
    private var cooldownUntil: Date?

    init(
        apiKeyProvider: @escaping () -> String?,
        fetch: @escaping @Sendable (JevWordIntentRequest, String) async throws -> JevWordIntentVerdict = {
            try await JevWordIntentClient.verdict(for: $0, apiKey: $1)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.fetch = fetch
        self.now = now
        reloadAPIKey()
    }

    nonisolated deinit {}

    var isAvailable: Bool { status == .ready }

    func reloadAPIKey() {
        let key = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = key?.isEmpty == false ? key : nil
        status = apiKey == nil ? .noKey : .ready
        cooldownUntil = nil
    }

    func verdict(for key: Key) -> JevWordIntentVerdict? {
        cache[key]
    }

    /// Queues a Jev decision for `request`, replacing any queued one that has not been sent yet, so
    /// only the word the writer stopped on is asked about.
    func request(_ request: JevWordIntentRequest) {
        let key = Key(word: request.typedWord, textBefore: request.textBefore)
        guard let apiKey, cache[key] == nil, !inFlight.contains(key), request.options.count >= 1 else { return }
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.send(request, key: key, apiKey: apiKey)
        }
    }

    private func send(_ request: JevWordIntentRequest, key: Key, apiKey: String) async {
        let start = now()
        if let cooldownUntil, start < cooldownUntil { return }
        sentTimestamps.removeAll { start.timeIntervalSince($0) > 60 }
        guard sentTimestamps.count < Self.maximumRequestsPerMinute else {
            CotabbyLogger.suggestion.debug("jev skipped: per-minute cap reached")
            return
        }
        sentTimestamps.append(start)
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        do {
            let verdict = try await fetch(request, apiKey)
            lastLatencyMilliseconds = Int(now().timeIntervalSince(start) * 1000)
            store(verdict, for: key)
            if status == .coolingDown { status = .ready }
            CotabbyLogger.suggestion.debug(
                "jev verdict for \(request.typedWord) in \(lastLatencyMilliseconds ?? 0)ms: \(verdict.probabilities)"
            )
            onRefined?()
        } catch JevWordIntentError.unauthorized {
            status = .unauthorized
            CotabbyLogger.suggestion.error("jev rejected the API key")
        } catch JevWordIntentError.rateLimited {
            status = .coolingDown
            cooldownUntil = now().addingTimeInterval(Self.rateLimitCooldown)
        } catch {
            CotabbyLogger.suggestion.debug("jev request failed: \(error.localizedDescription)")
        }
    }

    private func store(_ verdict: JevWordIntentVerdict, for key: Key) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = verdict
        while cacheOrder.count > Self.cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}

/// Turns a Jev verdict into ranked candidates the typo gate can apply its usual tiers to.
nonisolated enum WordIntentVerdictMapper {
    /// - Returns: candidates best first, recased like `typedWord`, excluding the typed word itself,
    ///   and the probability that the typed word was right (nil when it was not an option).
    static func candidates(
        from verdict: JevWordIntentVerdict,
        typedWord: String,
        personal: [String: Int]
    ) -> (candidates: [SpellingCandidate], typedProbability: Double?) {
        let typed = typedWord.lowercased()
        var candidates: [SpellingCandidate] = []
        for (term, probability) in verdict.probabilities where term != typed {
            let accepted = Double(personal[term] ?? 0)
            let boost = min(0.15, 0.05 * accepted)
            let recased = TypoCaseTransfer.applying(caseOf: typedWord, to: term)
            candidates.append(SpellingCandidate(term: recased, score: probability + boost))
        }
        candidates.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.term < rhs.term
        }
        return (Array(candidates.prefix(SpellingCandidateRanker.maxCandidates)), verdict.probabilities[typed])
    }
}
