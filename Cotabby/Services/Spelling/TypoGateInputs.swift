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
    /// How often the writer has written `second` right after `first` (their own sentences), so a fix
    /// that fits the writer's phrasing outranks one that only fits books.
    var personalPairCount: ((_ first: String, _ second: String) -> Int)?
    /// The n-gram table's likelihood of a word after the text before it (see
    /// `NextWordPredictor.contextScore`); up to three words of context against the bigrams' one.
    var sentenceContextScore: ((_ textBefore: String, _ word: String) -> Double)?
    /// The writer's own words (names, jargon) close to a misspelling; see `PersonalVocabulary`.
    var personalWords: ((_ typo: String) -> [PersonalVocabulary.Match])?
    /// The trained auto-fix judge; nil falls back to the score-and-margin rule.
    var autoFixModel: TreeEnsembleModel?
    /// The trained wrong-word judge for the sentence pass; nil falls back to the listed confusables.
    var wrongWordModel: TreeEnsembleModel?
    /// Set where the writer spells the American way: fixes come in that spelling (`neighbur` →
    /// `neighbor`, not `neighbour`). Nil leaves the ranker's choice alone.
    var americanSpellings: AmericanSpellings?
}

@MainActor
final class TypoGateInputs {
    /// A local answer this clear never costs a Jev call.
    private static let confidentScore = 0.85
    private static let confidentMargin = 0.3
    /// Mid-word, system guesses are only worth their cost from this many letters on.
    private static let nativeGuessMinimumMidWordLength = 6
    /// Real-word pairings this suspicious are worth asking Jev about even though they are not
    /// suspicious enough to flag locally.
    private static let jevRealWordRatio = 3.0
    private static let maximumJevOptions = 6
    /// How many of the ranker's candidates the trained model may reorder for a finished word.
    static let rerankPoolSize = 8

    private let dependencies: SpellingEngineDependencies
    private let precedingText: String
    private let textAfter: String
    private let previousWord: String?
    private var languageByWord: [String: SpellingDictionaryLanguage?] = [:]
    private var sourcesByWord: [String: SpellingCandidateSources] = [:]
    /// The evidence behind the last local ranking of each finished word, for `autoFixConfidence`.
    private var rankedByFinishedWord: [String: [RankedSpellingCandidate]] = [:]
    private var confidenceByFinishedWord: [String: Double] = [:]
    /// Lowercased personal word -> the casing the writer uses (`lindqvist` → Lindqvist).
    private var personalCasing: [String: String] = [:]
    private static let personalWordBaseLogCount = 8.0
    private static let personalWordLogCountPerUse = 0.25
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
        // A word joined to another by a dot or a slash (`users.nmae`) may be a name or an identifier:
        // the writer is shown a fix and decides. Nothing is changed for them there, not even a
        // capital, since a dot inside such a token is not the end of a sentence.
        if CurrentWordExtractor.extractTrailingWord(from: precedingText)?.result.isJoined == true {
            guard settings.offerTypoCorrections else { return .proceed }
            var offersOnly = TypoGate.Settings(
                suppressCompletionsOnTypo: settings.suppressCompletionsOnTypo, offerTypoCorrections: true, automaticallyFixTypos: false
            )
            offersOnly.choiceListMaximumMargin = settings.choiceListMaximumMargin
            offersOnly.singleOfferMinimumScore = settings.singleOfferMinimumScore
            offersOnly.midWordMinimumLength = settings.midWordMinimumLength
            let decision = TypoGate.resolve(
                precedingText: precedingText,
                settings: offersOnly,
                isTypo: isTypo,
                isWordInProgress: isWordInProgress,
                candidates: candidates(_:isMidWord:)
            )
            if case .suppress = decision { return .proceed }
            return decision
        }
        if let slip = caseSlipDecision(settings: settings) { return slip }
        let decision = TypoGate.resolve(
            precedingText: precedingText,
            settings: settings,
            isTypo: isTypo,
            isWordInProgress: isWordInProgress,
            candidates: candidates(_:isMidWord:),
            realWordCandidates: realWordCandidates,
            autoFixConfidence: autoFixConfidence
        )
        return settings.automaticallyFixTypos ? capitalizingIfNeeded(decision) : decision
    }

    /// A finished word with a Shift-key slip (`THe`, `kKing`): fixed by shape before the spell
    /// checker is asked, since it either accepts these or guesses at other words (see `CaseSlip`).
    private func caseSlipDecision(settings: TypoGate.Settings) -> TypoGateDecision? {
        guard settings.suppressCompletionsOnTypo, settings.automaticallyFixTypos || settings.offerTypoCorrections,
              let current = CurrentWordExtractor.extractTrailingWord(from: precedingText),
              current.trailingSpaceCount == 1 || !current.trailingPunctuation.isEmpty else { return nil }
        let word = current.result.word
        guard memory?.isKept(word) != true,
              let fix = CaseSlip.fix(for: word, isWord: { self.dependencies.symSpellCorrector.isDictionaryWord($0) }) else {
            return nil
        }
        if settings.automaticallyFixTypos, current.trailingSpaceCount == 1 {
            return .applyCorrection(word: word, correctedWord: fix)
        }
        return settings.offerTypoCorrections ? .offerCorrection(word: word, correctedWord: fix) : nil
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
        let rank = { (native: [String]) -> [SpellingCandidate] in
            let ranked = SpellingCandidateRanker.rankDetailed(
                word: word,
                isMidWord: isMidWord,
                sources: self.sources(for: word, isMidWord: isMidWord),
                native: native,
                personal: personal,
                contextCount: self.contextCount(for: word),
                personalContextCount: self.personalContextCount(),
                sentenceContextScore: self.sentenceContextScore(),
                limit: isMidWord ? SpellingCandidateRanker.maxCandidates : Self.rerankPoolSize
            )
            guard !isMidWord else {
                return self.inPreferredSpelling(ranked.map(self.inPersonalCasing)).map(\.candidate)
            }
            let ordered = self.inPreferredSpelling(self.orderedByModel(ranked, word: word).map(self.inPersonalCasing))
            self.rankedByFinishedWord[word] = ordered
            return ordered.prefix(SpellingCandidateRanker.maxCandidates).map(\.candidate)
        }
        // NSSpellChecker guesses cost 8–12 ms, most of a slow keystroke, and on a short fragment they
        // guess at a finished word that is not there yet. Mid-word the dictionary's prefix index
        // answers "which word is this becoming" in about a millisecond, so the system is asked only
        // once enough letters exist to name jargon the dictionary lacks (Kubernetes).
        if isMidWord, word.count < Self.nativeGuessMinimumMidWordLength {
            return rank([])
        }
        return rank(dependencies.spellChecker.nativeCorrections(for: word, language: language(for: word)?.rawValue))
    }

    /// The model's probability that the best fix for a just-ranked finished word is the intended
    /// word; nil when the score rule should decide instead (see `orderedByModel`).
    func autoFixConfidence(_ word: String) -> Double? {
        confidenceByFinishedWord[word]
    }

    /// Puts a finished word's candidates in the trained model's order and remembers its probability
    /// for the first one. The model is asked about each candidate in turn; eight candidates cost a
    /// few thousand comparisons, well under a tenth of a millisecond.
    ///
    /// Three cases keep the ranker's own order and the score rule, because the model's training rows
    /// had none of them: a fix from the certain-misspellings table, a word that is a name the system
    /// knows (`hungary` stays a choice between Hungary and hungry), and a fix this writer has
    /// already made twice, where their habit leads and the model has no say.
    private func orderedByModel(_ ranked: [RankedSpellingCandidate], word: String) -> [RankedSpellingCandidate] {
        confidenceByFinishedWord[word] = nil
        guard let model = dependencies.autoFixModel, let top = ranked.first, !top.signals.isKnownFix,
              !ranked.contains(where: { $0.signals.isProperNoun || $0.signals.personalAccepted >= SpellingCandidateRanker.habitLeadCount })
        else { return ranked }
        let capitalized = isCapitalizedMidSentence(word)
        let scored = ranked.indices.map { index -> (candidate: RankedSpellingCandidate, probability: Double) in
            (ranked[index], model.probability(features: AutoFixFeatures.vector(
                typo: word,
                ranked: ranked,
                index: index,
                capitalizedMidSentence: capitalized
            )))
        }
        // Stable: equal probabilities keep the ranker's order.
        let ordered = scored.enumerated().sorted { lhs, rhs in
            lhs.element.probability != rhs.element.probability
                ? lhs.element.probability > rhs.element.probability
                : lhs.offset < rhs.offset
        }
        confidenceByFinishedWord[word] = ordered.first?.element.probability
        return ordered.map(\.element.candidate)
    }

    /// A candidate that is one of the writer's own words keeps the capitals they write it with.
    private func inPersonalCasing(_ ranked: RankedSpellingCandidate) -> RankedSpellingCandidate {
        guard let cased = personalCasing[ranked.candidate.term.lowercased()] else { return ranked }
        return RankedSpellingCandidate(
            candidate: SpellingCandidate(term: cased, score: ranked.candidate.score),
            signals: ranked.signals
        )
    }

    /// Candidates in the spelling the writer uses (see `AmericanSpellings`). A British candidate
    /// becomes its American twin and keeps its place and evidence; if the twin was already listed
    /// lower, that entry is dropped, so the word is offered once.
    private func inPreferredSpelling(_ ranked: [RankedSpellingCandidate]) -> [RankedSpellingCandidate] {
        guard let spellings = dependencies.americanSpellings else { return ranked }
        var seen = Set<String>()
        return ranked.compactMap { entry in
            let term = spellings.american(for: entry.candidate.term) ?? entry.candidate.term
            guard seen.insert(term.lowercased()).inserted else { return nil }
            guard term != entry.candidate.term else { return entry }
            return RankedSpellingCandidate(
                candidate: SpellingCandidate(term: term, score: entry.candidate.score), signals: entry.signals
            )
        }
    }

    /// The model inputs for each candidate of a finished word ranked earlier in this cycle, in the
    /// order `rankedCandidates(forFinishedWord:)` returns them (training rows for `Tools/autofix`).
    func autoFixFeatures(_ word: String) -> [[Double]] {
        let ranked = rankedByFinishedWord[word] ?? []
        let capitalized = isCapitalizedMidSentence(word)
        return ranked.indices.map {
            AutoFixFeatures.vector(typo: word, ranked: ranked, index: $0, capitalizedMidSentence: capitalized)
        }
    }

    func rankedCandidates(forFinishedWord word: String) -> [RankedSpellingCandidate] {
        rankedByFinishedWord[word] ?? []
    }

    private func isCapitalizedMidSentence(_ word: String) -> Bool {
        guard word.first?.isUppercase == true else { return false }
        let before = (CurrentWordExtractor.textBeforeTrailingWord(in: precedingText) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = before.last else { return false }
        return !".!?".contains(last)
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
        if let trained = trainedRealWordCandidates(word, previous: previousWord) { return trained }
        let count: (String, String) -> Int64? = { bigrams.count(first: $0, second: $1) }
        var flagged = RealWordErrorDetector.candidates(word: word, previous: previousWord, count: count)
        // The word-pair counts see one previous word and split contractions (`think it's` looks
        // rare), so the n-gram sentence model has the last word: it vetoes a flag when the typed word
        // fits the sentence, and flags on its own when an alternative clearly fits better.
        if let score = sentenceContextScore() {
            let verdict = RealWordErrorDetector.sentenceVerdict(word: word, score: score)
            flagged = verdict.typedFits ? [] : (flagged.isEmpty ? verdict.flagged : flagged)
        }
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

    /// The trained wrong-word check for the word just finished at the caret: any real word, not only
    /// the listed confusables, judged from the words before it (nothing follows it yet, so the model's
    /// stricter caret threshold applies). Nil when the model or its inputs are unavailable, which
    /// leaves the listed-confusables rule in charge.
    private func trainedRealWordCandidates(_ word: String, previous: String) -> [SpellingCandidate]? {
        guard let model = dependencies.wrongWordModel, let threshold = model.caretThreshold,
              let sentenceScore = dependencies.sentenceContextScore,
              let sources = dependencies.symSpellCorrector.wrongWordSources() else { return nil }
        // Names are not wrong words.
        guard word != "I", !isCapitalizedMidSentence(word) else { return [] }
        let suspects = WrongWordDetector.suspects(
            for: word,
            sources: sources,
            position: WrongWordDetector.Position(
                textBefore: CurrentWordExtractor.textBeforeTrailingWord(in: precedingText) ?? "",
                previous: previous.lowercased(),
                next: nil,
                afterNext: nil,
                pairCount: { self.dependencies.bigrams?.count(first: $0, second: $1) },
                sentenceScore: sentenceScore
            ),
            model: model,
            threshold: threshold
        )
        // Scores stay in the wrong-word band (offered, never applied) like the listed-confusables rule.
        return suspects.map {
            SpellingCandidate(term: TypoCaseTransfer.applying(caseOf: word, to: $0.term), score: 0.55 + 0.25 * $0.probability)
        }
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
        var resolved = language(for: word).flatMap {
            dependencies.symSpellCorrector.candidates(for: word, language: $0, includePrefixMatches: isMidWord)
        } ?? .empty
        addPersonalWords(for: word, to: &resolved)
        // How often the two halves of a possible run-together word really follow each other.
        if !resolved.splits.isEmpty, let bigrams = englishBigrams(for: word) {
            resolved.splits = resolved.splits.map { split in
                var counted = split
                counted.pairCount = bigrams.count(first: split.first, second: split.second) ?? 0
                return counted
            }
        }
        sourcesByWord[key] = resolved
        return resolved
    }

    /// The writer's own words join the dictionary's as candidates, counted like very common words:
    /// a name this writer has written twice is likelier than a dictionary word they never use
    /// (`Lindqvsit` is Lindqvist, not Lundqvist).
    private func addPersonalWords(for word: String, to sources: inout SpellingCandidateSources) {
        guard let matches = dependencies.personalWords?(word), !matches.isEmpty else { return }
        let known = Set(sources.fullWord.map(\.term))
        for match in matches where !known.contains(match.word.lowercased()) {
            let logCount = Self.personalWordBaseLogCount + Self.personalWordLogCountPerUse * Double(min(match.uses, 8))
            sources.fullWord.append(SymSpellSuggestion(
                term: match.word.lowercased(),
                distance: match.distance,
                count: Int64(pow(10, logCount))
            ))
            personalCasing[match.word.lowercased()] = match.word
        }
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

    private func sentenceContextScore() -> ((String) -> Double)? {
        guard let score = dependencies.sentenceContextScore else { return nil }
        guard let textBefore = CurrentWordExtractor.textBeforeTrailingWord(in: precedingText),
              textBefore.contains(where: \.isLetter) else { return nil }
        return { score(textBefore, $0) }
    }

    private func personalContextCount() -> ((String) -> Int)? {
        guard let previousWord, let personal = dependencies.personalPairCount else { return nil }
        let first = previousWord.lowercased()
        return { personal(first, $0.lowercased()) }
    }
}

extension TypoGateInputs {
    /// The trained wrong-word check, when its model, the dictionary index, and the n-gram table are
    /// all available. A pairing the writer chose to keep (`memory.isKept("their house")`, the same key
    /// the caret-level check records) is never flagged again.
    static func wrongWordCheck(
        dependencies: SpellingEngineDependencies
    ) -> ((_ word: String, _ place: LocalSentenceProofreader.WordPlace) -> [String])? {
        guard let model = dependencies.wrongWordModel, let sentenceScore = dependencies.sentenceContextScore,
              let sources = dependencies.symSpellCorrector.wrongWordSources() else { return nil }
        return { word, place in
            if let previous = place.previous, dependencies.memory?.isKept("\(previous) \(word)") == true { return [] }
            guard dependencies.memory?.isKept(word) != true else { return [] }
            return WrongWordDetector.suspects(
                for: word,
                sources: sources,
                position: WrongWordDetector.Position(
                    textBefore: place.textBefore,
                    previous: place.previous?.lowercased(),
                    next: place.next?.lowercased(),
                    afterNext: place.afterNext?.lowercased(),
                    pairCount: { dependencies.bigrams?.count(first: $0, second: $1) },
                    sentenceScore: sentenceScore
                ),
                model: model
            ).map(\.term)
        }
    }

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
                let isCertain = TypoGate.isCertain(
                    top: top,
                    margin: margin,
                    confidence: inputs.autoFixConfidence(word),
                    settings: settings
                )
                return (ranked.prefix(3).map(\.term), isCertain)
            },
            pairCount: { first, second in dependencies.bigrams?.count(first: first, second: second) },
            sentenceScore: dependencies.sentenceContextScore,
            wrongWord: wrongWordCheck(dependencies: dependencies)
        )
    }
}
