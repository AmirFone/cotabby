import Foundation

/// File overview:
/// Pure decision rule for the typo gate that runs before each prediction. Extracted from
/// `SuggestionCoordinator` so the "suppress vs correct vs proceed" logic is unit-testable without
/// `NSSpellChecker` or a live AX snapshot: the coordinator passes the spell-check behaviors in as
/// closures, and tests pass deterministic stubs.
nonisolated enum TypoGateDecision: Equatable {
    /// No actionable typo on the current word. Proceed with a normal continuation.
    case proceed
    /// The current word looks misspelled and corrections are off (or none was available). Hide the
    /// continuation so completions never pile on top of a broken word, but show nothing.
    case suppress
    /// The current word looks misspelled and a correction is available. Offer it as a replace-the-word
    /// suggestion. `word` is the typo to replace; the accept path recomputes the edit from live text.
    case offerCorrection(word: String, correctedWord: String)
    /// The user finished a misspelled word with Space and enabled automatic fixing. Apply the edit
    /// immediately instead of creating an accept-key session.
    case applyCorrection(word: String, correctedWord: String)
    /// One clear best fix (shown as the green ghost) with runner-ups the writer can open with Down.
    case offerRankedCorrection(word: String, candidates: [SpellingCandidate])
    /// Several fixes are about equally likely: open the pick-list immediately.
    case offerChoices(word: String, candidates: [SpellingCandidate])
    /// A correctly spelled word that is probably the wrong word here (`went their`). Offered, never
    /// applied automatically.
    case offerRealWordFix(word: String, candidates: [SpellingCandidate])
}

enum TypoGate {
    /// The user settings that shape the gate decision, grouped so `resolve` takes one cohesive value
    /// instead of three loose Bools (which also keeps it within the parameter-count budget).
    struct Settings {
        let suppressCompletionsOnTypo: Bool
        let offerTypoCorrections: Bool
        let automaticallyFixTypos: Bool
        /// Auto-apply needs a top score at least this high...
        var autoApplyMinimumScore = Settings.baseAutoApplyMinimumScore
        /// ...and at least this far ahead of the runner-up, so "wich" (which/with) never auto-fixes.
        var autoApplyMinimumMargin = 0.4
        /// Below this gap between the top two, the writer picks from a list instead of a green ghost.
        var choiceListMaximumMargin = 0.15
        /// A top score under this is too unsure to present as a single suggestion.
        var singleOfferMinimumScore = 0.5
        /// With a trained model (`AutoFixConfidenceModel`), auto-apply instead needs this probability
        /// that the top fix is the intended word. Nil keeps the score-and-margin rule.
        var autoApplyMinimumConfidence: Double?
        /// Mid-word lists wait for enough letters to mean something.
        var midWordMinimumLength = 3

        static let baseAutoApplyMinimumScore = 1.12

        /// The auto-fix bar, raised for a writer who undoes auto-fixes: each undone fix already stops
        /// that one word from being fixed again, and a high undo rate says the engine's confident
        /// guesses are wrong for this writer more generally, so fewer should be applied unasked. Needs
        /// 20 auto-fixes before it moves, so a couple of early undos cannot swing it.
        /// The same adjustment for the trained model's probability threshold: a writer who undoes one
        /// auto-fix in ten needs the model about seven points surer, capped so some fixes always apply.
        static func adaptedAutoApplyMinimumConfidence(base: Double, autoApplied: Int, reverted: Int) -> Double {
            guard autoApplied >= 20 else { return base }
            let undoRate = Double(reverted) / Double(autoApplied)
            return min(0.98, base + min(0.15, max(0, undoRate - 0.03)))
        }

        static func adaptedAutoApplyMinimumScore(autoApplied: Int, reverted: Int) -> Double {
            guard autoApplied >= 20 else { return baseAutoApplyMinimumScore }
            let undoRate = Double(reverted) / Double(autoApplied)
            return baseAutoApplyMinimumScore + min(0.6, max(0, undoRate - 0.03) * 4)
        }
    }

    /// Resolves the gate decision for the trailing word of `precedingText`.
    ///
    /// `isTypo` and `bestCorrection` are injected so this stays pure: in production they wrap
    /// `CurrentWordSpellChecker`; in tests they are stubs. Automatic fixing takes precedence only
    /// after a literal trailing Space. Before that boundary the gate may offer a correction, but never
    /// mutates an unfinished word merely because the user paused.
    /// Confidence-tiered resolution.
    ///
    /// `isWordInProgress` answers "could this still become a correct word?" for a word the caret is
    /// inside; when it does, the gate proceeds so the model can finish the word from context.
    /// `candidates` returns ranked fixes (see `SpellingCandidateRanker`), best first.
    static func resolve(
        precedingText: String,
        settings: Settings,
        isTypo: (String) -> Bool,
        isWordInProgress: (String) -> Bool,
        candidates: (_ word: String, _ isMidWord: Bool) -> [SpellingCandidate],
        realWordCandidates: (_ word: String) -> [SpellingCandidate] = { _ in [] },
        autoFixConfidence: (_ word: String) -> Double? = { _ in nil }
    ) -> TypoGateDecision {
        guard settings.suppressCompletionsOnTypo,
              let current = CurrentWordExtractor.extractTrailingWord(from: precedingText) else {
            return .proceed
        }
        let word = current.result.word
        // Punctuation right after the word (`teh,`) finishes it just like a space does.
        let isMidWord = current.trailingSpaceCount == 0 && current.trailingPunctuation.isEmpty
        guard isTypo(word) else {
            // Real-word slips can only be judged once the word is finished.
            guard !isMidWord, settings.offerTypoCorrections else { return .proceed }
            let alternatives = realWordCandidates(word)
            return alternatives.isEmpty ? .proceed : .offerRealWordFix(word: word, candidates: alternatives)
        }
        if isMidWord, word.count < settings.midWordMinimumLength || isWordInProgress(word) {
            return .proceed
        }

        let ranked = candidates(word, isMidWord)
        guard let top = ranked.first else { return .suppress }
        guard settings.offerTypoCorrections || settings.automaticallyFixTypos else { return .suppress }

        let margin = ranked.count > 1 ? top.score - ranked[1].score : top.score
        if settings.automaticallyFixTypos, !isMidWord, current.trailingSpaceCount == 1,
           isCertain(top: top, margin: margin, confidence: autoFixConfidence(word), settings: settings) {
            return .applyCorrection(word: word, correctedWord: top.term)
        }
        guard settings.offerTypoCorrections else { return .suppress }
        if ranked.count > 1, margin < settings.choiceListMaximumMargin || top.score < settings.singleOfferMinimumScore {
            return .offerChoices(word: word, candidates: ranked)
        }
        if ranked.count > 1 {
            return .offerRankedCorrection(word: word, candidates: ranked)
        }
        return .offerCorrection(word: word, correctedWord: top.term)
    }

    /// Whether the top fix may be applied without asking. A model probability decides when there is
    /// one; otherwise the score must be high and well ahead of the runner-up.
    static func isCertain(top: SpellingCandidate, margin: Double, confidence: Double?, settings: Settings) -> Bool {
        if let confidence, let minimum = settings.autoApplyMinimumConfidence {
            return confidence >= minimum
        }
        return top.score >= settings.autoApplyMinimumScore && margin >= settings.autoApplyMinimumMargin
    }

    static func resolve(
        precedingText: String,
        settings: Settings,
        isTypo: (String) -> Bool,
        bestCorrection: (String) -> String?
    ) -> TypoGateDecision {
        guard settings.suppressCompletionsOnTypo else {
            return .proceed
        }
        // Tolerate one trailing space so a just-finished word remains actionable: automatic mode can
        // apply it, while offer mode can keep the green correction alive after Space.
        guard let current = CurrentWordExtractor.extractTrailingWord(from: precedingText) else {
            return .proceed
        }
        guard isTypo(current.result.word) else {
            return .proceed
        }
        guard let corrected = bestCorrection(current.result.word) else {
            return .suppress
        }
        if settings.automaticallyFixTypos, current.trailingSpaceCount == 1 {
            return .applyCorrection(word: current.result.word, correctedWord: corrected)
        }
        if settings.offerTypoCorrections {
            return .offerCorrection(word: current.result.word, correctedWord: corrected)
        }
        return .suppress
    }
}
