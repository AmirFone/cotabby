import Foundation

/// File overview:
/// Renders the system/user message pair for cloud chat endpoints (Groq).
///
/// Design: `BaseCompletionPromptRenderer` treats the model as a raw text continuer because the local
/// models are base GGUFs. Groq serves instruction-tuned models behind a chat API, so this renderer
/// uses the channel those models were trained on instead: rules and persona in the system turn, the
/// document in the user turn. Two properties matter for latency and quality:
///
/// 1. Byte stability. Groq caches prompt prefixes, so everything that does not change per keystroke
///    (rules, persona, notes, surface, clipboard, screen) comes first, and the caret prefix, which
///    changes on every keystroke, is the final block.
/// 2. Both sides of the caret. The text after the caret is sent too, so the model can end a
///    mid-sentence insertion cleanly instead of duplicating what already follows.
///
/// The renderer is a pure function of `SuggestionRequest`; `OpenAICompatibleSuggestionEngine` calls it
/// once per request and `SuggestionRequestFactory` calls it for the diagnostics preview.
enum EndpointChatPromptRenderer {
    static let alternateMarker = "###ALT###"

    struct Prompt: Equatable, Sendable {
        let system: String
        let user: String
    }

    /// `prefixScale` < 1 shrinks the caret window when the rate budget is running hot; the text
    /// nearest the caret is always kept.
    static func render(for request: SuggestionRequest, prefixScale: Double = 1.0) -> Prompt {
        Prompt(system: systemPrompt(for: request), user: userPrompt(for: request, prefixScale: prefixScale))
    }

    static func systemPrompt(for request: SuggestionRequest) -> String {
        var lines = [
            "You are an inline autocomplete engine running inside the writer's text field.",
            "Predict the text the writer is most likely to type next at the caret.",
            "Reply with only the text to insert at the caret. No quotes, labels, explanations, or markdown.",
            "Never repeat text that already appears before or after the caret.",
            "If the text before the caret ends partway through a word, finish that word first without a leading space.",
            "The writer is dyslexic: read through misspellings to infer the intended words, and always write " +
                "correctly spelled text yourself.",
            "Match the writer's language, tone, and formatting. " + request.completionLengthInstruction
        ]
        if !request.isMultiLineEnabled {
            lines.append("Stay on the current line.")
        }
        if request.alternateCount > 0 {
            lines.append(
                "Then, on a new line, write \(alternateMarker) and up to \(request.alternateCount) meaningfully " +
                    "different alternative continuations, one per line, most likely first."
            )
        }
        if let name = nonEmpty(request.userName) {
            lines.append("The writer's name is \(name).")
        }
        let rules = request.customRules.compactMap(nonEmpty)
        if !rules.isEmpty {
            lines.append("Writing style: \(rules.joined(separator: "; ")).")
        }
        if let language = nonEmpty(request.languageInstruction) {
            lines.append(language)
        }
        if let notes = nonEmpty(request.extendedContext) {
            lines.append("Terms and notes the writer keeps in mind (spell these exactly): \(notes)")
        }
        return lines.joined(separator: "\n")
    }

    static func userPrompt(for request: SuggestionRequest, prefixScale: Double = 1.0) -> String {
        var blocks: [String] = []
        if let surface = request.surfaceContext {
            let lines = SurfaceContextComposer.prefaceLines(for: surface)
            if !lines.isEmpty {
                blocks.append("Writing surface: " + lines.joined(separator: " "))
            }
        }
        if let clip = nonEmpty(request.clipboardContext) {
            blocks.append("On the clipboard:\n\(clip)")
        }
        if let screen = nonEmpty(request.visualContextSummary) {
            blocks.append("Nearby on screen:\n\(screen)")
        }
        if let suffix = nonEmpty(request.suffixText) {
            blocks.append("Text after the caret (already written, do not repeat):\n\(suffix)")
        }

        let scale = min(max(prefixScale, 0.1), 1.0)
        let keptCount = max(1, Int((Double(request.prefixText.count) * scale).rounded(.up)))
        let prefix = String(request.prefixText.suffix(keptCount))
        let caretHint = prefix.last.map { $0.isWhitespace } == true
            ? "(the caret follows a space)"
            : "(the caret follows the last character shown)"
        blocks.append("Text before the caret \(caretHint):\n\(prefix)")
        return blocks.joined(separator: "\n\n")
    }

    private static func nonEmpty(_ text: String?) -> String? {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// How much surrounding text a cloud endpoint receives. Local engines are sized by their KV cache;
/// a hosted model with a 131k-token window is sized by latency and cost instead.
nonisolated enum CloudEndpointContextWindow: Equatable, Sendable {
    case standard
    case large

    var maxPrefixCharacters: Int {
        switch self {
        case .standard: return 4_000
        case .large: return 7_500
        }
    }

    var maxPrefixWords: Int {
        switch self {
        case .standard: return 700
        case .large: return 1_300
        }
    }

    static let maxSuffixCharacters = 600
}

/// Splits one streamed chat response into the primary continuation and its alternates.
///
/// The primary continuation streams straight into ghost text, so a partial must never leak the
/// marker or the alternates behind it. Alternates are only read once the stream finishes.
nonisolated enum AlternateCandidateSplitter {
    struct Split: Equatable, Sendable {
        let primary: String
        let alternates: [String]
    }

    static func primaryForPartial(_ cumulativeRaw: String) -> String {
        guard let markerRange = cumulativeRaw.range(of: EndpointChatPromptRenderer.alternateMarker) else {
            return withoutPartialMarker(cumulativeRaw)
        }
        return trimmingTrailingNewlines(String(cumulativeRaw[..<markerRange.lowerBound]))
    }

    static func split(_ raw: String, maxAlternates: Int) -> Split {
        guard let markerRange = raw.range(of: EndpointChatPromptRenderer.alternateMarker) else {
            return Split(primary: raw, alternates: [])
        }
        let primary = trimmingTrailingNewlines(String(raw[..<markerRange.lowerBound]))
        let alternates = raw[markerRange.upperBound...]
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != EndpointChatPromptRenderer.alternateMarker }
        var unique: [String] = []
        for alternate in alternates where !unique.contains(alternate) && alternate != primary.trimmingCharacters(in: .whitespaces) {
            unique.append(alternate)
            if unique.count == maxAlternates { break }
        }
        return Split(primary: primary, alternates: unique)
    }

    /// While streaming, the tail may hold the first few characters of the marker (`\n###A`).
    /// Holding them back for one more chunk keeps them out of the ghost text.
    private static func withoutPartialMarker(_ text: String) -> String {
        let marker = EndpointChatPromptRenderer.alternateMarker
        for length in stride(from: min(marker.count - 1, text.count), through: 1, by: -1)
            where text.hasSuffix(marker.prefix(length)) {
            return trimmingTrailingNewlines(String(text.dropLast(length)))
        }
        return text
    }

    private static func trimmingTrailingNewlines(_ text: String) -> String {
        var view = Substring(text)
        while let last = view.last, last.isNewline {
            view = view.dropLast()
        }
        return String(view)
    }
}
