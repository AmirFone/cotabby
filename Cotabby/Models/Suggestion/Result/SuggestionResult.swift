import Foundation

/// Backend-independent generation output returned to the suggestion coordinator.

/// The engine's normalized response, including raw model text for debugging.
struct SuggestionResult: Equatable, Sendable {
    let generation: UInt64
    let rawText: String
    let text: String
    let latency: TimeInterval
    /// Raw value of the `CompletionSuppressionReason` that emptied `text`, when one applies.
    /// Carried as a string so the coordinator's quality accounting never needs the normalizer
    /// type, and so engine-specific reasons can ride along without enum churn. The explicit
    /// initializer default keeps existing call sites compiling unchanged.
    let suppressionReason: String?
    /// Other plausible continuations, already normalized, most likely first. Empty unless the engine
    /// asked for alternates; the candidate list offers them behind the Down arrow.
    let alternates: [String]

    init(
        generation: UInt64,
        rawText: String,
        text: String,
        latency: TimeInterval,
        suppressionReason: String? = nil,
        alternates: [String] = []
    ) {
        self.generation = generation
        self.rawText = rawText
        self.text = text
        self.latency = latency
        self.suppressionReason = suppressionReason
        self.alternates = alternates
    }
}
