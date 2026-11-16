import Foundation

/// File overview:
/// Finds correctly spelled words that are probably the wrong word (`to tired`, `your right`,
/// `pulled a mussel`), the errors a spell checker cannot see and a dyslexic writer cannot easily
/// proofread away because every letter looks plausible.
///
/// `RealWordErrorDetector` covers a hand-written list of about a hundred confusable groups. This
/// file generalizes it: any real word gets alternatives (a word one slip away, a word that sounds
/// the same, or a listed confusable), each alternative is described by how it relates to the typed
/// word and how much better it fits the words on both sides, and a trained tree model
/// (`TreeEnsembleModel`, the same evaluator as the auto-fix judge) turns that into a probability.
///
/// Everything here is pure: the dictionary, pair counts, and n-gram scores come in as closures, so
/// the app, `cotabby-spell --wrong-features` (training rows), and unit tests run the same code.
nonisolated struct WrongWordAlternative: Equatable, Sendable {
    /// Lowercased.
    let term: String
    let count: Int64
    let soundsIdentical: Bool
    /// Listed together with the typed word in `RealWordErrorDetector.confusableGroups`.
    let isConfusable: Bool
}

nonisolated enum WrongWordDetector {
    /// What the dictionary knows, as closures over `SymSpell` (see `SymSpellCorrector.wrongWordSources`).
    struct Sources {
        /// Corpus count of a lowercased word; 0 when it is not in the dictionary.
        let count: (String) -> Int64
        /// Dictionary words one edit away.
        let neighbors: (String) -> [SymSpellSuggestion]
        /// Common words that sound exactly the same.
        let soundAlikes: (String) -> [SymSpellSuggestion]
        /// Count of roughly the 30,000th most common word; rarer neighbors are not worth suggesting.
        let commonCountFloor: Int64
    }

    /// The sentence around the word, and the two context models.
    struct Position {
        /// Everything in the sentence before the word (ends in whitespace or is empty).
        let textBefore: String
        let previous: String?
        let next: String?
        let afterNext: String?
        /// Bigram count, nil while the list is loading.
        let pairCount: (_ first: String, _ second: String) -> Int64?
        /// N-gram likelihood of a word after some text (`NextWordPredictor.contextScore`).
        let sentenceScore: (_ textBefore: String, _ word: String) -> Double
    }

    static let maximumAlternatives = 8
    private static let sentenceFloor = 1e-6

    static func bundledModel(in bundle: Bundle = .main) -> TreeEnsembleModel? {
        TreeEnsembleModel.bundled(named: "wrong_word_en", featureNames: featureNames, in: bundle)
    }

    /// The words `word` was probably meant to be, most likely first: every alternative whose
    /// probability clears `threshold` (at most two). Empty when the word fits.
    /// - Parameter threshold: the model's sentence-pass threshold by default; pass its
    ///   `caretThreshold` when `position` has nothing to the right of the word yet.
    static func suspects(
        for word: String,
        sources: Sources,
        position: Position,
        model: TreeEnsembleModel,
        threshold: Double? = nil
    ) -> [(term: String, probability: Double)] {
        let found = alternatives(for: word, sources: sources)
        guard !found.isEmpty else { return [] }
        let minimum = threshold ?? model.threshold
        let vectors = features(typed: word, typedCount: sources.count(word.lowercased()), alternatives: found, position: position)
        return Array(zip(found, vectors)
            .map { (term: $0.term, probability: model.probability(features: $1)) }
            .filter { $0.probability >= minimum }
            .sorted { $0.probability > $1.probability }
            .prefix(2))
    }

    /// Words the writer may have meant instead of the real word `word`, most plausible kind first:
    /// listed confusables, then same-sounding words, then one-edit neighbors by frequency.
    static func alternatives(for word: String, sources: Sources) -> [WrongWordAlternative] {
        let typed = word.lowercased()
        guard typed.count >= 2 else { return [] }
        var found: [String: WrongWordAlternative] = [:]
        for term in RealWordErrorDetector.alternatives(for: typed) {
            found[term] = WrongWordAlternative(term: term, count: sources.count(term), soundsIdentical: false, isConfusable: true)
        }
        for match in sources.soundAlikes(typed) where match.term != typed {
            found[match.term] = WrongWordAlternative(
                term: match.term,
                count: match.count,
                soundsIdentical: true,
                isConfusable: found[match.term] != nil
            )
        }
        for match in sources.neighbors(typed) where match.term != typed && match.count >= sources.commonCountFloor {
            guard found[match.term] == nil, !isInflection(typed, match.term) else { continue }
            found[match.term] = WrongWordAlternative(term: match.term, count: match.count, soundsIdentical: false, isConfusable: false)
        }
        return Array(found.values.sorted { lhs, rhs in
            if lhs.isConfusable != rhs.isConfusable { return lhs.isConfusable }
            if lhs.soundsIdentical != rhs.soundsIdentical { return lhs.soundsIdentical }
            return lhs.count != rhs.count ? lhs.count > rhs.count : lhs.term < rhs.term
        }.prefix(maximumAlternatives))
    }

    /// One word is the other plus `s` or `d` (`cats`/`cat`, `use`/`used`). Agreement and tense need
    /// grammar the context counts do not have, and flagging them interrupts correct sentences.
    static func isInflection(_ lhs: String, _ rhs: String) -> Bool {
        let (shorter, longer) = lhs.count < rhs.count ? (lhs, rhs) : (rhs, lhs)
        guard shorter.count >= 3, longer.count == shorter.count + 1, longer.hasPrefix(shorter), let ending = longer.last else {
            return false
        }
        return ending == "s" || ending == "d"
    }

    static let featureNames: [String] = [
        "typedLength", "typedLogCount", "candidateLogCount", "logCountDelta",
        "editDistance", "lengthDelta", "similarity", "sameFirstLetter", "sameLastLetter",
        "isAdjacentSwap", "isDoubledLetter", "mirroredLetters", "vowelsOnly", "neighborKeys",
        "soundsIdentical", "isConfusable", "apostropheOnly", "hasPrevious", "hasNext",
        "leftTyped", "leftCandidate", "leftDelta", "rightTyped", "rightCandidate", "rightDelta",
        "afterNextTyped", "afterNextCandidate", "afterNextDelta",
        "pairBeforeTyped", "pairBeforeCandidate", "pairBeforeDelta",
        "pairAfterTyped", "pairAfterCandidate", "pairAfterDelta",
        "contextDelta", "alternativeCount", "bestRivalContextDelta"
    ]

    /// One vector per alternative, in order. "Delta" features are candidate minus typed word, in
    /// powers of ten, so positive means the alternative fits better.
    static func features(
        typed word: String,
        typedCount: Int64,
        alternatives: [WrongWordAlternative],
        position: Position
    ) -> [[Double]] {
        let typed = word.lowercased()
        let typedFit = fit(of: typed, position: position)
        let fits = alternatives.map { fit(of: $0.term, position: position) }
        let deltas = fits.map { $0.total - typedFit.total }
        return alternatives.enumerated().map { index, alternative in
            let rival = deltas.enumerated().filter { $0.offset != index }.map(\.element).max() ?? -9
            return shape(typed: typed, typedCount: typedCount, alternative: alternative)
                + [flag(position.previous != nil), flag(position.next != nil)]
                + contrast(typedFit, fits[index])
                + [deltas[index], Double(alternatives.count), rival]
        }
    }

    // MARK: - How the two spellings relate

    private static func shape(typed: String, typedCount: Int64, alternative: WrongWordAlternative) -> [Double] {
        let typedLetters = Array(typed), term = Array(alternative.term)
        let typedLog = log10(Double(max(typedCount, 1))), candidateLog = log10(Double(max(alternative.count, 1)))
        let distance = SymSpell.damerauOSA(typedLetters, term, maxDistance: 4)
        let substitutions = AutoFixFeatures.substitutedLetters(typedLetters, term)
        let doubled = SpellingCandidateRanker.isDoubledLetterRestoration(typo: typed, term: alternative.term)
            || SpellingCandidateRanker.isDoubledLetterRestoration(typo: alternative.term, term: typed)
        let consonants: ([Character]) -> [Character] = { $0.filter { !"aeiouy".contains($0) } }
        let isMirrored = substitutions.map { pairs in
            !pairs.isEmpty && pairs.allSatisfy { AutoFixFeatures.mirrors[$0.typed]?.contains($0.intended) == true }
        } ?? false
        let isKeySlip = substitutions.map { pairs in
            pairs.count == 1 && AutoFixFeatures.keyNeighbors[pairs[0].typed]?.contains(pairs[0].intended) == true
        } ?? false
        return [
            Double(typedLetters.count),
            typedLog,
            candidateLog,
            candidateLog - typedLog,
            Double(distance < 0 ? 5 : distance),
            Double(term.count - typedLetters.count),
            SymSpell.jaroWinkler(typedLetters, term),
            flag(typedLetters.first == term.first),
            flag(typedLetters.last == term.last),
            flag(SpellingCandidateRanker.isAdjacentSwap(typo: typed, term: alternative.term)),
            flag(doubled),
            flag(isMirrored),
            flag(typedLetters != term && consonants(typedLetters) == consonants(term)),
            flag(isKeySlip),
            flag(alternative.soundsIdentical),
            flag(alternative.isConfusable),
            flag(typedLetters.filter { $0 != "'" } == term.filter { $0 != "'" })
        ]
    }

    // MARK: - How well a word fits its place

    private struct Fit {
        let left: Double
        let right: Double
        let afterNext: Double
        let pairBefore: Double
        let pairAfter: Double
        var total: Double { left + right + afterNext }
    }

    private static func fit(of word: String, position: Position) -> Fit {
        let logScore: (String, String) -> Double = { log10(max(position.sentenceScore($0, $1), sentenceFloor)) }
        let pairLog: (String, String) -> Double = { log10(Double((position.pairCount($0, $1) ?? 0) + 1)) }
        let through = position.textBefore + word + " "
        return Fit(
            left: logScore(position.textBefore, word),
            right: position.next.map { logScore(through, $0) } ?? 0,
            afterNext: position.next.flatMap { next in position.afterNext.map { logScore(through + next + " ", $0) } } ?? 0,
            pairBefore: position.previous.map { pairLog($0, word) } ?? 0,
            pairAfter: position.next.map { pairLog(word, $0) } ?? 0
        )
    }

    private static func contrast(_ typed: Fit, _ candidate: Fit) -> [Double] {
        [
            typed.left, candidate.left, candidate.left - typed.left,
            typed.right, candidate.right, candidate.right - typed.right,
            typed.afterNext, candidate.afterNext, candidate.afterNext - typed.afterNext,
            typed.pairBefore, candidate.pairBefore, candidate.pairBefore - typed.pairBefore,
            typed.pairAfter, candidate.pairAfter, candidate.pairAfter - typed.pairAfter
        ]
    }

    private static func flag(_ value: Bool) -> Double { value ? 1 : 0 }
}
