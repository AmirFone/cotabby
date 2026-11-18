import Foundation

/// File overview:
/// The iPhone-style capitalization Cotabby applies as each word is finished: the first word of a
/// sentence (`hello` → `Hello`), and the pronoun `I` wherever it appears (`i`, `i'm`, `i've` →
/// `I`, `I'm`, `I've`). It edits only the word just finished, so it rides the same trailing-word
/// replacement as a typo fix and never rewrites earlier text.
///
/// A capital is only added to an ordinary word. A command or a term whose real name is lowercase
/// (`kubectl`, `node-gyp`, `pwd`) is often the first thing on a line, and capitalizing it changes
/// text the writer typed correctly, which costs far more than a sentence that starts without its
/// capital. So a joined or code-like token is never capitalized, and the caller can name further
/// words to leave alone (the software terms and the writer's own words; see
/// `TypoGateInputs.capitalizingIfNeeded`).
nonisolated enum SentenceCapitalization {
    /// Words that end in a period without ending a sentence, with the forms written without their
    /// inner dots (`eg.`, `ie.`).
    ///
    /// This must hold every abbreviation in `SentenceBoundaryClassifier`, which answers the same
    /// question for phrase acceptance: a period that does not end a sentence there must not start
    /// one here. The two lists are separate only because that file is not compiled into the
    /// `cotabby-spell` tool, so an abbreviation added there has to be added here as well;
    /// `SentenceProofreadingTests` pins the ones it has today.
    static let abbreviations: Set<String> = [
        "e.g.", "i.e.", "eg.", "ie.", "etc.", "vs.", "cf.", "ex.", "al.", "min.", "max.",
        "mr.", "mrs.", "ms.", "dr.", "st.", "jr.", "sr.", "prof.",
        "approx.", "no.", "fig.", "inc.", "ltd.", "co.", "dept.", "est.", "a.m.", "p.m."
    ]

    /// Names of commands a software engineer types first on a line (`ls -la`, `pwd`, `kubectl get
    /// pods`). They are only ever written in lowercase, and a capital turns them into something
    /// that is not the command (`Ls`, `Pwd`). Only names that are not also ordinary English words:
    /// `make`, `cat`, `echo` and `touch` start real sentences far more often than command lines.
    static let commandNames: Set<String> = [
        "ls", "pwd", "cd", "mv", "cp", "rm", "ln", "df", "du", "ps", "awk", "sed", "grep", "git", "npm", "npx",
        "pnpm", "pip", "uv", "brew", "ssh", "scp", "sudo", "chmod", "chown", "mkdir", "rmdir", "kubectl",
        "docker", "cargo", "tar", "vim", "tmux", "jq", "psql", "rsync", "wget", "xargs", "gh", "ffmpeg"
    ]

    /// The capitalized form of `word` given the text before it, or nil when it should stay as typed.
    /// - Parameters:
    ///   - textBefore: everything before `word` (not including it).
    ///   - isLeftAsTyped: whether a lowercase word is right as it stands even where a sentence
    ///     starts. Not asked about the pronoun `I`, which is capitalized everywhere.
    static func capitalized(
        _ word: String,
        textBefore: String,
        isLeftAsTyped: (String) -> Bool = { _ in false }
    ) -> String? {
        guard let first = word.first, first.isLowercase else { return nil }
        let lowered = word.lowercased()
        if lowered == "i" || lowered.hasPrefix("i'") || lowered.hasPrefix("i’") {
            return "I" + word.dropFirst()
        }
        // Mixed-case tokens (iPhone, eBay) are names, not sentence starts to fix.
        guard !word.dropFirst().contains(where: \.isUppercase), !isCodeLike(word),
              isSentenceStart(textBefore), !isLeftAsTyped(word) else { return nil }
        return first.uppercased() + word.dropFirst()
    }

    /// A token joined by `-`, `.`, `/` or `_`, or with a digit in it: a package, a path, a flag or an
    /// identifier (`node-gyp`, `k-means`, `utf8`) far more often than an ordinary word.
    static func isCodeLike(_ word: String) -> Bool {
        word.contains { "-./_".contains($0) || $0.isNumber }
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
