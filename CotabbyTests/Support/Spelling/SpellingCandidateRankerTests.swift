import XCTest
@testable import Cotabby

/// Pure ranking and tier rules, driven by hand-built evidence so each weight is pinned independently
/// of the bundled dictionary (the real-dictionary behavior lives in `SpellingCorrectionCalibrationTests`).
final class SpellingCandidateRankerTests: XCTestCase {
    func test_rank_prefersCloserThenMoreFrequentAndCopiesCase() {
        let sources = SpellingCandidateSources(
            fullWord: [
                SymSpellSuggestion(term: "the", distance: 1, count: 23_000_000_000),
                SymSpellSuggestion(term: "ten", distance: 1, count: 100_000_000)
            ],
            prefix: [],
            isCommonWordPrefix: false
        )

        let ranked = SpellingCandidateRanker.rank(word: "Teh", isMidWord: false, sources: sources, native: [], personal: [:])

        XCTAssertEqual(ranked.map(\.term), ["The", "Ten"])
        XCTAssertGreaterThan(ranked[0].score, ranked[1].score)
    }

    func test_rank_dictionaryAndSystemAgreeingOnAnUncontestedFixReachesAutoApply() {
        let sources = SpellingCandidateSources(
            fullWord: [SymSpellSuggestion(term: "tomorrow", distance: 2, count: 60_000_000)],
            prefix: [],
            isCommonWordPrefix: false
        )

        let ranked = SpellingCandidateRanker.rank(word: "tommorow", isMidWord: false, sources: sources, native: ["tomorrow"], personal: [:])

        XCTAssertGreaterThanOrEqual(ranked.first?.score ?? 0, 0.85)
    }

    func test_rank_nativeFirstGuessStandsAloneWithoutDictionary() {
        let ranked = SpellingCandidateRanker.rank(
            word: "recieve",
            isMidWord: false,
            sources: .empty,
            native: ["receive", "relieve"],
            personal: [:]
        )

        XCTAssertEqual(ranked.first?.term, "receive")
        XCTAssertGreaterThanOrEqual(ranked[0].score, 0.85)
    }

    func test_rank_keepsOnlyExactSplitsOfRunTogetherWords() {
        let ranked = SpellingCandidateRanker.rank(
            word: "alot",
            isMidWord: false,
            sources: .empty,
            native: ["a lot", "a plot", "allot"],
            personal: [:]
        )

        XCTAssertTrue(ranked.map(\.term).contains("a lot"))
        XCTAssertFalse(ranked.map(\.term).contains("a plot"))
    }

    func test_rank_personalHistoryBoostsTheWritersUsualFix() {
        let sources = SpellingCandidateSources(
            fullWord: [
                SymSpellSuggestion(term: "with", distance: 1, count: 3_000_000_000),
                SymSpellSuggestion(term: "which", distance: 1, count: 800_000_000)
            ],
            prefix: [],
            isCommonWordPrefix: false
        )

        let ranked = SpellingCandidateRanker.rank(word: "wich", isMidWord: false, sources: sources, native: [], personal: ["which": 2])

        XCTAssertEqual(ranked.first?.term, "which")
    }

    func test_rank_midWordUsesPrefixMatchesAndFavorsSwaps() {
        let sources = SpellingCandidateSources(
            fullWord: [],
            prefix: [
                SymSpellPrefixMatch(term: "recent", halfEditDistance: 2, count: 140_000_000),
                SymSpellPrefixMatch(term: "receive", halfEditDistance: 1, count: 88_000_000)
            ],
            isCommonWordPrefix: false
        )

        let ranked = SpellingCandidateRanker.rank(word: "recie", isMidWord: true, sources: sources, native: [], personal: [:])

        XCTAssertEqual(ranked.first?.term, "receive")
    }

    // MARK: - SymSpell prefix matching

    func test_prefixMatches_findsSwappedLettersAndFirstPairSwap() {
        let symSpell = SymSpell()
        for (word, count) in [("receive", 88), ("recent", 140), ("the", 23_000), ("then", 900)] {
            symSpell.createDictionaryEntry(key: word, count: Int64(count))
        }

        XCTAssertEqual(symSpell.prefixMatches(for: "recie", maxEditDistance: 1, limit: 5).first?.term, "receive")
        XCTAssertEqual(symSpell.prefixMatches(for: "hte", maxEditDistance: 1, limit: 5).first?.term, "the")
        XCTAssertTrue(symSpell.isCommonWordPrefix("rece"))
        XCTAssertFalse(symSpell.isCommonWordPrefix("recie"))
    }

    func test_bestPrefixHalfEditDistance_weightsSwapsBelowOtherEdits() {
        XCTAssertEqual(SymSpell.bestPrefixHalfEditDistance(Array("recie"), Array("receive"), maxHalfEdits: 2), 1)
        XCTAssertEqual(SymSpell.bestPrefixHalfEditDistance(Array("recxe"), Array("receive"), maxHalfEdits: 2), 2)
        XCTAssertEqual(SymSpell.bestPrefixHalfEditDistance(Array("zzzz"), Array("receive"), maxHalfEdits: 2), -1)
    }

    // MARK: - TypoGate tiers

    private func decide(_ text: String, candidates: [SpellingCandidate], inProgress: Bool = false) -> TypoGateDecision {
        TypoGate.resolve(
            precedingText: text,
            settings: TypoGate.Settings(suppressCompletionsOnTypo: true, offerTypoCorrections: true, automaticallyFixTypos: true),
            isTypo: { _ in true },
            isWordInProgress: { _ in inProgress },
            candidates: { _, _ in candidates }
        )
    }

    func test_tiers_autoApplyNeedsSpaceScoreAndMargin() {
        let clear = [SpellingCandidate(term: "the", score: 1.5), SpellingCandidate(term: "ten", score: 0.9)]
        XCTAssertEqual(decide("hi teh ", candidates: clear), .applyCorrection(word: "teh", correctedWord: "the"))
        XCTAssertEqual(decide("hi teh", candidates: clear), .offerRankedCorrection(word: "teh", candidates: clear))
    }

    func test_tiers_closeScoresOpenTheList() {
        let close = [SpellingCandidate(term: "with", score: 1.0), SpellingCandidate(term: "which", score: 0.95)]
        XCTAssertEqual(decide("hi wich ", candidates: close), .offerChoices(word: "wich", candidates: close))
    }

    func test_tiers_wordStillBeingTypedProceeds() {
        XCTAssertEqual(decide("hi rece", candidates: [SpellingCandidate(term: "recent", score: 1)], inProgress: true), .proceed)
    }

    func test_tiers_shortMidWordFragmentsProceed() {
        XCTAssertEqual(decide("hi th", candidates: [SpellingCandidate(term: "the", score: 1)]), .proceed)
    }

    // MARK: - Personal memory

    @MainActor
    func test_personalMemory_countsAndPersistsAcceptedFixes() {
        let suite = "SpellingCandidateRankerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let memory = PersonalCorrectionMemory(userDefaults: defaults)
        memory.recordAccepted(typo: "Wich", replacement: "which")
        memory.recordAccepted(typo: "wich", replacement: "Which")

        XCTAssertEqual(PersonalCorrectionMemory(userDefaults: defaults).acceptedReplacements(for: "WICH"), ["which": 2])
    }
}
