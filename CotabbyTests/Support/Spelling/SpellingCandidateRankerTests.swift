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

    func test_rank_writersOwnPhrasingSettlesACloseCall() {
        // #given two one-edit fixes where the corpus slightly prefers "dad"
        let sources = SpellingCandidateSources(
            fullWord: [
                SymSpellSuggestion(term: "dad", distance: 1, count: 50_000_000),
                SymSpellSuggestion(term: "day", distance: 1, count: 40_000_000)
            ],
            prefix: [],
            isCommonWordPrefix: false
        )

        // #when the writer has written "my day" twice and never "my dad"
        let ranked = SpellingCandidateRanker.rank(
            word: "dady",
            isMidWord: false,
            sources: sources,
            native: [],
            personal: [:],
            personalContextCount: { $0 == "day" ? 2 : 0 }
        )

        // #then their phrasing wins
        XCTAssertEqual(ranked.first?.term, "day")
    }

    func test_rank_identicalSoundLiftsAFarSpellingOverANearOne() {
        // #given "brat" one edit away and "brought" only reachable by sound
        let sources = SpellingCandidateSources(
            fullWord: [SymSpellSuggestion(term: "brat", distance: 1, count: 5_000_000)],
            prefix: [],
            isCommonWordPrefix: false,
            phonetic: [SymSpellPhoneticMatch(term: "brought", similarity: 0.8, count: 60_000_000, soundsIdentical: true)]
        )

        // #when ranking the finished word
        let ranked = SpellingCandidateRanker.rank(word: "brawt", isMidWord: false, sources: sources, native: [], personal: [:])

        // #then the word it sounds exactly like wins
        XCTAssertEqual(ranked.first?.term, "brought")
    }

    func test_adjacentSwap_recognizesUpToTwoNeighborPairs() {
        XCTAssertTrue(SpellingCandidateRanker.isAdjacentSwap(typo: "teh", term: "the"))
        XCTAssertTrue(SpellingCandidateRanker.isAdjacentSwap(typo: "recieve", term: "receive"))
        XCTAssertTrue(SpellingCandidateRanker.isAdjacentSwap(typo: "tihkn", term: "think"))
        XCTAssertFalse(SpellingCandidateRanker.isAdjacentSwap(typo: "teh", term: "tea"))
        XCTAssertFalse(SpellingCandidateRanker.isAdjacentSwap(typo: "abcdef", term: "badcfe"), "three swaps is too many")
    }

    func test_doubledLetterRestoration_recognizesOnlyOneDoubledLetter() {
        XCTAssertTrue(SpellingCandidateRanker.isDoubledLetterRestoration(typo: "hapy", term: "happy"))
        XCTAssertTrue(SpellingCandidateRanker.isDoubledLetterRestoration(typo: "stoped", term: "stopped"))
        XCTAssertFalse(SpellingCandidateRanker.isDoubledLetterRestoration(typo: "hapy", term: "harpy"))
        XCTAssertFalse(SpellingCandidateRanker.isDoubledLetterRestoration(typo: "sory", term: "story"))
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

    // MARK: - The second half of a hyphenated word

    /// The gate with a dictionary that knows which letters can still become a word.
    private func decide(_ text: String, wordStarts: Set<String>) -> TypoGateDecision {
        TypoGate.resolve(
            precedingText: text,
            settings: TypoGate.Settings(suppressCompletionsOnTypo: true, offerTypoCorrections: true, automaticallyFixTypos: true),
            isTypo: { _ in true },
            isWordInProgress: { wordStarts.contains($0) },
            candidates: { word, _ in [SpellingCandidate(term: word + "x", score: 1)] }
        )
    }

    func test_compoundBeingTyped_isJudgedByTheLettersAfterTheHyphen() {
        // #given letters after a hyphen that can still become a word, in a token no word starts with
        // #when the gate looks at the unfinished compound
        let decision = decide("it is user-fac", wordStarts: ["fac"])

        // #then nothing is flagged, so the word strip keeps the word
        XCTAssertEqual(decision, .proceed)
    }

    func test_compoundBeingTyped_withTwoLettersAfterTheHyphen_isTooShortToJudge() {
        // #given two letters after the hyphen, which no list was asked about
        let decision = decide("it is well-kn", wordStarts: [])

        // #then the gate waits, as it does for the first two letters of any word
        XCTAssertEqual(decision, .proceed)
    }

    func test_compoundBeingTyped_withASlipAfterTheHyphen_isStillOffered() {
        // #given letters after the hyphen that cannot become a word
        let decision = decide("it is user-fxq", wordStarts: ["user"])

        // #then the compound is offered a fix as a whole
        XCTAssertEqual(decision, .offerCorrection(word: "user-fxq", correctedWord: "user-fxqx"))
    }

    func test_compoundFinishedWithASpace_isJudgedWhole() {
        // #given the same compound with a space after it
        let decision = decide("it is user-fac ", wordStarts: ["fac"])

        // #then the whole token is judged: the part alone no longer excuses it
        XCTAssertNotEqual(decision, .proceed)
    }

    func test_compoundKnownWhole_proceedsEvenWhenItsLastPartIsNoWordStart() {
        // #given a token the dictionary can finish as a whole, whose last part starts no word
        let decision = decide("send an e-mai", wordStarts: ["e-mai"])

        XCTAssertEqual(decision, .proceed)
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

    // MARK: - The writer's own habit

    /// A slip as close to a much commoner word as to the word the writer means by it.
    private var slipNearACommonerWord: SpellingCandidateSources {
        SpellingCandidateSources(
            fullWord: [
                SymSpellSuggestion(term: "with", distance: 1, count: 23_000_000_000),
                SymSpellSuggestion(term: "which", distance: 1, count: 800_000_000),
                SymSpellSuggestion(term: "witch", distance: 1, count: 20_000_000)
            ],
            prefix: [],
            isCommonWordPrefix: false
        )
    }

    private func rank(_ word: String, sources: SpellingCandidateSources, personal: [String: Int]) -> [SpellingCandidate] {
        SpellingCandidateRanker.rank(word: word, isMidWord: false, sources: sources, native: [], personal: personal)
    }

    func test_fixMadeTwice_leadsButIsNotMadeForTheWriter() {
        // #when the writer has corrected the slip to the same word twice
        let ranked = rank("wich", sources: slipNearACommonerWord, personal: ["which": 2])

        // #then it is the fix shown, short of the lead an automatic fix needs
        XCTAssertEqual(ranked.first?.term, "which")
        let lead = ranked[0].score - ranked[1].score
        XCTAssertGreaterThanOrEqual(lead, SpellingCandidateRanker.habitLead - 0.001)
        XCTAssertLessThan(lead, TypoGate.Settings(suppressCompletionsOnTypo: true, offerTypoCorrections: true, automaticallyFixTypos: true).autoApplyMinimumMargin)
    }

    func test_fixMadeTwice_isNotMadeForTheWriter_evenWhereTheSentenceFavoursIt() {
        // #given a twice-made fix that is also the commoner word and the one that most often
        // follows the previous word, so its own score with the history nudge is far ahead
        let settings = TypoGate.Settings(suppressCompletionsOnTypo: true, offerTypoCorrections: true, automaticallyFixTypos: true)

        // #when the slip is ranked
        let ranked = SpellingCandidateRanker.rank(
            word: "wich",
            isMidWord: false,
            sources: slipNearACommonerWord,
            native: [],
            personal: ["with": 2],
            contextCount: { $0 == "with" ? 5_000_000_000 : 1_000_000 }
        )

        // #then it leads, by too little to be applied without asking
        XCTAssertFalse(TypoGate.isCertain(top: ranked[0], margin: ranked[0].score - ranked[1].score, confidence: nil, settings: settings))
    }

    func test_fixMadeThreeTimes_leadsByTheAutoFixMargin() {
        let ranked = rank("wich", sources: slipNearACommonerWord, personal: ["which": 3])
        let settings = TypoGate.Settings(suppressCompletionsOnTypo: true, offerTypoCorrections: true, automaticallyFixTypos: true)

        XCTAssertEqual(ranked.first?.term, "which")
        XCTAssertTrue(TypoGate.isCertain(top: ranked[0], margin: ranked[0].score - ranked[1].score, confidence: nil, settings: settings))
    }

    func test_slipCorrectedToTwoWordsAboutAsOften_hasNoHabit() {
        // `fro` retyped as `from` three times and as `for` twice says the writer means both.
        XCTAssertNil(SpellingCandidateRanker.habitualFix(in: ["from": 3, "for": 2]))
        XCTAssertEqual(SpellingCandidateRanker.habitualFix(in: ["from": 4, "for": 2])?.term, "from")
        XCTAssertNil(SpellingCandidateRanker.habitualFix(in: ["from": 1]))
    }

    func test_habitualFixTheDictionaryDidNotFind_isOfferedAnyway() {
        // #given a slip too far from its word for the dictionary sources to connect them
        let ranked = rank("restrnt", sources: slipNearACommonerWord, personal: ["restaurant": 2])

        XCTAssertEqual(ranked.first?.term, "restaurant")
    }

    func test_habitualFix_keepsTheCapitalTheWriterTyped() {
        let ranked = rank("Wich", sources: slipNearACommonerWord, personal: ["which": 3])

        XCTAssertEqual(ranked.first?.term, "Which")
    }

    @MainActor
    func test_personalMemory_correctingAWordTakesBackAnEarlierKeep() {
        // #given a slip marked as intended because one automatic fix of it was undone
        let suite = "SpellingCandidateRankerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = PersonalCorrectionMemory(userDefaults: defaults)
        memory.recordKept("wich")
        XCTAssertTrue(memory.isKept("wich"))

        // #when the writer then corrects it themselves
        memory.recordAccepted(typo: "wich", replacement: "which")

        // #then it is a slip again, here and after a restart
        XCTAssertFalse(memory.isKept("wich"))
        XCTAssertFalse(PersonalCorrectionMemory(userDefaults: defaults).isKept("wich"))
    }

    func test_prefixMatches_bytePath_givesExactlyWhatTheCharacterPathGives() throws {
        // #given the bundled dictionary with everything the app adds, and prefixes of many kinds:
        // correct starts, slips, swapped openings, apostrophes, one with an accent
        let url = try XCTUnwrap(Bundle.main.url(forResource: "frequency_dictionary_en_82_765", withExtension: "txt"))
        let symSpell = SymSpell()
        symSpell.loadDictionary(
            contents: try String(contentsOf: url, encoding: .utf8) + "\n" + SymSpellCorrector.englishOverrides()
                + "\n" + SymSpellCorrector.englishSupplement() + "\ncaf\u{E9} 500000\nna\u{EF}ve 400000\n"
        )
        let prefixes = [
            "th", "hte", "recie", "neccess", "wich", "becuase", "definat", "seperat", "goverm", "enviro", "tomoro",
            "wen", "frend", "beleiv", "acomod", "restar", "neigb", "favor", "travl", "don'", "i'", "you'v", "caf",
            "na\u{EF}", "zz", "qx", "embarras", "occured", "untill", "adress", "calender", "priv", "s", "aa", "strenght",
        ]

        // #then every prefix gets the same matches, in the same order, from both paths
        for prefix in prefixes {
            for distance in [0, 1, 2] {
                let fast = symSpell.prefixMatches(for: prefix, maxEditDistance: distance, limit: 40)
                let reference = symSpell.prefixMatches(for: prefix, maxEditDistance: distance, limit: 40, comparingCharacters: true)
                XCTAssertEqual(fast, reference, "\(prefix) at distance \(distance)")
            }
        }
        // #and the plain completions and the "word in progress" test agree with the dictionary itself
        XCTAssertTrue(symSpell.completions(of: "neighb", limit: 20).contains("neighborhood"))
        XCTAssertEqual(symSpell.completions(of: "caf", limit: 50).contains("caf\u{E9}"), true)
        XCTAssertFalse(symSpell.completions(of: "the", limit: 50).contains("the"))
        XCTAssertTrue(symSpell.isCommonWordPrefix("restau"))
        XCTAssertFalse(symSpell.isCommonWordPrefix("restaz"))
        XCTAssertEqual(symSpell.count(of: "cannot"), 60_000_000)
    }
}
