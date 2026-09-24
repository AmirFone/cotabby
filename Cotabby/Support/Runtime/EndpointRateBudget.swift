import Foundation

/// File overview:
/// Client-side request governor for hosted endpoints.
///
/// Autocomplete fires on nearly every pause in typing, and a cancelled HTTP request still bills its
/// prompt tokens. Without a governor a fast typist on a free-tier key hits HTTP 429 within seconds,
/// and every suggestion disappears until the window resets. This pure value decides, before each
/// request, whether to send it now, wait a few milliseconds, send it with a smaller prompt, or skip
/// it. `EndpointRateGovernor` owns one for the app lifetime and publishes its state for the UI.
nonisolated struct EndpointRateBudget: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        /// Send now. `prefixScale` < 1 means shrink the caret window to stay under budget.
        case send(prefixScale: Double)
        /// Wait this long, then send. Keeps back-to-back requests from stacking on the server.
        case wait(seconds: Double)
        /// Do not send. Suggestions for this keystroke are skipped quietly.
        case skip(SkipReason)
    }

    enum SkipReason: String, Equatable, Sendable {
        case coolingDown
        case overBudget
        case notAtWordBoundary
    }

    static let minimumRequestSpacing: TimeInterval = 0.15
    static let window: TimeInterval = 60
    /// Past this share of the per-minute budget, prompts start shrinking toward half size.
    static let scaleDownThreshold = 0.7
    /// Budgets at or below this (Groq's free tier is 8k) only request at word boundaries.
    static let wordBoundaryOnlyCeiling = 20_000
    static let maximumBackoff: TimeInterval = 8

    var tokensPerMinute: Int
    private(set) var cooldownEndsAt: Date?
    private var ledger: [Entry] = []
    private var lastSentAt: Date?
    private var consecutiveRateLimits = 0
    private var serverRemainingTokens: Int?
    private var serverResetsAt: Date?

    private struct Entry: Equatable, Sendable {
        let sentAt: Date
        let tokens: Int
    }

    init(tokensPerMinute: Int) {
        self.tokensPerMinute = tokensPerMinute
    }

    var isWordBoundaryOnly: Bool {
        tokensPerMinute <= Self.wordBoundaryOnlyCeiling
    }

    func tokensUsed(now: Date) -> Int {
        ledger.filter { now.timeIntervalSince($0.sentAt) < Self.window }.reduce(0) { $0 + $1.tokens }
    }

    /// Decides what to do with a request estimated at `estimatedTokens`. A `.send` decision also
    /// records the spend, so callers must actually send it.
    mutating func decide(estimatedTokens: Int, isAtWordBoundary: Bool, now: Date) -> Decision {
        prune(now: now)
        if let cooldownEndsAt, now < cooldownEndsAt {
            return .skip(.coolingDown)
        }
        cooldownEndsAt = nil
        if isWordBoundaryOnly, !isAtWordBoundary {
            return .skip(.notAtWordBoundary)
        }
        if let lastSentAt {
            let elapsed = now.timeIntervalSince(lastSentAt)
            if elapsed < Self.minimumRequestSpacing {
                return .wait(seconds: Self.minimumRequestSpacing - elapsed)
            }
        }

        let budget = Double(effectiveBudget(now: now))
        let used = Double(tokensUsed(now: now))
        let projectedShare = (used + Double(estimatedTokens)) / max(budget, 1)
        let scale: Double
        if projectedShare <= Self.scaleDownThreshold {
            scale = 1
        } else if projectedShare <= 1 {
            let overThreshold = (projectedShare - Self.scaleDownThreshold) / (1 - Self.scaleDownThreshold)
            scale = 1 - 0.5 * overThreshold
        } else if (used + Double(estimatedTokens) * 0.5) / max(budget, 1) <= 1 {
            scale = 0.5
        } else {
            return .skip(.overBudget)
        }

        let spent = Int((Double(estimatedTokens) * scale).rounded(.up))
        ledger.append(Entry(sentAt: now, tokens: spent))
        lastSentAt = now
        return .send(prefixScale: scale)
    }

    mutating func noteSuccess() {
        consecutiveRateLimits = 0
    }

    /// A 429 always wins over local accounting: honor the server's wait, doubling on repeats.
    mutating func noteRateLimited(retryAfterSeconds: Double?, now: Date) {
        consecutiveRateLimits += 1
        let backoff = min(Self.maximumBackoff, pow(2, Double(consecutiveRateLimits - 1)))
        let wait = max(retryAfterSeconds ?? 0, backoff)
        cooldownEndsAt = now.addingTimeInterval(wait)
    }

    /// The server's remaining-token header is authoritative when it is lower than local accounting,
    /// for example when another app shares the same API key.
    mutating func ingest(_ snapshot: OpenAICompatibleRateLimitSnapshot, now: Date) {
        serverRemainingTokens = snapshot.remainingTokens
        serverResetsAt = snapshot.secondsUntilTokensReset.map { now.addingTimeInterval($0) }
    }

    private func effectiveBudget(now: Date) -> Int {
        guard let serverRemainingTokens, let serverResetsAt, now < serverResetsAt else {
            return tokensPerMinute
        }
        return min(tokensPerMinute, tokensUsed(now: now) + serverRemainingTokens)
    }

    private mutating func prune(now: Date) {
        ledger.removeAll { now.timeIntervalSince($0.sentAt) >= Self.window }
    }
}
