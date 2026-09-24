import AppKit
import Foundation

/// File overview:
/// Thin wrapper around `NSSpellChecker` for the typo gate. We isolate the AppKit dependency here so
/// the prediction pipeline depends on a focused, testable surface rather than `NSSpellChecker`
/// directly, and so the spell document tag is owned in exactly one place.
///
/// Why native spell-check (not the LLM) for both detection and correction:
/// - Detection must be deterministic and cheap; it is the same engine the system underlines with.
/// - The Open Source path drives a base model that does not follow instruction prompts, so an
///   LLM "give me the corrected word" prompt is unreliable there. The native ranked guesses are
///   instant, offline, and good enough for single-word spelling fixes.
///
/// Known limit, by design: `NSSpellChecker` only flags non-words, so real-word errors (`their` vs
/// `there`) are never detected. That is out of scope here.
@MainActor
final class CurrentWordSpellChecker {
    /// Document tag identifies our "spell session" inside `NSSpellChecker.shared`. A unique tag
    /// avoids cross-contamination with whatever spellcheck state other apps have armed.
    private let documentTag: Int
    /// `NSSpellChecker` costs up to ~15 ms per call and the typo gate asks about the same word on
    /// every keystroke and every re-evaluation, so answers are memoized per language. Bounded and
    /// cleared wholesale; a word the writer teaches the system mid-session is picked up after that.
    private var typoCache: [String: Bool] = [:]
    private var guessCache: [String: [String]] = [:]
    private static let cacheLimit = 4_096

    init() {
        documentTag = NSSpellChecker.uniqueSpellDocumentTag()
        // We deliberately do not mutate `NSSpellChecker.shared` (e.g. forcing
        // `automaticallyIdentifiesLanguages`): that flag is app-global shared state, and overriding
        // it here would silently change behavior for any future text-checking context. We pass
        // `language: nil` on every call instead, which respects the shared checker's existing
        // language configuration (the user's system spelling preference, which already enables
        // automatic-by-language detection by default on modern macOS).
    }

    /// Returns true when `NSSpellChecker` considers the entire word misspelled. We require the
    /// returned range to start at offset 0 and cover the whole word; otherwise we would misfire on
    /// tokens like `I'm` where only part of the token is flagged, and on tokens that carry trailing
    /// punctuation (`nmae,`) where the flagged range stops short of the punctuation.
    ///
    /// `language` pins the check to one language. With `nil`, macOS accepts a word that is valid in
    /// *any* of the user's enabled spelling languages, and a Mac with many enabled languages then
    /// waves through `teh` (valid elsewhere), `wich`, and `adress`. Callers pass the language they
    /// detected from the surrounding text whenever they have one.
    func isTypo(_ word: String, language: String? = nil) -> Bool {
        guard !word.isEmpty else { return false }
        let key = (language ?? "*") + "|" + word
        if let cached = typoCache[key] { return cached }
        let result = uncachedIsTypo(word, language: language)
        if typoCache.count >= Self.cacheLimit { typoCache.removeAll(keepingCapacity: true) }
        typoCache[key] = result
        return result
    }

    private func uncachedIsTypo(_ word: String, language: String?) -> Bool {
        let misspelledRange = NSSpellChecker.shared.checkSpelling(
            of: word,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: documentTag,
            wordCount: nil
        )
        guard misspelledRange.location == 0 else {
            return false
        }
        return misspelledRange.length == (word as NSString).length
    }

    /// `NSSpellChecker`'s own ranked corrections for the word (best first), or an empty array when it
    /// has nothing to offer.
    func nativeCorrections(for word: String, language: String? = nil) -> [String] {
        let key = (language ?? "*") + "|" + word
        if let cached = guessCache[key] { return cached }
        let fullRange = NSRange(location: 0, length: (word as NSString).length)
        let guesses = NSSpellChecker.shared.guesses(
            forWordRange: fullRange,
            in: word,
            language: language,
            inSpellDocumentWithTag: documentTag
        )
        if guessCache.count >= Self.cacheLimit { guessCache.removeAll(keepingCapacity: true) }
        guessCache[key] = guesses ?? []
        return guesses ?? []
    }

    /// The single instant correction to offer for `word`: the top native guess that is a different
    /// single word, recased to match the typo's capitalization. `nil` when there is no usable guess.
    func bestCorrection(for word: String) -> String? {
        let candidate = nativeCorrections(for: word)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { candidate in
                !candidate.isEmpty
                    && candidate.lowercased() != word.lowercased()
                    // Single-word fixes only: a guess containing a space would change the field's
                    // word count and break the one-word-replace delete math on accept.
                    && !candidate.contains(" ")
            }
        guard let candidate else {
            return nil
        }
        return TypoCaseTransfer.applying(caseOf: word, to: candidate)
    }
}
