import XCTest
@testable import Cotabby

/// Pure pieces behind the stronger spelling and the sentence pass: sound-alike keys, the known
/// misspelling table, iPhone-style capitalization, and the local proofreader with stubbed checks.
final class SentenceProofreadingTests: XCTestCase {
    // MARK: - PhoneticKey

    func test_phoneticKey_matchesSoundItOutSpellings() {
        // #then each typo shares at least one key with the word it sounds like
        for (typo, word) in [("enuf", "enough"), ("skool", "school"), ("fisical", "physical"), ("shud", "should"), ("fone", "phone")] {
            XCTAssertFalse(
                Set(PhoneticKey.keys(for: typo)).isDisjoint(with: PhoneticKey.keys(for: word)),
                "\(typo) should sound like \(word): \(PhoneticKey.keys(for: typo)) vs \(PhoneticKey.keys(for: word))"
            )
        }
    }

    func test_phoneticKey_separatesDifferentSounds() {
        XCTAssertTrue(Set(PhoneticKey.keys(for: "cat")).isDisjoint(with: PhoneticKey.keys(for: "dog")))
    }

    // MARK: - KnownMisspellings

    func test_knownMisspellings_fixesAndKeepsCase() {
        XCTAssertEqual(KnownMisspellings.fix(for: "enuf"), "enough")
        XCTAssertEqual(KnownMisspellings.fix(for: "Dont"), "Don't")
        XCTAssertEqual(KnownMisspellings.fix(for: "im"), "I'm")
    }

    func test_knownMisspellings_neverTouchesRealWordsOrSlang() {
        for word in ["gonna", "wanna", "wont", "lets", "well", "its", "sed", "strait", "which", "with"] {
            XCTAssertNil(KnownMisspellings.fix(for: word), word)
        }
    }

    // MARK: - SentenceCapitalization

    func test_capitalization_sentenceStartsAndPronoun() {
        XCTAssertEqual(SentenceCapitalization.capitalized("hello", textBefore: ""), "Hello")
        XCTAssertEqual(SentenceCapitalization.capitalized("thanks", textBefore: "See you. "), "Thanks")
        XCTAssertEqual(SentenceCapitalization.capitalized("i", textBefore: "so "), "I")
        XCTAssertEqual(SentenceCapitalization.capitalized("i'm", textBefore: "then "), "I'm")
    }

    func test_capitalization_leavesMidSentenceAbbreviationsAndNames() {
        XCTAssertNil(SentenceCapitalization.capitalized("the", textBefore: "I think "))
        XCTAssertNil(SentenceCapitalization.capitalized("the", textBefore: "e.g. "))
        XCTAssertNil(SentenceCapitalization.capitalized("smith", textBefore: "I met Mr. "))
        XCTAssertNil(SentenceCapitalization.capitalized("economy", textBefore: "the U.S. "))
        XCTAssertNil(SentenceCapitalization.capitalized("iPhone", textBefore: ""))
    }

    // MARK: - LocalSentenceProofreader

    private func proofread(
        _ sentence: String,
        typos: [String: (String, Bool)] = [:],
        pairs: [String: Int64] = [:],
        sentenceScores: [String: Double]? = nil
    ) -> LocalProofreadResult {
        LocalSentenceProofreader.proofread(sentence, checks: LocalSentenceProofreader.Checks(
            isTypo: { typos[$0] != nil },
            fix: { word, _ in typos[word].map { (options: [$0.0], isCertain: $0.1) } },
            pairCount: { first, second in pairs["\(first) \(second)"] ?? 0 },
            sentenceScore: sentenceScores.map { scores in { _, word in scores[word.lowercased()] ?? 0 } }
        ))
    }

    func test_proofread_mechanicalFixesAreAutomatic() {
        // #when
        let result = proofread("I went to the the store , then home.")

        // #then
        XCTAssertEqual(result.autoCorrected, "I went to the store, then home.")
        XCTAssertFalse(result.hasSuggestions)
    }

    func test_proofread_keepsLegitimateRepeats() {
        XCTAssertEqual(proofread("I had had enough of it.").autoCorrected, "I had had enough of it.")
    }

    func test_proofread_certainTypoIsAppliedUncertainOneIsSuggested() {
        let result = proofread(
            "It broke becuase the adres was wrong.",
            typos: ["becuase": ("because", true), "adres": ("address", false)]
        )

        XCTAssertEqual(result.autoCorrected, "It broke because the adres was wrong.")
        XCTAssertEqual(result.suggested, "It broke because the address was wrong.")
    }

    func test_proofread_wrongWordFromBothSidesIsOnlySuggested() {
        let result = proofread("I went their yesterday.", pairs: ["went there": 30_000_000])

        XCTAssertEqual(result.autoCorrected, "I went their yesterday.")
        XCTAssertEqual(result.suggested, "I went there yesterday.")
    }

    func test_proofread_fixingATypoCannotLeaveADoubledWord() {
        let result = proofread("I think teh the plan works.", typos: ["teh": ("the", true)])

        XCTAssertEqual(result.autoCorrected, "I think the plan works.")
    }

    func test_proofread_leavesTheLastWordToTheWordGate() {
        XCTAssertFalse(proofread("I like teh", typos: ["teh": ("the", true)]).hasAutoFixes)
    }

    func test_proofread_wordThatFitsTheSentenceIsNotFlaggedWhateverThePairsSay() {
        // #given pair counts that dislike "it's" and a sentence model that finds it likely
        let result = proofread(
            "It's hard to master English.",
            pairs: ["its hard": 30_000_000],
            sentenceScores: ["it's": 0.3, "its": 0.01]
        )

        // #then the correct contraction is left alone
        XCTAssertFalse(result.hasSuggestions)
    }

    func test_proofread_capitalizedUnknownWordMidSentenceIsAName() {
        let result = proofread("Yesterday Koko learned new words.", typos: ["Koko": ("Kook", true)])

        XCTAssertEqual(result.autoCorrected, "Yesterday Koko learned new words.")
    }
}
