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

    func test_capitalization_abbreviationWrittenWithoutInnerDots_doesNotStartASentence() {
        // #given abbreviations the way they are often typed, with only the final period
        let abbreviations = ["eg.", "ie.", "cf.", "ex.", "min.", "max.", "et al."]

        // #when a lowercase word follows one of them inside a sentence
        let capitalized = abbreviations.map { SentenceCapitalization.capitalized("there", textBefore: "Use a tool, \($0) ") }

        // #then it stays lowercase
        XCTAssertEqual(capitalized, Array(repeating: nil, count: abbreviations.count))
    }

    func test_capitalization_agreesWithTheSentenceBoundaryClassifier_onItsAbbreviations() {
        // #given every abbreviation `SentenceBoundaryClassifier` lists (its set is private, so the
        // list is repeated here and checked against it below)
        let abbreviations = ["mr", "mrs", "ms", "dr", "st", "vs", "eg", "ie", "etc", "no", "fig", "approx", "inc", "ltd"]

        // #when each ends a piece of text, as the classifier sees it, and comes before a word, as
        // capitalization sees it
        let disagreeing = abbreviations.filter { abbreviation in
            let text = "see \(abbreviation)."
            return SentenceBoundaryClassifier.endsSentence(text) || SentenceCapitalization.isSentenceStart(text + " ")
        }

        // #then neither rule takes the period for the end of a sentence
        XCTAssertEqual(disagreeing, [])
    }

    func test_capitalization_joinedOrCodeLikeToken_atSentenceStart_isLeftAsTyped() {
        // #given tokens joined by a hyphen, dot, slash or underscore, or holding a digit
        let tokens = ["node-gyp", "k-means", "self-hosted", "config.yaml", "src/main", "snake_case", "utf8"]

        // #when each is the first word after a finished sentence
        let capitalized = tokens.map { SentenceCapitalization.capitalized($0, textBefore: "It was fine. ") }

        // #then none gets a capital
        XCTAssertEqual(capitalized, Array(repeating: nil, count: tokens.count))
    }

    func test_capitalization_wordTheCallerLeavesAsTyped_isNotCapitalizedAtSentenceStart() {
        // #given a caller that knows `kubectl` is written in lowercase

        // #when it starts a sentence
        let capitalized = SentenceCapitalization.capitalized("kubectl", textBefore: "It was fine. ") { $0 == "kubectl" }

        // #then it stays as typed
        XCTAssertNil(capitalized)
    }

    func test_capitalization_ordinaryWord_isStillCapitalized_whenTheCallerLeavesOtherWordsAsTyped() {
        // #given the same caller

        // #when an ordinary word starts a sentence
        let capitalized = SentenceCapitalization.capitalized("hello", textBefore: "It was fine. ") { $0 == "kubectl" }

        // #then it gets its capital
        XCTAssertEqual(capitalized, "Hello")
    }

    func test_capitalization_pronounI_isCapitalized_evenWhenTheCallerLeavesEveryWordAsTyped() {
        // #given a caller that would leave any word alone

        // #when the pronoun is typed in lowercase inside a sentence
        let capitalized = SentenceCapitalization.capitalized("i", textBefore: "so ") { _ in true }

        // #then it is still capitalized
        XCTAssertEqual(capitalized, "I")
    }

    // MARK: - LocalSentenceProofreader

    func test_pronounIsCapitalized_withEitherApostrophe_butNotTheLetterOfAnAbbreviation() {
        // #given the pronoun with a curly apostrophe, and `i.e.`, which starts with the same letter
        let pronoun = proofread("And then i’m sure it works.")
        let abbreviation = proofread("Use the first one, i.e. this one.")

        // #then the pronoun gets its capital and the abbreviation is left as written
        XCTAssertEqual(pronoun.autoCorrected, "And then I’m sure it works.")
        XCTAssertEqual(abbreviation.autoCorrected, "Use the first one, i.e. this one.")
    }

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

    // MARK: - Code-like text inside a sentence

    func test_wordToken_isJoinedUnlessItStandsAloneAsAPlainWord() {
        // #given a sentence with a path, a dotted name, a flag, a hyphenated name and a digit in it
        let sentence = "Then “cat” /etc/passwd, fs.readdir (now) --force aws-sdk i7 tmp_buf today."

        // #when
        let joined = WordToken.tokens(in: sentence).filter(\.isJoined).map(\.text)

        // #then only the words with nothing but quotes, brackets or sentence punctuation around them are plain
        XCTAssertEqual(joined, ["etc", "passwd", "fs", "readdir", "force", "aws", "sdk", "i", "tmp", "buf"])
    }

    func test_proofread_neverFixesAPieceOfAPathANameOrAFlag() {
        // #given pieces the spelling engine is certain about, each inside something that is not prose
        let typos = ["passwd": ("passed", true), "readdir": ("reader", true), "forse": ("force", true), "sentense": ("sentence", true)]
        let sentence = "Then cat /etc/passwd and call fs.readdir with --forse on the fix-sentense-rules branch today."

        // #when
        let result = proofread(sentence, typos: typos)

        // #then
        XCTAssertEqual(result.autoCorrected, sentence)
    }

    func test_proofread_neverOffersAPieceOfAFileNameOrAnIdentifierOnTheCard() {
        // #given pieces the spelling engine would offer a fix for
        let typos = ["tsx": ("tax", false), "yml": ("yaml", false), "buf": ("buff", false), "arr": ("area", false)]

        // #when
        let result = proofread("Open src/App.tsx and config.yml and the tmp_buf field of arr[n] today.", typos: typos)

        // #then
        XCTAssertFalse(result.hasSuggestions)
    }

    func test_proofread_plainWordNextToCodeIsStillFixed() {
        // #given a certain typo standing on its own between a path and a file name
        let result = proofread("Open /etc/hosts and teh config.yml file today.", typos: ["teh": ("the", true)])

        // #then
        XCTAssertEqual(result.autoCorrected, "Open /etc/hosts and the config.yml file today.")
    }

    func test_pronounIsNotCapitalized_whenTheLetterIsPartOfSomethingElse() {
        // #given the letter against a digit, a slash, a bracket, in a list marker, and quoted
        let sentences = [
            "My laptop has an i7 processor and it is fast.",
            "We use i18n for the translations here today.",
            "Read the i/o docs before you start today.",
            "See items (i) and (ii) in the list below.",
            "Set a[i] to zero for each element today.",
            "The letter \"i\" is the loop index here today."
        ]

        // #then each sentence comes back as written
        XCTAssertEqual(sentences.map { proofread($0).autoCorrected }, sentences)
    }

    func test_pronounIsCapitalized_rightAfterAnOpeningBracketOrQuote() {
        // #when the pronoun starts a bracketed aside and a quotation
        let result = proofread("He said (i think) that \"i will come\" later today.")

        // #then
        XCTAssertEqual(result.autoCorrected, "He said (I think) that \"I will come\" later today.")
    }

    func test_spacingRules_leaveCodeInASentenceAlone() {
        // #given lists, calls, a mode string, an acronym, a ternary and a lone dot, all typed on purpose
        let sentences = [
            "Pass the values a,b,c to the function now.",
            "Call print(a,b) to show both values here.",
            "Run chmod u+x,g+r on the script today.",
            "Run cd src;ls and see the files today.",
            "TL;DR the plan works and we ship it.",
            "Use the ternary x ? y : z in the code today.",
            "The key : value pairs are in the file today.",
            "Then run git add . and commit it today.",
            "We need name,email,phone in the form today."
        ]

        // #then each sentence comes back as written
        XCTAssertEqual(sentences.map { proofread($0).autoCorrected }, sentences)
    }

    func test_spacingRules_stillFixSlipsBetweenOrdinaryWords() {
        // #when a comma has no space after it, a space on the wrong side, and a space in front
        let result = proofread("Yes,we can and yes ,we will ; so , are we ready ?")

        // #then
        XCTAssertEqual(result.autoCorrected, "Yes, we can and yes, we will; so, are we ready?")
    }

    func test_couldOf_isLeftAlone_whenTheModalIsANounOrOfIsAPreposition() {
        // #given `might` and `must` as nouns, and `of` starting a phrase of its own
        let sentences = [
            "They feared the might of Rome back then.",
            "They feared the might of armed men then.",
            "Hamlet is a must of any reading list.",
            "We would of necessity wait for it.",
            "Who could of the three do it today?"
        ]

        // #then each sentence comes back as written
        XCTAssertEqual(sentences.map { proofread($0).autoCorrected }, sentences)
    }

    func test_couldOf_becomesHave_beforeAPastParticiple() {
        // #when a subject comes before `must`, `n’t` marks the verb, and an adverb sits before the participle
        let result = proofread("He must of been tired, she wouldn’t of gone, and we should of never asked them.")

        // #then
        XCTAssertEqual(result.autoCorrected, "He must have been tired, she wouldn’t have gone, and we should have never asked them.")
    }

    func test_doubledWord_isKept_whenItIsANameOrARepeatMadeOnPurpose() {
        // #given reduplicated names, emphasis, and function words that double in correct English
        let sentences = [
            "We flew to Bora Bora and saw Duran Duran there.",
            "Mahi mahi is on the menu at the place today.",
            "Please please say bye bye to the long long day.",
            "She saw The The play live last year.",
            "Who do I talk to to get this fixed today?",
            "Use a a b c layout for the grid today."
        ]

        // #then each sentence comes back as written
        XCTAssertEqual(sentences.map { proofread($0).autoCorrected }, sentences)
    }

    func test_doubledWord_isCollapsed_whenTheWordIsNeverDoubled() {
        // #when
        let result = proofread("It is made of of wood and it it works with with care.")

        // #then
        XCTAssertEqual(result.autoCorrected, "It is made of wood and it works with care.")
    }
}
