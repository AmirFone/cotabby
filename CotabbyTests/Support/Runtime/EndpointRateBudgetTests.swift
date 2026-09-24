import XCTest
@testable import Cotabby

/// The budget decides whether each keystroke's request is sent, delayed, shrunk, or skipped. These
/// tests drive it with a fixed clock so window rollover and backoff are deterministic.
final class EndpointRateBudgetTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    func test_decide_sendsFullPromptWellUnderBudget() {
        var budget = EndpointRateBudget(tokensPerMinute: 250_000)

        let decision = budget.decide(estimatedTokens: 3_000, isAtWordBoundary: false, now: start)

        XCTAssertEqual(decision, .send(prefixScale: 1))
        XCTAssertEqual(budget.tokensUsed(now: start), 3_000)
    }

    func test_decide_waitsOutMinimumSpacingBetweenRequests() {
        var budget = EndpointRateBudget(tokensPerMinute: 250_000)
        _ = budget.decide(estimatedTokens: 100, isAtWordBoundary: true, now: start)

        let decision = budget.decide(estimatedTokens: 100, isAtWordBoundary: true, now: start.addingTimeInterval(0.05))

        guard case .wait(let seconds) = decision else {
            return XCTFail("Expected a spacing wait, got \(decision)")
        }
        XCTAssertEqual(seconds, 0.10, accuracy: 0.001)
    }

    func test_decide_shrinksPromptPastSeventyPercentThenSkipsWhenFull() {
        var budget = EndpointRateBudget(tokensPerMinute: 100_000)
        _ = budget.decide(estimatedTokens: 70_000, isAtWordBoundary: true, now: start)

        let shrunk = budget.decide(estimatedTokens: 15_000, isAtWordBoundary: true, now: start.addingTimeInterval(1))
        guard case .send(let scale) = shrunk else { return XCTFail("Expected send, got \(shrunk)") }
        XCTAssertLessThan(scale, 1)
        XCTAssertGreaterThanOrEqual(scale, 0.5)

        let skipped = budget.decide(estimatedTokens: 90_000, isAtWordBoundary: true, now: start.addingTimeInterval(2))
        XCTAssertEqual(skipped, .skip(.overBudget))
    }

    func test_decide_windowRollsOverAfterSixtySeconds() {
        var budget = EndpointRateBudget(tokensPerMinute: 10_000)
        _ = budget.decide(estimatedTokens: 6_000, isAtWordBoundary: true, now: start)
        XCTAssertEqual(
            budget.decide(estimatedTokens: 10_000, isAtWordBoundary: true, now: start.addingTimeInterval(30)),
            .skip(.overBudget)
        )

        let decision = budget.decide(estimatedTokens: 6_000, isAtWordBoundary: true, now: start.addingTimeInterval(61))

        XCTAssertEqual(decision, .send(prefixScale: 1))
    }

    func test_noteRateLimited_coolsDownForRetryAfterAndBacksOff() {
        var budget = EndpointRateBudget(tokensPerMinute: 250_000)
        budget.noteRateLimited(retryAfterSeconds: 3, now: start)

        XCTAssertEqual(budget.decide(estimatedTokens: 10, isAtWordBoundary: true, now: start.addingTimeInterval(2)), .skip(.coolingDown))
        XCTAssertEqual(budget.decide(estimatedTokens: 10, isAtWordBoundary: true, now: start.addingTimeInterval(3.1)), .send(prefixScale: 1))

        budget.noteRateLimited(retryAfterSeconds: nil, now: start.addingTimeInterval(4))
        XCTAssertEqual(budget.cooldownEndsAt, start.addingTimeInterval(6))
    }

    func test_freeTierBudget_onlyRequestsAtWordBoundaries() {
        var budget = EndpointRateBudget(tokensPerMinute: 8_000)

        XCTAssertEqual(budget.decide(estimatedTokens: 500, isAtWordBoundary: false, now: start), .skip(.notAtWordBoundary))
        XCTAssertEqual(budget.decide(estimatedTokens: 500, isAtWordBoundary: true, now: start), .send(prefixScale: 1))
    }

    func test_ingest_serverRemainingTokensTightensBudget() {
        var budget = EndpointRateBudget(tokensPerMinute: 250_000)
        budget.ingest(OpenAICompatibleRateLimitSnapshot(remainingTokens: 1_000, secondsUntilTokensReset: 30), now: start)

        let decision = budget.decide(estimatedTokens: 5_000, isAtWordBoundary: true, now: start)

        XCTAssertEqual(decision, .skip(.overBudget))
    }
}
