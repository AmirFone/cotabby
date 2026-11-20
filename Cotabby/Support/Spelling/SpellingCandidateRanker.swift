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
    var fullWord: [SymSpellSuggestion]
    let prefix: [SymSpellPrefixMatch]
    /// A common word starts with these letters, so the writer may simply not be finished.
    let isCommonWordPrefix: Bool
    /// Common words that sound like the typo (`enuf` → enough), however many letters differ.
    var phonetic: [SymSpellPhoneticMatch] = []
    /// Ways to read a finished word as two common words run together.
    var splits: [SymSpellSplit] = []

    static let empty = SpellingCandidateSources(fullWord: [], prefix: [], isCommonWordPrefix: false)
}

extension SymSpellSuggestion: @unchecked Sendable {}
extension SymSpellPhoneticMatch: @unchecked Sendable {}
extension SymSpellPrefixMatch: @unchecked Sendable {}
extension SymSpellSplit: @unchecked Sendable {}

/// One ranked replacement. `score` is comparable only within the same ranking call.
nonisolated struct SpellingCandidate: Equatable, Sendable {
    let term: String
    let score: Double
}

/// What the ranker weighed for one candidate. The score folds these into one number for ordering;
/// `AutoFixConfidence` reads them separately to judge whether the top fix is safe to apply unasked.
nonisolated struct SpellingCandidateSignals: Equatable, Sendable {
    /// Spelling closeness from the dictionary sources (1 = one edit, 0.7 = two, lower = sound-alike only).
    var distanceWeight = 0.0
    /// log10 of the corpus count; nil when only the system checker named the word.
    var logCount: Double?
    var nativePosition: Int?
    var soundSimilarity: Double?
    var soundsIdentical = false
    /// The sound match is one slip off rather than exact (see `SymSpellPhoneticMatch.isApproximate`).
    var soundIsApproximate = false
    /// From the certain-misspellings table.
    var isKnownFix = false
    /// The typed letters with the system checker's capitals (`walmart` → Walmart): the word may be
    /// a correctly spelled name rather than a typo.
    var isProperNoun = false
    var personalAccepted = 0
    var personalContext = 0
    /// For a two-word reading of a run-together word: log10 of one plus how often the halves follow
    /// each other, and log10 of the rarer half's count. Nil for ordinary candidates.
    var splitPairLog: Double?
    var splitMinimumLogCount: Double?
    /// log10 of how often the candidate follows the previous word (floored at 6); nil without context.
    var pairLogCount: Double?
    /// The n-gram table's likelihood of the candidate after the sentence so far; nil without context.
    var sentenceScore: Double?
}

nonisolated struct RankedSpellingCandidate: Equatable, Sendable {
    let candidate: SpellingCandidate
    let signals: SpellingCandidateSignals
}

nonisolated enum SpellingCandidateRanker {
    static let maxCandidates = 4
    static let knownFixLead = 0.45
    /// Score of a two-word reading of a run-together word, and of one whose halves are a known pair.
    static let splitWeight = 0.6
    static let splitKnownPairWeight = 0.9
    /// Sound-alikes with less spelling in common than this are coincidences, not intent.
    static let minimumPhoneticSimilarity = 0.62

    /// - Parameters:
    ///   - word: the typo as it appears in the field (its case is copied onto every candidate).
    ///   - isMidWord: the caret is still inside the word, so prefix matches may complete it.
    ///   - native: `NSSpellChecker` guesses, best first.
    ///   - personal: how many times the writer previously accepted each replacement for this typo.
    ///   - contextCount: how often a candidate follows the previous word (see `BigramContextModel`);
    ///     nil when there is no previous word or the model is still loading.
    ///   - personalContextCount: how often the writer wrote a candidate after the previous word in
    ///     their own finished sentences (see `PersonalPhraseModel`).
    static func rank(
        word: String,
        isMidWord: Bool,
        sources: SpellingCandidateSources,
        native: [String],
        personal: [String: Int],
        contextCount: ((String) -> Int64?)? = nil,
        personalContextCount: ((String) -> Int)? = nil,
        sentenceContextScore: ((String) -> Double)? = nil
    ) -> [SpellingCandidate] {
        rankDetailed(
            word: word,
            isMidWord: isMidWord,
            sources: sources,
            native: native,
            personal: personal,
            contextCount: contextCount,
            personalContextCount: personalContextCount,
            sentenceContextScore: sentenceContextScore
        ).map(\.candidate)
    }

    /// `rank` with the evidence behind each candidate kept alongside it.
    static func rankDetailed(
        word: String,
        isMidWord: Bool,
        sources: SpellingCandidateSources,
        native: [String],
        personal: [String: Int],
        contextCount: ((String) -> Int64?)? = nil,
        personalContextCount: ((String) -> Int)? = nil,
        sentenceContextScore: ((String) -> Double)? = nil,
        limit: Int = maxCandidates
    ) -> [RankedSpellingCandidate] {
        let lowered = word.lowercased()
        var evidence = dictionaryEvidence(for: lowered, isMidWord: isMidWord, sources: sources)
        addNativeEvidence(native, typo: lowered, into: &evidence)
        // A known misspelling (`dont`, `enuf`) is unambiguous, so it leads by more than the auto-apply margin.
        let knownFix = KnownMisspellings.fix(for: word)
        let certain = SpellingCandidateSignals(isKnownFix: true)
        // A name competes at a fixed score: it applies by itself when nothing else comes close
        // (`walmart` → Walmart) and shares the bar when a common word is one slip away (`hungary`
        // could be Hungary or hungry).
        let properNoun = (isMidWord ? nil : properNounCasing(of: word, native: native)).map {
            RankedSpellingCandidate(
                candidate: SpellingCandidate(term: $0, score: properNounScore),
                signals: SpellingCandidateSignals(isProperNoun: true)
            )
        }
        guard !evidence.isEmpty else {
            if let knownFix {
                return [RankedSpellingCandidate(candidate: SpellingCandidate(term: knownFix, score: 1.5), signals: certain)]
            }
            return properNoun.map { [$0] } ?? []
        }

        let terms = Array(evidence.keys)
        let pairLogs = pairLogCounts(for: terms, contextCount: contextCount)
        let sentenceScores = sentenceContextScore.map { score in
            terms.reduce(into: [String: Double]()) { result, term in result[term] = score(term) }
        } ?? [:]
        let context = ScoringContext(
            typo: lowered,
            dictionaryBest: isMidWord ? nil : uncontestedDictionaryBest(sources.fullWord, excluding: lowered),
            shortWordPenalty: lowered.count <= 3 ? 0.85 : 1.0,
            isMidWord: isMidWord,
            personal: personal,
            contextBoosts: contextBoosts(from: pairLogs),
            personalContext: personalContextCount.map { count in
                terms.reduce(into: [:]) { result, term in result[term] = count(term) }
            } ?? [:],
            sentenceBoosts: sentenceBoosts(from: sentenceScores)
        )
        let scored = evidence.map { term, item in
            RankedSpellingCandidate(
                candidate: SpellingCandidate(
                    term: TypoCaseTransfer.applying(caseOf: word, to: term),
                    score: score(term: term, item: item, context: context)
                        * firstLetterFactor(typo: lowered, term: term, item: item)
                ),
                signals: SpellingCandidateSignals(
                    distanceWeight: item.distanceWeight,
                    logCount: item.logCount,
                    nativePosition: item.nativePosition,
                    soundSimilarity: item.soundSimilarity,
                    soundsIdentical: item.soundsIdentical,
                    soundIsApproximate: item.soundIsApproximate,
                    personalAccepted: personal[term] ?? 0,
                    personalContext: context.personalContext[term] ?? 0,
                    splitPairLog: item.splitPairLog,
                    splitMinimumLogCount: item.splitMinimumLogCount,
                    pairLogCount: pairLogs[term],
                    sentenceScore: sentenceScores[term]
                )
            )
        }

        let knownKey = knownFix?.lowercased()
        let byScore = (scored + (properNoun.map { [$0] } ?? []))
            .filter { $0.candidate.term.lowercased() != knownKey }
            .sorted { lhs, rhs in
                lhs.candidate.score != rhs.candidate.score
                    ? lhs.candidate.score > rhs.candidate.score
                    : lhs.candidate.term < rhs.candidate.term
            }
        let others = knownFix == nil ? leadingWithHabitualFix(byScore, word: word, personal: personal) : byScore
        // A known fix always leads by more than the auto-apply margin, whatever the others scored.
        let known = knownFix.map { fix -> RankedSpellingCandidate in
            var signals = scored.first { $0.candidate.term.lowercased() == knownKey }?.signals ?? certain
            signals.isKnownFix = true
            let score = max(1.5, (others.first?.candidate.score ?? 0) + knownFixLead)
            return RankedSpellingCandidate(candidate: SpellingCandidate(term: fix, score: score), signals: signals)
        }
        return Array(((known.map { [$0] } ?? []) + others).prefix(limit))
    }

    /// How many times the writer must have made the same fix for this exact slip before it leads
    /// the list, and before it is made for them.
    static let habitLeadCount = 2
    static let habitAutoCount = 3
    /// A habit is only made for the writer while it has at least this many uses for every use of
    /// their other fix for the same slip: right four times in five or better. `fro` made into
    /// `from` four times and `for` twice still leads with `from`, and asks.
    static let habitAutoDominance = 4
    /// How far apart the two words are scored for a slip the writer takes both ways: inside the
    /// gate's margin for showing a list (`TypoGate.Settings.baseChoiceListMaximumMargin`).
    static let bothWaysGap = 0.05
    /// The lead a twice-made fix gets: enough to be the one fix shown, not enough to be applied.
    static let habitLead = 0.2

    /// The fix this writer keeps making for this exact slip, when they have made it at least twice
    /// and at least twice as often as any other fix for it (`fro` retyped as both `from` and `for`
    /// has no habit). Nil otherwise.
    static func habitualFix(in personal: [String: Int]) -> HabitualFix? {
        let ordered = personal.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        guard let best = ordered.first, best.value >= habitLeadCount else { return nil }
        let rival = ordered.dropFirst().first?.value ?? 0
        return best.value >= 2 * rival ? HabitualFix(term: best.key, count: best.value, rival: rival) : nil
    }

    /// The fix a writer keeps making for one slip: the word, how often they made it, and how
    /// often they made their next most frequent fix for the same slip (0 when there is none).
    struct HabitualFix: Equatable {
        let term: String
        let count: Int
        let rival: Int
    }

    /// A slip the writer has corrected to two different words, with neither a habit, is theirs
    /// to settle each time: their two words lead, close enough together that the gate shows a
    /// list and applies nothing.
    ///
    /// Without this the dictionary's order decided, and its first word could be applied unasked.
    /// On a recorded day a short slip the writer makes for two common words lost its habit to one
    /// rejection (see `PersonalCorrectionMemory.demoteHabit`), and for the next hours the
    /// commoner of the two was typed for them 8 times, with 19 bars and 4 retypes before the
    /// habit was back, while their own history said the slip goes both ways.
    private static func leadingWithBothOfTheWritersWords(
        _ ranked: [RankedSpellingCandidate], word: String, personal: [String: Int]
    ) -> [RankedSpellingCandidate] {
        let own = personal.filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(2)
        guard own.count == 2 else { return ranked }
        let top = max(ranked.first?.candidate.score ?? 0, 1.0)
        let leading = own.enumerated().map { place, entry -> RankedSpellingCandidate in
            let listed = ranked.first { $0.candidate.term.lowercased() == entry.key }
            return RankedSpellingCandidate(
                candidate: SpellingCandidate(
                    term: listed?.candidate.term ?? TypoCaseTransfer.applying(caseOf: word, to: entry.key),
                    score: top - Double(place) * bothWaysGap
                ),
                signals: listed?.signals ?? SpellingCandidateSignals(personalAccepted: entry.value)
            )
        }
        return leading + ranked.filter { candidate in !own.contains { $0.key == candidate.candidate.term.lowercased() } }
    }

    /// True when the writer has made two different fixes for the slip these candidates are for.
    /// The order is then theirs (`leadingWithBothOfTheWritersWords`), and no model reorders it.
    static func holdsTwoOfTheWritersFixes(_ ranked: [RankedSpellingCandidate]) -> Bool {
        ranked.filter { $0.signals.personalAccepted > 0 }.count >= 2
    }

    /// Puts the writer's habitual fix first, whatever the dictionary thinks is likelier.
    ///
    /// A writer's own repeated correction of one slip to one word is the strongest evidence there
    /// is about that slip, and word frequency must not outvote it: someone who types `wich` for
    /// `which` many times a day should not be offered `with` every time because `with` is the
    /// commoner word. From the second time the fix leads the list; from
    /// the third it leads by the auto-fix margin, like a certain misspelling, so it is made for them.
    /// The fix is added when the dictionary sources did not find it (a slip too far from its word).
    private static func leadingWithHabitualFix(
        _ ranked: [RankedSpellingCandidate], word: String, personal: [String: Int]
    ) -> [RankedSpellingCandidate] {
        guard let habit = habitualFix(in: personal) else {
            return leadingWithBothOfTheWritersWords(ranked, word: word, personal: personal)
        }
        let rest = ranked.filter { $0.candidate.term.lowercased() != habit.term }
        let own = ranked.first { $0.candidate.term.lowercased() == habit.term }
        let isMadeForThem = habit.count >= habitAutoCount && habit.count >= habitAutoDominance * habit.rival
        let runnerUp = rest.first?.candidate.score ?? 0
        // Until the fix is made for them it leads by `habitLead` and no more. Its own score is left
        // out on purpose: that score already holds the history nudge, which with a favourable
        // sentence put a twice-made fix far enough ahead to be applied without asking.
        let score = isMadeForThem
            ? max(own?.candidate.score ?? 0, runnerUp + knownFixLead, 1.5)
            : max(runnerUp + habitLead, 1.0)
        let leading = RankedSpellingCandidate(
            candidate: SpellingCandidate(
                term: own?.candidate.term ?? TypoCaseTransfer.applying(caseOf: word, to: habit.term), score: score
            ),
            signals: own?.signals ?? SpellingCandidateSignals(personalAccepted: habit.count)
        )
        return [leading] + rest
    }

    static let properNounScore = 1.3

    /// The system checker's own spelling of a lowercase word when the only difference is its capitals
    /// (`walmart` → Walmart, `iphone` → iPhone): the writer probably spelled a name correctly, and a
    /// look-alike word (`venmo` → venom) should not replace it unasked.
    static func properNounCasing(of word: String, native: [String]) -> String? {
        guard word == word.lowercased(), let first = native.first, first != word, first.lowercased() == word else {
            return nil
        }
        return first
    }

    private struct ScoringContext {
        let typo: String
        let dictionaryBest: String?
        let shortWordPenalty: Double
        let isMidWord: Bool
        let personal: [String: Int]
        let contextBoosts: [String: Double]
        let personalContext: [String: Int]
        let sentenceBoosts: [String: Double]
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
        for match in sources.phonetic
        where match.term != lowered && (match.similarity >= minimumPhoneticSimilarity || match.soundsIdentical) {
            // Sounding right and looking close is the dyslexic signature: `enuf` ~ enough (0.78),
            // while a same-sound word with little spelling in common (`enuf` ~ unify) stays low. A
            // sound one slip off is weaker evidence than the same sound.
            let weight = (match.isApproximate ? 0.2 : 0.35) + 0.6 * match.similarity
            evidence[match.term, default: Evidence()].absorb(weight: weight, count: match.count)
            evidence[match.term]?.soundSimilarity = match.similarity
            if match.soundsIdentical { evidence[match.term]?.soundsIdentical = true }
            if match.isApproximate { evidence[match.term]?.soundIsApproximate = true }
        }
        addSplitEvidence(sources.splits, into: &evidence)
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

    /// Two common words that really do follow each other (`next door`) are a strong reading of a
    /// non-word made of exactly their letters; two that never meet (`be cause`) are a weak one.
    private static func addSplitEvidence(_ splits: [SymSpellSplit], into evidence: inout [String: Evidence]) {
        for split in splits {
            let key = split.first + " " + split.second
            var item = evidence[key] ?? Evidence(nativeOnlyWeight: split.pairCount > 0 ? splitKnownPairWeight : splitWeight)
            item.splitPairLog = log10(Double(split.pairCount) + 1)
            item.splitMinimumLogCount = log10(Double(max(split.minimumCount, 1)))
            evidence[key] = item
        }
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
                if evidence[key] == nil { evidence[key] = Evidence(nativeOnlyWeight: splitWeight) }
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
        // Same sound vowels included (`brawt` ~ brought, `pikcher` ~ picture) is the strongest
        // sound-it-out evidence there is; `brat` shares only the consonants. Only for words more
        // than one edit away: a one-edit neighbor is already scored well, and boosting it too let
        // a rare near word run away with the lead (`juse` → jus over juice).
        if item.soundsIdentical, !context.isMidWord, item.distanceWeight < 1 {
            score += soundsIdenticalBonus
        }
        // Dropping one letter of a double (`dady`, `hapy`, `stoped`) is among the most common
        // dyslexic spellings, so the word with that letter doubled beats a same-distance neighbor.
        if !context.isMidWord, isDoubledLetterRestoration(typo: context.typo, term: term) {
            score += doubledLetterBonus
        }
        // Two neighboring letters swapped (`teh`, `recieve`) is the most common slip of all, far
        // more common than one wrong letter, so it beats a same-distance substitution (`tea`).
        if !context.isMidWord, isAdjacentSwap(typo: context.typo, term: term) {
            score += adjacentSwapBonus
        }
        // The writer's own history: each time they accepted or retyped this fix it gains. A fix
        // they keep making leads outright (see `leadingWithHabitualFix`); this is the gentler
        // nudge for one made once, or made about as often as another.
        if let accepted = context.personal[term], accepted > 0 {
            score += min(personalHistoryCap, personalHistoryStep * Double(accepted))
        }
        // The writer's own phrasing ("my daddy") is stronger evidence than book counts, but it is
        // scaled by spelling closeness like corpus context so it can only settle close calls.
        if let written = context.personalContext[term], written > 0 {
            score += min(personalContextBoost, 0.1 * Double(written)) * item.distanceWeight
        }
        let closeness = max(item.distanceWeight, item.logCount == nil ? 0.7 : 0)
        return score + ((context.contextBoosts[term] ?? 0) + (context.sentenceBoosts[term] ?? 0)) * closeness
    }

    /// Context is comparative: the candidate that most often follows the previous word gains
    /// `maximumContextBoost` (scaled by how close its spelling is, so a common pairing cannot drag a
    /// two-edit word past a one-edit fix: `left thier` stays `their`, not `the`), and a candidate about
    /// thirty times rarer after it gains nothing. `know wich` has
    /// `know which` seven times more often than `know with`, which outweighs `with` being the more
    /// common word overall. Pairs missing from the list count as a floor of one million.
    static let personalHistoryStep = 0.15
    static let personalHistoryCap = 0.6
    static let doubledLetterBonus = 0.15
    static let adjacentSwapBonus = 0.15

    /// `term` is `typo` with one or two separate pairs of neighboring letters swapped (`teh`,
    /// `tihkn` → think).
    static func isAdjacentSwap(typo: String, term: String) -> Bool {
        var typed = Array(typo)
        let intended = Array(term)
        guard typed.count == intended.count, typed != intended else { return false }
        var swaps = 0
        var index = 0
        while index < typed.count {
            guard typed[index] != intended[index] else {
                index += 1
                continue
            }
            guard swaps < 2, index + 1 < typed.count, typed[index] == intended[index + 1],
                  typed[index + 1] == intended[index] else { return false }
            typed.swapAt(index, index + 1)
            swaps += 1
            index += 2
        }
        return typed == intended
    }
    static let soundsIdenticalBonus = 0.3

    /// `term` is `typo` with exactly one letter doubled.
    static func isDoubledLetterRestoration(typo: String, term: String) -> Bool {
        let typed = Array(typo)
        let intended = Array(term)
        guard intended.count == typed.count + 1 else { return false }
        for index in 1..<intended.count where intended[index] == intended[index - 1] {
            var restored = intended
            restored.remove(at: index)
            if restored == typed { return true }
        }
        return false
    }

    static let maximumContextBoost = 0.35
    static let maximumSentenceBoost = 0.3

    /// Relative like `contextBoosts`: the candidate the n-gram table finds likeliest after the
    /// sentence so far gains the full boost, others in proportion, unseen ones nothing.
    private static func sentenceBoosts(from scores: [String: Double]) -> [String: Double] {
        guard let best = scores.values.max(), best > 0 else { return [:] }
        return scores.mapValues { maximumSentenceBoost * $0 / best }
    }
    /// Cap on the boost for a pair the writer has written themselves (reached at three uses).
    static let personalContextBoost = 0.3
    static let contextSpanDecades = 1.5

    /// log10 of how often each candidate follows the previous word, floored at a million; empty when
    /// there is no previous word or the pair list has not loaded.
    private static func pairLogCounts(for terms: [String], contextCount: ((String) -> Int64?)?) -> [String: Double] {
        guard let contextCount else { return [:] }
        var logs: [String: Double] = [:]
        for term in terms {
            guard let first = term.split(separator: " ").first, let count = contextCount(String(first)) else { return [:] }
            logs[term] = log10(Double(max(count, 1_000_000)))
        }
        return logs
    }

    private static func contextBoosts(from logs: [String: Double]) -> [String: Double] {
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
        var soundsIdentical = false
        var soundIsApproximate = false
        var splitPairLog: Double?
        var splitMinimumLogCount: Double?
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
