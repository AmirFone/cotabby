import Foundation

/// File overview:
/// Decides whether the ranker's best fix is safe to apply without asking. The ranker's score orders
/// candidates well, but "how far ahead is the top score" is a poor measure of "how likely is the top
/// fix to be the word the writer meant": a brand name one swap away from a common word scores like a
/// real typo. This file turns the same evidence into a probability with a small gradient-boosted
/// tree model trained on real misspellings (Birkbeck corpora in held-out sentences) and on correct
/// words the system checker flags (names, slang), so more fixes can be applied on the spot while
/// wrong ones stay rare.
///
/// `AutoFixFeatures` is the single definition of the model's inputs, used by the app, by
/// `cotabby-spell --features` to write training rows, and by the trained model file (which names
/// its features, so a model trained against a different list is rejected instead of silently
/// misread). `TreeEnsembleModel` evaluates the trees: a few hundred comparisons, a few microseconds,
/// so it costs nothing on the keystroke that finishes a word.
nonisolated enum AutoFixFeatures {
    /// The trained judge shipped with the app; nil when the file is missing or was trained on a
    /// different feature list.
    static func bundledModel(in bundle: Bundle = .main) -> TreeEnsembleModel? {
        TreeEnsembleModel.bundled(named: "autofix_confidence_en", featureNames: names, in: bundle)
    }

    /// The second judge: the same inputs, trained with generated finger slips as well (a key
    /// beside the one meant, a dropped, extra or swapped letter). It only ever adds its
    /// confidence to a fix the first judge already put first (`TypoGateInputs.orderedByModel`).
    static func bundledKeyboardModel(in bundle: Bundle = .main) -> TreeEnsembleModel? {
        TreeEnsembleModel.bundled(named: "autofix_keyboard_en", featureNames: names, in: bundle)
    }

    static let names: [String] = [
        "typoLength", "typoIsShort", "typoVowelRatio", "typoHasNonLetter", "capitalizedMidSentence",
        "candidateCount", "rankerPosition", "topScore", "margin", "secondScore", "nearCount",
        "topDistanceWeight", "topLogCount", "topEditDistance", "topEditRatio", "topLengthDelta",
        "topSimilarity", "topNativeFirst", "topNativeListed", "topSoundSimilarity", "topSoundsIdentical",
        "topSoundIsApproximate",
        "topIsKnownFix", "topIsAdjacentSwap", "topIsDoubledLetter", "topSameFirstLetter", "topSameLastLetter",
        "topHasSpace", "topSplitPairLog", "topSplitMinimumLogCount", "topMirroredLetters", "topVowelsOnly", "topNeighborKeys",
        "topPairLog", "topSentenceLog", "hasSentenceContext",
        "secondDistanceWeight", "secondLogCount", "secondEditDistance", "secondSimilarity",
        "secondNativeFirst", "secondSoundsIdentical", "secondPairLog", "secondSentenceLog",
        "logCountDelta", "sentenceLogDelta", "pairLogDelta", "editDistanceDelta"
    ]

    /// Scores within this of the judged candidate count as rivals.
    private static let nearMargin = 0.15
    private static let maximumEditDistance = 6
    private static let sentenceFloor = 1e-6

    /// The model inputs for judging the candidate at `index`. "top" in the feature names is that
    /// candidate; "second" is its strongest rival, the ranker's best other candidate.
    /// - Parameters:
    ///   - typo: the word as typed.
    ///   - ranked: `SpellingCandidateRanker.rankDetailed` for the finished word, best first.
    ///   - capitalizedMidSentence: the word starts with a capital and does not start a sentence, which
    ///     is how names look.
    static func vector(
        typo: String,
        ranked: [RankedSpellingCandidate],
        index: Int = 0,
        capitalizedMidSentence: Bool
    ) -> [Double] {
        guard ranked.indices.contains(index) else { return [] }
        let top = ranked[index]
        let rivals = ranked.enumerated().filter { $0.offset != index }.map(\.element)
        let second = rivals.first
        let typed = Array(typo.lowercased())
        let topTerm = Array(top.candidate.term.lowercased())
        let secondTerm = second.map { Array($0.candidate.term.lowercased()) }
        let vowels = typed.filter { "aeiouy".contains($0) }.count
        let topEdits = editDistance(typed, topTerm)
        let secondEdits = secondTerm.map { editDistance(typed, $0) } ?? Double(maximumEditDistance + 3)
        let topSentence = sentenceLog(top.signals.sentenceScore)
        let secondSentence = sentenceLog(second?.signals.sentenceScore)
        let topPair = pairLog(top.signals.pairLogCount)
        let secondPair = pairLog(second?.signals.pairLogCount)
        let topLogCount = top.signals.logCount ?? -1
        let secondLogCount = second?.signals.logCount ?? -1
        let topString = String(topTerm)
        let typedString = String(typed)
        let substitutions = substitutedLetters(typed, topTerm)

        return [
            Double(typed.count),
            flag(typed.count <= 3),
            Double(vowels) / Double(max(typed.count, 1)),
            flag(typed.contains { !$0.isLetter }),
            flag(capitalizedMidSentence),
            Double(ranked.count),
            Double(index),
            top.candidate.score,
            top.candidate.score - (second?.candidate.score ?? 0),
            second?.candidate.score ?? 0,
            Double(rivals.filter { $0.candidate.score >= top.candidate.score - nearMargin }.count),
            top.signals.distanceWeight,
            topLogCount,
            topEdits,
            topEdits / Double(max(typed.count, 1)),
            Double(topTerm.count - typed.count),
            SymSpell.jaroWinkler(typed, topTerm),
            flag(top.signals.nativePosition == 0),
            flag(top.signals.nativePosition != nil),
            top.signals.soundSimilarity ?? 0,
            flag(top.signals.soundsIdentical),
            flag(top.signals.soundIsApproximate),
            flag(top.signals.isKnownFix),
            flag(SpellingCandidateRanker.isAdjacentSwap(typo: typedString, term: topString)),
            flag(SpellingCandidateRanker.isDoubledLetterRestoration(typo: typedString, term: topString)),
            flag(typed.first == topTerm.first),
            flag(typed.last == topTerm.last),
            flag(topTerm.contains(" ")),
            top.signals.splitPairLog ?? -1,
            top.signals.splitMinimumLogCount ?? -1,
            flag(substitutions.map { !$0.isEmpty && $0.allSatisfy { mirrors[$0.typed]?.contains($0.intended) == true } } ?? false),
            flag(typed != topTerm && typed.filter { !"aeiouy".contains($0) } == topTerm.filter { !"aeiouy".contains($0) }),
            flag(substitutions.map { $0.count == 1 && keyNeighbors[$0[0].typed]?.contains($0[0].intended) == true } ?? false),
            topPair,
            topSentence,
            flag(top.signals.sentenceScore != nil),
            second?.signals.distanceWeight ?? 0,
            secondLogCount,
            secondEdits,
            secondTerm.map { SymSpell.jaroWinkler(typed, $0) } ?? 0,
            flag(second?.signals.nativePosition == 0),
            flag(second?.signals.soundsIdentical == true),
            secondPair,
            secondSentence,
            topLogCount - secondLogCount,
            topSentence - secondSentence,
            topPair - secondPair,
            secondEdits - topEdits
        ]
    }

    /// Letters a dyslexic writer mirrors or rotates (`dack` for back, `qlay` for play).
    static let mirrors: [Character: Set<Character>] = [
        "b": ["d", "p", "q"], "d": ["b", "p", "q"], "p": ["q", "b", "d"], "q": ["p", "b", "d"],
        "m": ["w"], "w": ["m"], "n": ["u"], "u": ["n"]
    ]

    /// Keys next to each other on a QWERTY keyboard: a finger slip rather than a spelling belief.
    static let keyNeighbors: [Character: Set<Character>] = {
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map(Array.init)
        var map: [Character: Set<Character>] = [:]
        for (rowIndex, row) in rows.enumerated() {
            for (column, key) in row.enumerated() {
                var near = Set<Character>()
                if column > 0 { near.insert(row[column - 1]) }
                if column + 1 < row.count { near.insert(row[column + 1]) }
                // The rows are staggered by about half a key, so a key touches two keys in each neighboring row.
                for other in [rowIndex - 1, rowIndex + 1] where rows.indices.contains(other) {
                    for offset in [rowIndex < other ? column - 1 : column, rowIndex < other ? column : column + 1]
                    where rows[other].indices.contains(offset) {
                        near.insert(rows[other][offset])
                    }
                }
                map[key] = near
            }
        }
        return map
    }()

    /// The letter pairs that differ when both spellings have the same length; nil otherwise.
    static func substitutedLetters(_ typed: [Character], _ term: [Character]) -> [(typed: Character, intended: Character)]? {
        guard typed.count == term.count else { return nil }
        return zip(typed, term).filter { $0 != $1 }.map { (typed: $0, intended: $1) }
    }

    private static func flag(_ value: Bool) -> Double { value ? 1 : 0 }

    private static func editDistance(_ typed: [Character], _ term: [Character]) -> Double {
        let distance = SymSpell.damerauOSA(typed, term, maxDistance: maximumEditDistance)
        return Double(distance < 0 ? maximumEditDistance + 1 : distance)
    }

    private static func sentenceLog(_ score: Double?) -> Double {
        log10(max(score ?? 0, sentenceFloor))
    }

    /// Decades above the one-million floor the pair counts use; 0 without context.
    private static func pairLog(_ logCount: Double?) -> Double {
        max(0, (logCount ?? 6) - 6)
    }
}
