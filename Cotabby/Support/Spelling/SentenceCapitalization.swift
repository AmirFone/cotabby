import Foundation

/// File overview:
/// The iPhone-style capitalization Cotabby applies as each word is finished: the first word of a
/// sentence (`hello` → `Hello`), and the pronoun `I` wherever it appears (`i`, `i'm`, `i've` →
/// `I`, `I'm`, `I've`). It edits only the word just finished, so it rides the same trailing-word
/// replacement as a typo fix and never rewrites earlier text.
nonisolated enum SentenceCapitalization {
    /// Words that end in a period without ending a sentence.
    static let abbreviations: Set<String> = [
        "e.g.", "i.e.", "etc.", "vs.", "mr.", "mrs.", "ms.", "dr.", "st.", "jr.", "sr.", "prof.",
        "approx.", "no.", "fig.", "inc.", "ltd.", "co.", "dept.", "est.", "a.m.", "p.m."
    ]

    /// The capitalized form of `word` given the text before it, or nil when it should stay as typed.
    /// - Parameter textBefore: everything before `word` (not including it).
    static func capitalized(_ word: String, textBefore: String) -> String? {
        guard let first = word.first, first.isLowercase else { return nil }
        let lowered = word.lowercased()
        if lowered == "i" || lowered.hasPrefix("i'") || lowered.hasPrefix("i’") {
            return "I" + word.dropFirst()
        }
        // Mixed-case tokens (iPhone, eBay) are names, not sentence starts to fix.
        guard !word.dropFirst().contains(where: \.isUppercase), isSentenceStart(textBefore) else { return nil }
        return first.uppercased() + word.dropFirst()
    }

    static func isSentenceStart(_ textBefore: String) -> Bool {
        let trimmedSpaces = textBefore.reversed().drop { $0 == " " || $0 == "\t" }
        guard let last = trimmedSpaces.first else { return true }
        if last.isNewline { return true }
        var tail = String(trimmedSpaces.reversed())
        // Closing quotes and brackets can follow the terminal mark: `He left." then`.
        while let character = tail.last, "\"'”’)]".contains(character) { tail.removeLast() }
        guard let terminal = tail.last, ".!?".contains(terminal) else { return false }
        if tail.hasSuffix("..") { return false }
        guard terminal == "." else { return true }
        let lastToken = tail.split(whereSeparator: \.isWhitespace).last.map { $0.lowercased() } ?? ""
        if abbreviations.contains(lastToken) { return false }
        // Initials and dotted acronyms: `J.`, `U.S.`
        let letters = lastToken.filter(\.isLetter)
        return letters.count > 1 && !lastToken.dropLast().contains(".")
    }
}
