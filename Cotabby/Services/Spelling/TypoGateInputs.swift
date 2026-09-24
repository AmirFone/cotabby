import Foundation

/// File overview:
/// Everything the typo gate needs to know about the word at the caret, gathered for one prediction
/// cycle: is it misspelled, what could it be, does the previous word make one fix likelier, and has
/// Jev already ruled on it. Lookups are memoized per cycle because the gate asks about the same word
/// several times.
///
/// It depends only on `SpellingEngineDependencies`, not on the suggestion coordinator, so the
/// `cotabby-spell` command-line harness runs exactly the code the app runs.
@MainActor
struct SpellingEngineDependencies {
    let spellChecker: CurrentWordSpellChecker
    let symSpellCorrector: SymSpellCorrector
    let languageResolver: SpellingLanguageResolver
    let enabledLanguages: () -> [SpellingDictionaryLanguage]
    let memory: PersonalCorrectionMemory?
    let bigrams: BigramContextModel?
    let refiner: WordIntentRefiner?
}

@MainActor
final class TypoGateInputs {
    /// A local answer this clear never costs a Jev call.
    private static let confidentScore = 0.85
    private static let confidentMargin = 0.3
    /// Real-word pairings this suspicious are worth asking Jev about even though they are not
    /// suspicious enough to flag locally.
    private static let jevRealWordRatio = 3.0
    private static let maximumJevOptions = 6

    private let dependencies: SpellingEngineDependencies
    private let precedingText: String
    private let textAfter: String
    private let previousWord: String?
    private var languageByWord: [String: SpellingDictionaryLanguage?] = [:]
    private var sourcesByWord: [String: SpellingCandidateSources] = [:]
    /// True once any answer in this cycle came from a Jev verdict rather than local evidence.
    private(set) var usedJevVerdict = false

    init(dependencies: SpellingEngineDependencies, precedingText: String, textAfter: String) {
        self.dependencies = dependencies
        self.precedingText = precedingText
        self.textAfter = textAfter
        previousWord = CurrentWordExtractor.wordBeforeTrailingWord(in: precedingText)
    }

    private var memory: PersonalCorrectionMemory? { dependencies.memory }
    private var refiner: WordIntentRefiner? { dependencies.refiner }

    func decide(settings: TypoGate.Settings) -> TypoGateDecision {
        let decision = TypoGate.resolve(
            precedingText: precedingText,
            settings: settings,
            isTypo: isTypo,
            isWordInProgress: isWordInProgress,
            candidates: candidates(_:isMidWord:),
            realWordCandidates: realWordCandidates
        )
        return settings.automaticallyFixTypos ? capitalizingIfNeeded(decision) : decision
    }

    /// Folds sentence-start and `I` capitalization into the decision for a just-finished word, so a
    /// typo at the start of a sentence becomes `The` in one edit rather than `the` and then `The`.
    private func capitalizingIfNeeded(_ decision: TypoGateDecision) -> TypoGateDecision {
        guard let current = CurrentWordExtractor.extractTrailingWord(from: precedingText),
              current.trailingSpaceCount == 1 else {
            return decision
        }
        let word = current.result.word
        let before = CurrentWordExtractor.textBeforeTrailingWord(in: precedingText) ?? ""
        switch decision {
        case let .applyCorrection(typo, fix):
            return .applyCorrection(word: typo, correctedWord: SentenceCapitalization.capitalized(fix, textBefore: before) ?? fix)
        case .proceed:
            guard let capitalized = SentenceCapitalization.capitalized(word, textBefore: before) else { return decision }
            return .applyCorrection(word: word, correctedWord: capitalized)
        default:
            return decision
        }
    }

    func isTypo(_ word: String) -> Bool {
        guard memory?.isKept(word) != true else { return false }
        // `cant` and `thats` pass the system checker but are almost always a dropped apostrophe;
        // every `KnownMisspellings` key is a non-word or near-certain slip.
        if KnownMisspellings.fix(for: word) != nil { return true }
        return dependencies.spellChecker.isTypo(word, language: language(for: word)?.rawValue)
    }

    func isWordInProgress(_ word: String) -> Bool {
        sources(for: word, isMidWord: true).isCommonWordPrefix
    }

    func candidates(_ word: String, isMidWord: Bool) -> [SpellingCandidate] {
        let personal = memory?.acceptedReplacements(for: word) ?? [:]
        if let verdict = refiner?.verdict(for: jevKey(for: word)) {
            let mapped = WordIntentVerdictMapper.candidates(from: verdict, typedWord: word, personal: personal)
            if !mapped.candidates.isEmpty {
                usedJevVerdict = true
                return mapped.candidates
            }
        }
        return SpellingCandidateRanker.rank(
            word: word,
            isMidWord: isMidWord,
            sources: sources(for: word, isMidWord: isMidWord),
            native: dependencies.spellChecker.nativeCorrections(for: word, language: language(for: word)?.rawValue),
            personal: personal,
            contextCount: contextCount(for: word)
        )
    }

    func realWordCandidates(_ word: String) -> [SpellingCandidate] {
        guard let previousWord, let bigrams = englishBigrams(for: word),
              memory?.isKept(realWordKeepKey(for: word)) != true else {
            return []
        }
        if let verdict = refiner?.verdict(for: jevKey(for: word)) {
            let mapped = WordIntentVerdictMapper.candidates(from: verdict, typedWord: word, personal: [:])
            guard (mapped.typedProbability ?? 1) < 0.5 else { return [] }
            usedJevVerdict = true
            return mapped.candidates.filter { $0.score >= 0.3 }
        }
        let count: (String, String) -> Int64? = { bigrams.count(first: $0, second: $1) }
        let flagged = RealWordErrorDetector.candidates(word: word, previous: previousWord, count: count)
        if flagged.isEmpty, refiner?.isAvailable == true {
            let suspicious = RealWordErrorDetector.candidates(
                word: word,
                previous: previousWord,
                minimumRatio: Self.jevRealWordRatio,
                count: count
            )
            if !suspicious.isEmpty {
                requestJevVerdict(typo: word, candidates: suspicious, includesTypedWord: true)
            }
        }
        return flagged
    }

    func realWordKeepKey(for word: String) -> String {
        previousWord.map { "\($0) \(word)" } ?? word
    }

    /// Asks Jev to choose, unless the local answer is already clear or there is nothing to choose.
    func requestJevVerdict(typo: String, candidates: [SpellingCandidate], includesTypedWord: Bool) {
        guard let refiner, refiner.isAvailable else { return }
        if !includesTypedWord {
            guard candidates.count > 1 else { return }
            let margin = candidates[0].score - candidates[1].score
            if candidates[0].score >= Self.confidentScore, margin >= Self.confidentMargin { return }
        }
        refiner.request(JevWordIntentRequest(
            typedWord: typo,
            textBefore: textBefore(word: typo),
            textAfter: textAfter,
            options: candidates.prefix(Self.maximumJevOptions).map { $0.term.lowercased() },
            includesTypedWord: includesTypedWord
        ))
    }

    // MARK: - Lookups

    private func jevKey(for word: String) -> WordIntentRefiner.Key {
        WordIntentRefiner.Key(word: word, textBefore: textBefore(word: word))
    }

    private func textBefore(word: String) -> String {
        CurrentWordExtractor.textBeforeTrailingWord(in: precedingText) ?? precedingText
    }

    private func language(for word: String) -> SpellingDictionaryLanguage? {
        if let cached = languageByWord[word] { return cached }
        let resolved = dependencies.languageResolver.resolve(
            precedingText: precedingText,
            currentWord: word,
            enabledLanguages: dependencies.enabledLanguages()
        )
        languageByWord[word] = resolved
        return resolved
    }

    private func sources(for word: String, isMidWord: Bool) -> SpellingCandidateSources {
        let key = "\(isMidWord)|\(word)"
        if let cached = sourcesByWord[key] { return cached }
        let resolved = language(for: word).flatMap {
            dependencies.symSpellCorrector.candidates(for: word, language: $0, includePrefixMatches: isMidWord)
        } ?? .empty
        sourcesByWord[key] = resolved
        return resolved
    }

    /// The bigram list is English, so context only applies when the word resolved to English.
    private func englishBigrams(for word: String) -> BigramContextModel? {
        guard language(for: word) == .english else { return nil }
        return dependencies.bigrams
    }

    private func contextCount(for word: String) -> ((String) -> Int64?)? {
        guard let previousWord, let bigrams = englishBigrams(for: word) else { return nil }
        return { bigrams.count(first: previousWord, second: $0) }
    }
}

extension TypoGateInputs {
    /// A leftover typo is only worth a suggestion when its best fix scores at least this well.
    static let sentenceSuggestionMinimumScore = 0.9

    /// The sentence pass's view of the same engine: a word elsewhere in the sentence is judged exactly
    /// as if the caret were right after it, so the tiers match what the writer sees while typing.
    static func sentenceChecks(
        dependencies: SpellingEngineDependencies,
        settings: TypoGate.Settings
    ) -> LocalSentenceProofreader.Checks {
        LocalSentenceProofreader.Checks(
            isTypo: { word in
                TypoGateInputs(dependencies: dependencies, precedingText: word + " ", textAfter: "").isTypo(word)
            },
            fix: { word, textBefore in
                let inputs = TypoGateInputs(dependencies: dependencies, precedingText: textBefore + word + " ", textAfter: "")
                let ranked = inputs.candidates(word, isMidWord: false)
                guard let top = ranked.first, top.score >= sentenceSuggestionMinimumScore else { return nil }
                let margin = ranked.count > 1 ? top.score - ranked[1].score : top.score
                let isCertain = top.score >= settings.autoApplyMinimumScore && margin >= settings.autoApplyMinimumMargin
                return (ranked.prefix(3).map(\.term), isCertain)
            },
            pairCount: { first, second in dependencies.bigrams?.count(first: first, second: second) }
        )
    }
}
