import Foundation

/// Chooses the prediction debounce from the last observed generation latency.
///
/// A fixed debounce serves two masters badly: on fast hardware it adds avoidable delay before
/// every suggestion, and on slow hardware it lets keystrokes pile doomed generations onto a model
/// that cannot keep up (each cancel still costs a decode setup and teardown). Keying the debounce
/// to the most recent generation latency makes fast machines snappier and slow machines calmer,
/// with no configuration. The configured value remains the fallback until a first latency exists.
nonisolated enum DebouncePolicy {
    static func milliseconds(
        lastGenerationLatencyMilliseconds: Int?,
        fallback: Int,
        engine: SuggestionEngineKind = .llamaOpenSource,
        isCloudEndpoint: Bool = false
    ) -> Int {
        if isCloudEndpoint {
            return cloudMilliseconds(lastGenerationLatencyMilliseconds: lastGenerationLatencyMilliseconds, fallback: fallback)
        }
        // An HTTP endpoint cannot reuse Cotabby's in-process KV cache, and cancelling a request does
        // not guarantee the remote server stops its tokenizer immediately. A trailing-edge pause
        // therefore saves more time than it costs: it collapses a typing burst into one useful
        // request instead of filling Ollama's queue with work that will be discarded.
        if engine == .openAICompatible {
            guard let last = lastGenerationLatencyMilliseconds, last > 0 else {
                return max(fallback, 180)
            }
            switch last {
            case ...300: return 100
            case ...700: return 150
            default: return 220
            }
        }

        guard let last = lastGenerationLatencyMilliseconds, last > 0 else {
            return fallback
        }
        switch last {
        case ...70: return 15
        case ...140: return 25
        default: return 55
        }
    }

    /// Groq returns a whole autocomplete in ~150 ms round trip and bills nothing for requests it
    /// never receives, so its pause only needs to swallow keystrokes typed faster than a response
    /// could arrive. The rate budget, not the debounce, protects the token quota.
    private static func cloudMilliseconds(lastGenerationLatencyMilliseconds: Int?, fallback: Int) -> Int {
        guard let last = lastGenerationLatencyMilliseconds, last > 0 else {
            return max(fallback, 90)
        }
        switch last {
        case ...250: return 60
        case ...500: return 100
        default: return 160
        }
    }
}
