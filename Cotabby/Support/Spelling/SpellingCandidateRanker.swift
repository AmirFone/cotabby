import Foundation

/// File overview:
/// Turns the raw evidence about a misspelled word into a short, confidence-scored candidate list.
///
/// Three independent sources vote: SymSpell whole-word corrections (edit distance plus corpus
/// frequency), SymSpell prefix matches for a word still being typed, and `NSSpellChecker`'s own
/// ranked guesses (which know phonetics and the user's learned words). The writer's own history of
/// accepted fixes adds a fourth vote, which is how the list learns one person's recurring
/// misspellings. The ranker is pure so the confidence tiers in `TypoGate` can be tested with
/// hand-built evidence instead of live dictionaries.

/// The dictionary evidence for one word, gathered by `SymSpellCorrector`.
nonisolated struct SpellingCandidateSources: Equatable, Sendable {
    let fullWord: [SymSpellSuggestion]
    let prefix: [SymSpellPrefixMatch]
    /// A common word starts with these letters, so the writer may simply not be finished.
    let isCommonWordPrefix: Bool
    /// Common words that sound like the typo (`enuf` → enough), however many letters differ.
    var phonetic: [SymSpellPhoneticMatch] = []

    static let empty = SpellingCandidateSources(fullWord: [], prefix: [], isCommonWordPrefix: false)
}

extension SymSpellSuggestion: @unchecked Sendable {}
extension SymSpellPhoneticMatch: @unchecked Sendable {}
extension SymSpellPrefixMatch: @unchecked Sendable {}

/// One ranked replacement. `score` is comparable only within the same ranking call.
nonisolated struct SpellingCandidate: Equatable, Sendable {
    let term: String
    let score: Double
}

nonisolated enum SpellingCandidateRanker {
    static let maxCandidates = 4
    static let knownFixLead = 0.3
    /// Sound-alikes with less spelling in common than this are coincidences, not intent.
    static let minimumPhoneticSimilarity = 0.62

    /// - Parameters:
    ///   - word: the typo as it appears in the field (its case is copied onto every candidate).
    ///   - isMidWord: the caret is still inside the word, so prefix matches may complete it.
    ///   - native: `NSSpellChecker` guesses, best first.
    ///   - personal: how many times the writer previously accepted each replacement for this typo.
    ///   - contextCount: how often a candidate follows the previous word (see `BigramContextModel`);
    ///     nil when there is no previous word or the model is still loading.
    static func rank(
        word: String,
        isMidWord: Bool,
        sources: SpellingCandidateSources,
        native: [String],
        personal: [String: Int],
        contextCount: ((String) -> Int64?)? = nil
    ) -> [SpellingCandidate] {
        let lowered = word.lowercased()
        var evidence = dictionaryEvidence(for: lowered, isMidWord: isMidWord, sources: sources)
        addNativeEvidence(native, typo: lowered, into: &evidence)
        // A known misspelling (`dont`, `enuf`) is unambiguous, so it leads by more than the auto-apply margin.
        let contraction = KnownMisspellings.fix(for: word).map { SpellingCandidate(term: $0, score: 1.5) }
        guard !evidence.isEmpty else { return contraction.map { [$0] } ?? [] }

        let context = ScoringContext(
            dictionaryBest: isMidWord ? nil : uncontestedDictionaryBest(sources.fullWord, excluding: lowered),
            shortWordPenalty: lowered.count <= 3 ? 0.85 : 1.0,
            isMidWord: isMidWord,
            personal: personal,
            contextBoosts: contextBoosts(for: Array(evidence.keys), contextCount: contextCount)
        )
        let scored = evidence.map { term, item in
            SpellingCandidate(
                term: TypoCaseTransfer.applying(caseOf: word, to: term),
                score: score(term: term, item: item, context: context) * firstLetterFactor(typo: lowered, term: term, item: item)
            )
        }

        let contractionKey = contraction?.term.lowercased()
        let others = scored
            .filter { $0.term.lowercased() != contractionKey }
            .sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.term < rhs.term
            }
        // A known fix always leads by more than the auto-apply margin, whatever the others scored.
        let known = contraction.map {
            SpellingCandidate(term: $0.term, score: max($0.score, (others.first?.score ?? 0) + knownFixLead))
        }
        return Array(((known.map { [$0] } ?? []) + others).prefix(maxCandidates))
    }

    private struct ScoringContext {
        let dictionaryBest: String?
        let shortWordPenalty: Double
        let isMidWord: Bool
        let personal: [String: Int]
        let contextBoosts: [String: Double]
    }

    private static func dictionaryEvidence(
        for lowered: String,
        isMidWord: Bool,
        sources: SpellingCandidateSources
    ) -> [String: Evidence] {
        var evidence: [String: Evidence] = [:]
        for suggestion in sources.fullWord where suggestion.term != lowered && !suggestion.term.contains(" ") {
            let weight = suggestion.distance <= 1 ? 1.0 : 0.7
            evidence[suggestion.term, default: Evidence()].absorb(weight: weight, count: suggestion.count)
        }
        for match in sources.phonetic where match.term != lowered && match.similarity >= minimumPhoneticSimilarity {
            // Sounding right and looking close is the dyslexic signature: `enuf` ~ enough (0.78),
            // while a same-sound word with little spelling in common (`enuf` ~ unify) stays low.
            let weight = 0.35 + 0.6 * match.similarity
            evidence[match.term, default: Evidence()].absorb(weight: weight, count: match.count)
            evidence[match.term]?.soundSimilarity = match.similarity
        }
        guard isMidWord else { return evidence }
        for match in sources.prefix where match.term != lowered {
            // A completion of what was typed, or of it with two letters swapped, is strong
            // evidence; a wrong or missing letter is weaker because the rest of the word is unknown.
            let weight: Double = switch match.halfEditDistance {
            case 0, 1: 0.9
            case 2: 0.75
            case 3: 0.6
            default: 0.45
            }
            evidence[match.term, default: Evidence()].absorb(weight: weight, count: match.count)
        }
        return evidence
    }

    private static func addNativeEvidence(_ native: [String], typo lowered: String, into evidence: inout [String: Evidence]) {
        let nativeTerms = native
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.lowercased() != lowered }
        for (position, guess) in nativeTerms.enumerated() {
            let key = guess.lowercased()
            if key.contains(" ") {
                // Only a split of exactly the typed letters (`alot` -> `a lot`, `infact` -> `in fact`)
                // is kept: run-together words are a common slip, while other multi-word guesses are noise.
                guard key.replacingOccurrences(of: " ", with: "") == lowered else { continue }
                // Common run-togethers (`alot`, `infact`) are in `KnownMisspellings`; a system split
                // of anything else (`stayshun` → "stay shun") is a weak guess, not a fix.
                evidence[key] = Evidence(nativeOnlyWeight: 0.6)
            }
            // Without dictionary evidence (index still loading, or a language with no bundled
            // dictionary) the system's first guess is the only strong signal, so it must be able to
            // stand alone; later guesses fall off quickly.
            let nativeOnlyWeight = position == 0 ? 0.7 : max(0.2, 0.45 - 0.05 * Double(position))
            var item = evidence[key] ?? Evidence(nativeOnlyWeight: nativeOnlyWeight)
            item.nativePosition = min(item.nativePosition ?? position, position)
            evidence[key] = item
        }
    }

    private static func score(term: String, item: Evidence, context: ScoringContext) -> Double {
        var score = item.logCount.map {
            item.distanceWeight * (0.6 + 0.4 * frequencyShare(logCount: $0)) * context.shortWordPenalty
        } ?? item.nativeOnlyWeight
        // Half a word does not sound like anything yet, so only finished words get the sound bonus.
        if let similarity = item.soundSimilarity, !context.isMidWord {
            // Sounding the same and looking close is the dyslexic signature, and it outranks a word
            // that is one letter off but sounds different: `elefant` is elephant, not elegant.
            score += 0.3 * max(0, (similarity - 0.7) / 0.3)
        }
        if let position = item.nativePosition {
            score += position == 0 ? 0.15 : 0.05
            // Two independent sources naming the same single best word is the strongest signal
            // available without context.
            if position == 0, term == context.dictionaryBest {
                score += 0.15
            }
        }
        if let accepted = context.personal[term], accepted > 0 {
            score += min(0.3, 0.12 * Double(accepted))
        }
        return score + (context.contextBoosts[term] ?? 0) * max(item.distanceWeight, item.logCount == nil ? 0.7 : 0)
    }

    /// Context is comparative: the candidate that most often follows the previous word gains
    /// `maximumContextBoost` (scaled by how close its spelling is, so a common pairing cannot drag a
    /// two-edit word past a one-edit fix: `left thier` stays `their`, not `the`), and a candidate about
    /// thirty times rarer after it gains nothing. `know wich` has
    /// `know which` seven times more often than `know with`, which outweighs `with` being the more
    /// common word overall. Pairs missing from the list count as a floor of one million.
    static let maximumContextBoost = 0.35
    static let contextSpanDecades = 1.5

    private static func contextBoosts(for terms: [String], contextCount: ((String) -> Int64?)?) -> [String: Double] {
        guard let contextCount else { return [:] }
        var logs: [String: Double] = [:]
        for term in terms {
            guard let first = term.split(separator: " ").first, let count = contextCount(String(first)) else { return [:] }
            logs[term] = log10(Double(max(count, 1_000_000)))
        }
        guard let best = logs.values.max(), best > 6 else { return [:] }
        return logs.mapValues { maximumContextBoost * max(0, 1 - (best - $0) / contextSpanDecades) }
    }

    /// Writers, dyslexic ones included, almost always get the first letter right or swap the first
    /// two, so a fix that changes the first letter (`oshun` → shun, `tords` → words) is discounted.
    /// Sound-alikes are exempt: `fone` → phone and `nolege` → knowledge change it on purpose.
    private static func firstLetterFactor(typo: String, term: String, item: Evidence) -> Double {
        guard let typoFirst = typo.first, let termFirst = term.first, typoFirst != termFirst, !item.soundsAlike else {
            return 1
        }
        let typoChars = Array(typo), termChars = Array(term)
        let swappedOpening = typoChars.count > 1 && termChars.count > 1
            && typoChars[0] == termChars[1] && typoChars[1] == termChars[0]
        return swappedOpening ? 1 : 0.75
    }

    /// Corpus frequency on a fixed log scale (about 1,000 to 10 billion occurrences), so a candidate's
    /// score does not depend on which other candidates happened to be found.
    private static func frequencyShare(logCount: Double) -> Double {
        min(max((logCount - 3) / 7, 0), 1)
    }

    /// The dictionary's best whole-word fix, unless another word at the same edit distance is at
    /// least a tenth as common. `wich` has `with` and `which` both one edit away, so neither is
    /// uncontested; `tommorow` has only `tomorrow`.
    private static func uncontestedDictionaryBest(_ suggestions: [SymSpellSuggestion], excluding typo: String) -> String? {
        let candidates = suggestions.filter { $0.term != typo }
        guard let best = candidates.first else { return nil }
        let contested = candidates.dropFirst().contains {
            $0.distance == best.distance && Double($0.count) >= Double(best.count) * 0.1
        }
        return contested ? nil : best.term
    }

    private struct Evidence {
        var distanceWeight = 0.0
        var logCount: Double?
        var nativeOnlyWeight = 0.0
        var nativePosition: Int?
        /// Spelling similarity of a common word that sounds like the typo; nil when it does not.
        var soundSimilarity: Double?
        var soundsAlike: Bool { soundSimilarity != nil }

        init() {}

        init(nativeOnlyWeight: Double) {
            self.nativeOnlyWeight = nativeOnlyWeight
        }

        mutating func absorb(weight: Double, count: Int64) {
            distanceWeight = max(distanceWeight, weight)
            let log = log10(Double(max(count, 1)))
            logCount = max(logCount ?? log, log)
        }
    }
}
