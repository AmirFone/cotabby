import XCTest
@testable import Cotabby

/// The model inputs and the tree evaluator, with hand-built evidence and a two-tree model so the
/// arithmetic is checkable by eye. Agreement with the real trained model is checked by
/// `cotabby-spell --check-model` against LightGBM's own outputs.
final class AutoFixConfidenceTests: XCTestCase {
    private func candidate(_ term: String, score: Double, signals: SpellingCandidateSignals = .init()) -> RankedSpellingCandidate {
        RankedSpellingCandidate(candidate: SpellingCandidate(term: term, score: score), signals: signals)
    }

    private func value(_ name: String, in vector: [Double]) -> Double {
        vector[AutoFixFeatures.names.firstIndex(of: name)!]
    }

    private func model(features: [String] = AutoFixFeatures.names, threshold: Double = 0.8) throws -> Data {
        let margin = AutoFixFeatures.names.firstIndex(of: "margin")!
        let json: [String: Any] = [
            "features": features,
            "threshold": threshold,
            "trees": [
                // margin <= 0.2 → -1, else +2
                ["feature": [margin, -1, -1], "threshold": [0.2, 0, 0], "left": [1, 0, 0], "right": [2, 0, 0], "value": [0, -1, 2]],
                // a single leaf
                ["feature": [-1], "threshold": [0], "left": [0], "right": [0], "value": [0.5]]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: json)
    }

    func test_vector_hasOneValuePerName() {
        let vector = AutoFixFeatures.vector(
            typo: "teh",
            ranked: [candidate("the", score: 1.3), candidate("tech", score: 0.8)],
            capitalizedMidSentence: false
        )

        XCTAssertEqual(vector.count, AutoFixFeatures.names.count)
    }

    func test_vector_describesTheJudgedCandidateAgainstItsStrongestRival() {
        let ranked = [candidate("the", score: 1.3), candidate("tech", score: 0.8), candidate("ten", score: 0.7)]

        let leader = AutoFixFeatures.vector(typo: "teh", ranked: ranked, index: 0, capitalizedMidSentence: false)
        let runnerUp = AutoFixFeatures.vector(typo: "teh", ranked: ranked, index: 1, capitalizedMidSentence: false)

        XCTAssertEqual(value("margin", in: leader), 0.5, accuracy: 1e-9)
        XCTAssertEqual(value("margin", in: runnerUp), -0.5, accuracy: 1e-9)
        XCTAssertEqual(value("rankerPosition", in: runnerUp), 1)
        XCTAssertEqual(value("topIsAdjacentSwap", in: leader), 1)
        XCTAssertEqual(value("topIsAdjacentSwap", in: runnerUp), 0)
    }

    func test_vector_marksMirroredLettersVowelSlipsAndNeighboringKeys() {
        let mirrored = AutoFixFeatures.vector(typo: "dack", ranked: [candidate("back", score: 1)], capitalizedMidSentence: false)
        let vowels = AutoFixFeatures.vector(typo: "definate", ranked: [candidate("definite", score: 1)], capitalizedMidSentence: false)
        let slip = AutoFixFeatures.vector(typo: "wprd", ranked: [candidate("word", score: 1)], capitalizedMidSentence: false)

        XCTAssertEqual(value("topMirroredLetters", in: mirrored), 1)
        XCTAssertEqual(value("topVowelsOnly", in: vowels), 1)
        XCTAssertEqual(value("topNeighborKeys", in: slip), 1)
        XCTAssertEqual(value("topMirroredLetters", in: slip), 0)
    }

    func test_vector_isEmptyWithoutCandidates() {
        XCTAssertTrue(AutoFixFeatures.vector(typo: "teh", ranked: [], capitalizedMidSentence: false).isEmpty)
    }

    func test_model_sumsLeafValuesIntoAProbability() throws {
        let model = try XCTUnwrap(TreeEnsembleModel(data: try model(), featureNames: AutoFixFeatures.names))
        var features = [Double](repeating: 0, count: AutoFixFeatures.names.count)
        let margin = AutoFixFeatures.names.firstIndex(of: "margin")!

        features[margin] = 0.5
        XCTAssertEqual(model.probability(features: features), 1 / (1 + exp(-2.5)), accuracy: 1e-12)
        features[margin] = 0.2
        XCTAssertEqual(model.probability(features: features), 1 / (1 + exp(0.5)), accuracy: 1e-12)
        XCTAssertEqual(model.threshold, 0.8)
    }

    func test_model_rejectsAFileTrainedOnOtherFeatures() throws {
        XCTAssertNil(TreeEnsembleModel(
            data: try model(features: AutoFixFeatures.names.dropLast() + ["somethingElse"]),
            featureNames: AutoFixFeatures.names
        ))
        XCTAssertNil(TreeEnsembleModel(data: Data("not json".utf8), featureNames: AutoFixFeatures.names))
    }

    func test_model_scoresAWrongLengthVectorAsZero() throws {
        let model = try XCTUnwrap(TreeEnsembleModel(data: try model(), featureNames: AutoFixFeatures.names))

        XCTAssertEqual(model.probability(features: [1, 2, 3]), 0)
    }

    func test_bundledModel_matchesThisBuildsFeatureList() {
        XCTAssertNotNil(AutoFixFeatures.bundledModel(),
                        "Retrain with Tools/autofix/run.sh after changing AutoFixFeatures.names")
    }

    func test_bundledKeyboardModel_matchesThisBuildsFeatureList() {
        XCTAssertNotNil(AutoFixFeatures.bundledKeyboardModel(),
                        "Retrain the second judge too (Tools/autofix/run.sh, AUTOFIX_OUT) after changing AutoFixFeatures.names")
    }
}

/// With a model probability the gate applies a fix on that probability; without one it falls back to
/// the score and margin.
final class TypoGateConfidenceTests: XCTestCase {
    private func resolve(confidence: Double?, minimum: Double?, candidates: [SpellingCandidate]) -> TypoGateDecision {
        var settings = TypoGate.Settings(suppressCompletionsOnTypo: true, offerTypoCorrections: true, automaticallyFixTypos: true)
        settings.autoApplyMinimumConfidence = minimum
        return TypoGate.resolve(
            precedingText: "I saw teh ",
            settings: settings,
            isTypo: { $0 == "teh" },
            isWordInProgress: { _ in false },
            candidates: { _, _ in candidates },
            autoFixConfidence: { _ in confidence }
        )
    }

    private let close = [SpellingCandidate(term: "the", score: 1.0), SpellingCandidate(term: "ten", score: 0.9)]
    private let clear = [SpellingCandidate(term: "the", score: 1.5), SpellingCandidate(term: "ten", score: 0.6)]

    func test_confidentModel_appliesAFixTheScoreRuleWouldOnlyOffer() {
        XCTAssertEqual(resolve(confidence: 0.9, minimum: 0.8, candidates: close), .applyCorrection(word: "teh", correctedWord: "the"))
    }

    func test_unsureModel_offersAFixTheScoreRuleWouldApply() {
        XCTAssertEqual(resolve(confidence: 0.5, minimum: 0.8, candidates: clear), .offerRankedCorrection(word: "teh", candidates: clear))
    }

    func test_noModelProbability_usesTheScoreRule() {
        XCTAssertEqual(resolve(confidence: nil, minimum: 0.8, candidates: clear), .applyCorrection(word: "teh", correctedWord: "the"))
        XCTAssertEqual(resolve(confidence: 0.99, minimum: nil, candidates: close), .offerChoices(word: "teh", candidates: close))
    }

    func test_frequentUndos_raiseTheConfidenceBarWithACap() {
        let adapted = TypoGate.Settings.adaptedAutoApplyMinimumConfidence
        XCTAssertEqual(adapted(0.76, 10, 5), 0.76)
        XCTAssertEqual(adapted(0.76, 100, 2), 0.76)
        XCTAssertEqual(adapted(0.76, 100, 10), 0.83, accuracy: 1e-9)
        XCTAssertEqual(adapted(0.76, 100, 60), 0.91, accuracy: 1e-9)
        XCTAssertEqual(adapted(0.95, 100, 60), 0.98, accuracy: 1e-9)
    }
}

/// Two words typed without their space are offered as a pair, stronger when the pair is a known one.
final class RunTogetherCandidateTests: XCTestCase {
    private func ranked(pairCount: Int64) -> [RankedSpellingCandidate] {
        var sources = SpellingCandidateSources(
            fullWord: [SymSpellSuggestion(term: "nestor", distance: 2, count: 400_000)],
            prefix: [],
            isCommonWordPrefix: false
        )
        sources.splits = [SymSpellSplit(first: "next", second: "door", minimumCount: 50_000_000, pairCount: pairCount)]
        return SpellingCandidateRanker.rankDetailed(word: "nextdoor", isMidWord: false, sources: sources, native: [], personal: [:])
    }

    func test_knownPair_leadsAndCarriesItsCounts() {
        let ranked = ranked(pairCount: 3_000_000)

        XCTAssertEqual(ranked.first?.candidate.term, "next door")
        XCTAssertEqual(ranked.first?.signals.splitPairLog ?? 0, log10(3_000_001), accuracy: 1e-9)
        XCTAssertNil(ranked.last?.signals.splitPairLog)
    }

    func test_unknownPair_isAWeakerReading() {
        let known = ranked(pairCount: 3_000_000).first { $0.candidate.term == "next door" }
        let unknown = ranked(pairCount: 0).first { $0.candidate.term == "next door" }

        XCTAssertGreaterThan(known?.candidate.score ?? 0, unknown?.candidate.score ?? 0)
        XCTAssertEqual(unknown?.signals.splitPairLog, 0)
    }

    func test_systemSplitOfTheSameLetters_doesNotEraseTheCounts() {
        var sources = SpellingCandidateSources.empty
        sources.splits = [SymSpellSplit(first: "next", second: "door", minimumCount: 50_000_000, pairCount: 3_000_000)]

        let ranked = SpellingCandidateRanker.rankDetailed(
            word: "nextdoor",
            isMidWord: false,
            sources: sources,
            native: ["next door"],
            personal: [:]
        )

        XCTAssertEqual(ranked.first?.signals.nativePosition, 0)
        XCTAssertNotNil(ranked.first?.signals.splitPairLog)
    }
}

/// A lowercase word the system checker only wants capitalized is a name, not a misspelling.
final class ProperNounCandidateTests: XCTestCase {
    func test_nameWithNoCloseWord_leadsAlone() {
        let ranked = SpellingCandidateRanker.rankDetailed(
            word: "walmart",
            isMidWord: false,
            sources: .empty,
            native: ["Walmart", "Walmarts"],
            personal: [:]
        )

        XCTAssertEqual(ranked.first?.candidate.term, "Walmart")
        XCTAssertEqual(ranked.first?.signals.isProperNoun, true)
        XCTAssertGreaterThanOrEqual((ranked.first?.candidate.score ?? 0) - (ranked.dropFirst().first?.candidate.score ?? 0), 0.4)
    }

    func test_nameOneSlipFromACommonWord_sharesTheList() {
        let sources = SpellingCandidateSources(
            fullWord: [SymSpellSuggestion(term: "hungry", distance: 1, count: 20_000_000)],
            prefix: [],
            isCommonWordPrefix: false
        )

        let ranked = SpellingCandidateRanker.rankDetailed(
            word: "hungary",
            isMidWord: false,
            sources: sources,
            native: ["Hungary", "hungry"],
            personal: [:]
        )

        XCTAssertEqual(Set(ranked.prefix(2).map(\.candidate.term)), ["Hungary", "hungry"])
        XCTAssertLessThan(abs(ranked[0].candidate.score - ranked[1].candidate.score), 0.4)
    }

    func test_onlyALowercaseWordWhoseFirstGuessIsItsOwnCapitalization() {
        XCTAssertEqual(SpellingCandidateRanker.properNounCasing(of: "iphone", native: ["iPhone", "phone"]), "iPhone")
        XCTAssertNil(SpellingCandidateRanker.properNounCasing(of: "venmo", native: ["venom", "Venmo"]))
        XCTAssertNil(SpellingCandidateRanker.properNounCasing(of: "Teh", native: ["TEH"]))
        XCTAssertNil(SpellingCandidateRanker.properNounCasing(of: "teh", native: ["the"]))
    }

    func test_midWord_aNameIsNotOffered() {
        let ranked = SpellingCandidateRanker.rankDetailed(
            word: "walmart",
            isMidWord: true,
            sources: .empty,
            native: ["Walmart", "Walmarts"],
            personal: [:]
        )

        XCTAssertFalse(ranked.contains { $0.signals.isProperNoun })
    }
}
