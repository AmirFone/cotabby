import Combine
import Foundation

/// Main-actor owner of the hosted endpoint's `EndpointRateBudget`.
///
/// The budget is a pure value so its arithmetic is testable with an injected clock. This wrapper
/// exists because three independent collaborators must share one budget: the endpoint engine asks
/// before every request, the API client reports server rate-limit headers after every response, and
/// Settings/Home show when the app is cooling down. `CotabbyAppEnvironment` builds exactly one for
/// the app lifetime, so the ledger survives engine switches and settings changes.
@MainActor
final class EndpointRateGovernor: ObservableObject {
    /// Non-nil while a 429 cooldown is active. UI shows it; the engine skips requests until then.
    @Published private(set) var cooldownEndsAt: Date?
    @Published private(set) var tokensUsedLastMinute = 0

    private var budget: EndpointRateBudget
    private let now: () -> Date

    init(tokensPerMinute: Int, now: @escaping () -> Date = Date.init) {
        budget = EndpointRateBudget(tokensPerMinute: tokensPerMinute)
        self.now = now
    }

    /// Main-actor stores deallocated inside app-hosted tests need a nonisolated deinit; see
    /// `SuggestionQualityMetricsStore`.
    nonisolated deinit {}

    var tokensPerMinute: Int { budget.tokensPerMinute }
    var isWordBoundaryOnly: Bool { budget.isWordBoundaryOnly }

    func setTokensPerMinute(_ tokensPerMinute: Int) {
        budget.tokensPerMinute = tokensPerMinute
    }

    func decide(estimatedTokens: Int, isAtWordBoundary: Bool) -> EndpointRateBudget.Decision {
        let date = now()
        let decision = budget.decide(estimatedTokens: estimatedTokens, isAtWordBoundary: isAtWordBoundary, now: date)
        publish(now: date)
        return decision
    }

    func noteSuccess() {
        budget.noteSuccess()
    }

    func noteRateLimited(retryAfterSeconds: Double?) {
        let date = now()
        budget.noteRateLimited(retryAfterSeconds: retryAfterSeconds, now: date)
        publish(now: date)
    }

    func ingest(_ snapshot: OpenAICompatibleRateLimitSnapshot) {
        budget.ingest(snapshot, now: now())
    }

    private func publish(now date: Date) {
        let cooldown = budget.cooldownEndsAt.flatMap { $0 > date ? $0 : nil }
        if cooldownEndsAt != cooldown { cooldownEndsAt = cooldown }
        let used = budget.tokensUsed(now: date)
        if tokensUsedLastMinute != used { tokensUsedLastMinute = used }
    }
}
