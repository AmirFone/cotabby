import Foundation

/// File overview:
/// The provider's own view of remaining capacity, parsed from `x-ratelimit-*` response headers.
/// Groq (and OpenAI) send these on every response; local servers send none, so the initializer is
/// failable and a missing snapshot simply means "no server-side budget to respect". The value is
/// produced by `OpenAICompatibleAPIClient` and consumed by `EndpointRateBudget`.
nonisolated struct OpenAICompatibleRateLimitSnapshot: Equatable, Sendable {
    /// Token ceiling for the provider's token window (Groq: tokens per minute).
    let tokenLimit: Int?
    let remainingTokens: Int?
    let secondsUntilTokensReset: Double?
    /// Request ceiling for the provider's request window (Groq: requests per day).
    let requestLimit: Int?
    let remainingRequests: Int?
    let secondsUntilRequestsReset: Double?

    init(
        tokenLimit: Int? = nil,
        remainingTokens: Int? = nil,
        secondsUntilTokensReset: Double? = nil,
        requestLimit: Int? = nil,
        remainingRequests: Int? = nil,
        secondsUntilRequestsReset: Double? = nil
    ) {
        self.tokenLimit = tokenLimit
        self.remainingTokens = remainingTokens
        self.secondsUntilTokensReset = secondsUntilTokensReset
        self.requestLimit = requestLimit
        self.remainingRequests = remainingRequests
        self.secondsUntilRequestsReset = secondsUntilRequestsReset
    }

    init?(headers: HTTPURLResponse) {
        self.init(header: { headers.value(forHTTPHeaderField: $0) })
    }

    init?(header: (String) -> String?) {
        func int(_ raw: String?) -> Int? { raw.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        func duration(_ raw: String?) -> Double? { raw.flatMap(Self.durationSeconds(from:)) }
        self.init(
            tokenLimit: int(header("x-ratelimit-limit-tokens")),
            remainingTokens: int(header("x-ratelimit-remaining-tokens")),
            secondsUntilTokensReset: duration(header("x-ratelimit-reset-tokens")),
            requestLimit: int(header("x-ratelimit-limit-requests")),
            remainingRequests: int(header("x-ratelimit-remaining-requests")),
            secondsUntilRequestsReset: duration(header("x-ratelimit-reset-requests"))
        )
        if tokenLimit == nil, remainingTokens == nil, requestLimit == nil, remainingRequests == nil {
            return nil
        }
    }

    /// `retry-after` is plain seconds; when absent, the token reset window is the next best wait.
    static func retryAfterSeconds(headers: HTTPURLResponse) -> Double? {
        if let raw = headers.value(forHTTPHeaderField: "retry-after"),
           let seconds = Double(raw.trimmingCharacters(in: .whitespaces)) {
            return seconds
        }
        return headers.value(forHTTPHeaderField: "x-ratelimit-reset-tokens").flatMap(durationSeconds(from:))
    }

    /// Parses Go-style durations the providers emit: `29ms`, `7.66s`, `1m2.5s`, `2h1m`.
    static func durationSeconds(from raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let plain = Double(text) { return plain }

        var total = 0.0
        var number = ""
        var index = text.startIndex
        var parsedAnyUnit = false
        while index < text.endIndex {
            let character = text[index]
            if character.isNumber || character == "." {
                number.append(character)
                index = text.index(after: index)
                continue
            }
            guard let value = Double(number) else { return nil }
            let remainder = text[index...]
            if remainder.hasPrefix("ms") {
                total += value / 1_000
                index = text.index(index, offsetBy: 2)
            } else if character == "s" {
                total += value
                index = text.index(after: index)
            } else if character == "m" {
                total += value * 60
                index = text.index(after: index)
            } else if character == "h" {
                total += value * 3_600
                index = text.index(after: index)
            } else {
                return nil
            }
            number = ""
            parsedAnyUnit = true
        }
        guard number.isEmpty, parsedAnyUnit else { return nil }
        return total
    }
}
