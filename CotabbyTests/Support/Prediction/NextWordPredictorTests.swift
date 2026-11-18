import XCTest
@testable import Cotabby

/// Pins the predictor's reading of the text (sentence start, names, partial words), its backoff
/// scoring, and when Return is allowed to pick, against a tiny hand-built n-gram table.
final class NextWordPredictorTests: XCTestCase {
    private let model = NextWordModelFixture.make([
        "": (1000, [("the", 300), ("i", 200), ("to", 150), ("go", 50), ("good", 40)]),
        "<s>": (500, [("i", 200), ("the", 100), ("we", 50)]),
        "want": (100, [("to", 80), ("a", 10), ("it", 5)]),
        "i want": (60, [("to", 50), ("you", 6)]),
        "<s> i want": (40, [("to", 30), ("it", 6)]),
        "want to": (90, [("go", 40), ("be", 20), ("get", 15), ("give", 5)]),
        "i want to": (50, [("be", 20), ("go", 18), ("see", 5)]),
        "told <name>": (20, [("that", 12), ("about", 4)]),
        "don't": (50, [("know", 30), ("want", 10)]),
        "at the": (100, [("a", 50), ("restaurant", 30)]),
        "go to": (100, [("work", 50), ("bank", 45)]),
    ])

    private func sources(
        completions: [String] = ["going", "gone", "great"],
        personal: [String: [String: Int]] = [:],
        fuzzyCompletions: [String] = [],
        languageModel: LanguageModelScores? = nil
    ) -> NextWordPredictor.Sources {
        NextWordPredictor.Sources(
            model: model,
            completions: { prefix, limit in Array(completions.filter { $0.hasPrefix(prefix) }.prefix(limit)) },
            personal: { context in
                personal[context.joined(separator: " ")].map { ($0.values.reduce(0, +), $0) }
            },
            fuzzyCompletions: { _, limit in Array(fuzzyCompletions.prefix(limit)) },
            languageModel: { _ in languageModel }
        )
    }

    // MARK: - Reading the end of a long text

    func test_lastWords_areTheSameAsSplittingTheWholeText() {
        // #given texts with every kind of spacing at the end, one of them long
        let long = String(repeating: "word ", count: 5_000) + "and the last four"
        for text in ["", " ", "one", "one two", "one  two\nthree ", "a b c d e f", long, long + "  \n"] {
            let expected = text.split(whereSeparator: { $0.isWhitespace }).suffix(4).map(String.init)

            let words = NextWordPredictor.lastWords(of: Substring(text), count: 4).map(String.init)

            XCTAssertEqual(words, expected, String(text.suffix(30)))
        }
    }

    // MARK: - Words with usual capitals

    func test_wordWithUsualCapitals_isShownTheWayItIsWritten() {
        // #given a list word that is conventionally written with capitals
        var withCapitals = sources()
        withCapitals.usualCapitals = { $0 == "go" ? "Go" : nil }

        let prediction = NextWordPredictor.predict(textBefore: "I want to g", sources: withCapitals)

        // #then it is offered that way even after a lowercase letter, and other words are untouched
        XCTAssertEqual(prediction?.words.first, "Go")
        XCTAssertTrue(prediction?.words.dropFirst().allSatisfy { $0 == $0.lowercased() } ?? false)
    }

    // MARK: - After a dot, a slash or a hyphen

    func test_wordStartedRightAfterADotOrSlash_isCompletedFromTheWordsBeforeIt() {
        // #given a word begun against a dot and against a slash, with no space
        let afterDot = NextWordPredictor.predict(textBefore: "I want.t", sources: sources())
        let afterSlash = NextWordPredictor.predict(textBefore: "I want/t", sources: sources())

        // #then the word before the mark is the context, and the dot does not start a sentence
        XCTAssertEqual(afterDot?.words.first, "to")
        XCTAssertEqual(afterSlash?.words.first, "to")
        XCTAssertEqual(afterDot?.prefix, "t")
    }

    func test_rightAfterASlashOrHyphen_theNextWordIsSuggested_butNotAfterADot() {
        // A dot with nothing after it is nearly always the end of a sentence, one space short.
        XCTAssertEqual(NextWordPredictor.predict(textBefore: "I want/", sources: sources())?.words.first, "to")
        XCTAssertEqual(NextWordPredictor.predict(textBefore: "I want-", sources: sources())?.words.first, "to")
        XCTAssertNil(NextWordPredictor.predict(textBefore: "I want.", sources: sources()))
    }

    func test_addressesAndPaths_getNoSuggestions() {
        for text in ["see example.com/g", "open ~/Desktop/g", "mail jo@example.g", "go to src/main/g", "version v1.g", "see www.g"] {
            XCTAssertNil(NextWordPredictor.predict(textBefore: text, sources: sources()), text)
        }
    }

    // MARK: - With the language model

    func test_languageModel_putsTheRightVerbFormFirst() {
        // #given a past-tense sentence, where the table knows nothing after "Yesterday I"
        let text = "Yesterday I walk"
        let model = LanguageModelFixture.scores(textBefore: text, ["walked": 0.5, "walking": 0.04, "walks": 0.01, "walker": 0.001])

        // #when predicting with the model's answer
        let prediction = NextWordPredictor.predict(textBefore: text, sources: sources(languageModel: model))

        // #then the past form comes before the other forms
        XCTAssertEqual(prediction?.words, ["walked", "walking", "walks", "walker"])
    }

    func test_languageModel_offersANameTheTextAlreadyUsed_withItsCapital() {
        // #given a name no dictionary has, which the model found in the text and expects again
        let text = "I want Priyanka to go. I want to pri"
        let model = LanguageModelFixture.scores(
            textBefore: text, ["prior": 0.02, "price": 0.01], textWords: [("Priyanka", 0.3)]
        )

        // #when predicting with lowercase letters typed
        let prediction = NextWordPredictor.predict(textBefore: text, sources: sources(languageModel: model))

        // #then the name comes first, written as the writer wrote it
        XCTAssertEqual(prediction?.words, ["Priyanka", "prior", "price"])
    }

    func test_languageModel_textWordThatDoesNotFitTheLetters_isNotOffered() {
        let text = "I want Priyanka to go. I want to pro"
        let model = LanguageModelFixture.scores(textBefore: text, ["problem": 0.02], textWords: [("Priyanka", 0.3)])

        let prediction = NextWordPredictor.predict(textBefore: text, sources: sources(languageModel: model))

        XCTAssertEqual(prediction?.words, ["problem"])
    }

    func test_languageModel_dictionaryWordTheWriterCapitalizes_isShownCapitalized() {
        // #given a dictionary word the text uses as a name (no probability of its own: the lexicon has it)
        let text = "I want Lantern to go to Lantern. I want the lan"
        let model = LanguageModelFixture.scores(
            textBefore: text, ["lantern": 0.2, "land": 0.05], textWords: [("Lantern", nil)]
        )

        let prediction = NextWordPredictor.predict(textBefore: text, sources: sources(languageModel: model))

        XCTAssertEqual(prediction?.words, ["Lantern", "land"])
    }

    func test_americanSpelling_offersOneWordOnce_inTheAmericanSpelling() {
        // #given a model that finds the British spelling likelier than the American one
        let text = "I want to go trav"
        let model = LanguageModelFixture.scores(textBefore: text, ["travelling": 0.3, "traveling": 0.2, "travel": 0.1])
        var sources = sources(languageModel: model)
        sources.americanSpellings = AmericanSpellings(contents: "travelling traveling")

        // #when predicting for a writer who spells the American way
        let prediction = NextWordPredictor.predict(textBefore: text, sources: sources)

        // #then the word is offered once, first, in that spelling
        XCTAssertEqual(prediction?.words, ["traveling", "travel"])
    }

    func test_languageModel_ordersByLikelihoodNotByKeysSaved() {
        // #given "I want to ", where the table alone would put the longer word forward
        let text = "I want to "
        let model = LanguageModelFixture.scores(textBefore: text, ["go": 0.4, "be": 0.3, "understand": 0.05])

        // #when predicting with the model's answer
        let prediction = NextWordPredictor.predict(textBefore: text, sources: sources(languageModel: model))

        // #then the likeliest word is first, short as it is
        XCTAssertEqual(prediction?.words.first, "go")
    }

    func test_languageModel_exactCompletionBeatsAFarLikelierNearMiss() {
        // #given the letters "withou", and "with" (a near miss of them) twenty times likelier
        let text = "I left withou"
        let model = LanguageModelFixture.scores(textBefore: text, ["without": 0.02, "with": 0.4, "within": 0.01])

        // #when predicting, with "with" and "within" offered as forgiven slips
        let prediction = NextWordPredictor.predict(
            textBefore: text, sources: sources(fuzzyCompletions: ["with", "within"], languageModel: model)
        )

        // #then the word the letters spell is first, and the shorter word is not offered at all
        XCTAssertEqual(prediction?.words.first, "without")
        XCTAssertEqual(prediction?.words.contains("with"), false)
    }

    func test_languageModel_nearMissComesFirstWhenNothingLikelyStartsWithTheLetters() {
        // #given a misspelled start, "wich", that only begins a very unlikely word
        let text = "I know wich"
        let model = LanguageModelFixture.scores(textBefore: text, ["which": 0.3, "wichita": 0.000001])

        // #when predicting, with "which" offered as a forgiven slip
        let prediction = NextWordPredictor.predict(
            textBefore: text, sources: sources(fuzzyCompletions: ["which"], languageModel: model)
        )

        // #then the word meant is first
        XCTAssertEqual(prediction?.words.first, "which")
    }

    func test_languageModel_wordItDoesNotKnow_isScoredByTheTable() {
        // #given the writer's own phrase "go to lindqvist", a name no dictionary has
        let text = "We go to "
        let model = LanguageModelFixture.scores(textBefore: text, ["work": 0.2, "bank": 0.1])
        let personal = ["go to": ["lindqvist": 40]]

        // #when predicting
        let prediction = NextWordPredictor.predict(textBefore: text, sources: sources(personal: personal, languageModel: model))

        // #then the name is still offered
        XCTAssertEqual(prediction?.words.contains("lindqvist"), true)
    }

    func test_offensiveWord_isNeverOffered_withOrWithoutTheLanguageModel() {
        // #given a context where a swear word is the likeliest next word for both sources
        let table = NextWordModelFixture.make(["": (100, [("shit", 60), ("ship", 30), ("shin", 5)])])
        let text = "Oh sh"
        let model = LanguageModelFixture.scores(textBefore: text, ["shit": 0.6, "ship": 0.2, "shin": 0.01])
        func predict(_ languageModel: LanguageModelScores?) -> [String]? {
            NextWordPredictor.predict(textBefore: text, sources: NextWordPredictor.Sources(
                model: table,
                completions: { _, _ in ["shit", "ship"] },
                personal: { _ in nil },
                languageModel: { _ in languageModel }
            ))?.words
        }

        // #then neither list contains it
        XCTAssertEqual(predict(nil), ["ship", "shin"])
        XCTAssertEqual(predict(model), ["ship", "shin"])
    }

    func test_afterSpace_prefersTheLongestKnownContext() {
        // #given "I want to " where the full context favors "be" over the shorter context's "go"
        // #when predicting
        let prediction = NextWordPredictor.predict(textBefore: "I want to ", sources: sources())

        // #then the three-word context wins
        XCTAssertEqual(prediction?.words.first, "be")
        XCTAssertEqual(prediction?.prefix, "")
    }

    func test_partialWord_filtersToCompletionsAndFillsFromTheDictionary() {
        let prediction = NextWordPredictor.predict(textBefore: "I want to g", sources: sources())

        XCTAssertEqual(prediction?.words, ["go", "get", "give", "good", "going"])
        XCTAssertEqual(prediction?.prefix, "g")
    }

    func test_sentenceStart_capitalizesAndIIsAlwaysUppercase() {
        let prediction = NextWordPredictor.predict(textBefore: "Done. ", sources: sources())

        XCTAssertEqual(Set(prediction?.words.prefix(2) ?? []), ["I", "The"])
    }

    func test_capitalizedWordMidSentence_isReadAsAName() {
        let prediction = NextWordPredictor.predict(textBefore: "We told Sam ", sources: sources())

        XCTAssertEqual(prediction?.words.first, "that")
    }

    func test_typedWordItselfIsNotOffered() {
        let prediction = NextWordPredictor.predict(textBefore: "I want to go", sources: sources())

        XCTAssertFalse(prediction?.words.contains("go") ?? true)
    }

    func test_noPredictionDirectlyAfterASymbolOrDigit() {
        XCTAssertNil(NextWordPredictor.predict(textBefore: "mail @jo", sources: sources()))
        XCTAssertNil(NextWordPredictor.predict(textBefore: "room 3", sources: sources()))
    }

    func test_personalPhrasesOutrankTheCorpus() {
        let prediction = NextWordPredictor.predict(
            textBefore: "I want to ",
            sources: sources(personal: ["i want to": ["ship": 8]])
        )

        XCTAssertEqual(prediction?.words.first, "ship")
    }

    func test_certainMisspellingsInTheContextReadAsTheirFix() {
        let prediction = NextWordPredictor.predict(textBefore: "I dont ", sources: sources())

        XCTAssertEqual(prediction?.words.first, "know")
    }

    func test_aPhraseUsedOnceDoesNotOutrankALongerCorpusContext() {
        let prediction = NextWordPredictor.predict(
            textBefore: "I want to ",
            sources: sources(personal: ["want to": ["the": 1]])
        )

        XCTAssertEqual(prediction?.words.first, "be")
    }

    func test_contextScore_prefersTheWordThatFitsTheSentence() {
        let go = NextWordPredictor.contextScore(of: "go", after: "I want to ", model: model)
        let good = NextWordPredictor.contextScore(of: "good", after: "I want to ", model: model)
        let unseen = NextWordPredictor.contextScore(of: "zebra", after: "I want to ", model: model)

        XCTAssertGreaterThan(go, good)
        XCTAssertEqual(unseen, 0)
    }

    func test_theWordThatSavesTheMostKeysTakesTheTabSlot() {
        // #given "a" likelier than "restaurant" but saving nothing over typing it
        // #when predicting
        let prediction = NextWordPredictor.predict(textBefore: "We ate at the ", sources: sources())

        // #then the long word comes first and the short one is still offered
        XCTAssertEqual(prediction?.words.first, "restaurant")
        XCTAssertTrue(prediction?.words.contains("a") ?? false)
    }

    func test_aHardToSpellWordWinsATieWithAnEasyOne() {
        var sources = sources()
        sources.isHardToSpell = { $0 == "bank" }

        let prediction = NextWordPredictor.predict(textBefore: "We go to ", sources: sources)

        XCTAssertEqual(prediction?.words.first, "bank")
    }

    func test_otherLanguages_hideTheStripButForeignNamesDoNot() {
        XCTAssertTrue(NextWordPredictor.isOtherLanguage("Ich habe keine Zeit ", model: model))
        XCTAssertTrue(NextWordPredictor.isOtherLanguage("Привет как ", model: model))
        XCTAssertFalse(NextWordPredictor.isOtherLanguage("I want to go to Cancún ", model: model))
    }

    func test_wordsFromTheSupplement_doNotReadAsAnotherLanguage() {
        // #given two English words in a row that the n-gram table has no entry for
        let text = "the zorbling quexel "
        XCTAssertTrue(NextWordPredictor.isOtherLanguage(text, model: model))

        // #when the supplement knows them
        let known: Set<String> = ["zorbling", "quexel"]

        // #then the text is still English and the strip keeps predicting
        XCTAssertFalse(NextWordPredictor.isOtherLanguage(text, model: model, isKnownWord: known.contains))
    }

    func test_allCapsTyping_readsAsWordsAndPredictsInCaps() {
        let prediction = NextWordPredictor.predict(textBefore: "I WANT TO ", sources: sources())

        XCTAssertEqual(prediction?.words.first, "BE")
    }

    // MARK: - Capitals: one acronym is not shouting

    func test_oneAcronym_doesNotPutTheStripInCapitals() {
        // #given an ordinary sentence that ends in an acronym
        let prediction = NextWordPredictor.predict(textBefore: "We want to use NASA ", sources: sources())

        // #then the next word is offered in lowercase
        XCTAssertEqual(prediction?.words.first, "the")
    }

    func test_twoAcronymsAfterALowercaseWord_doNotPutTheStripInCapitals() {
        // #given two all-caps words in a row inside a lowercase sentence
        let prediction = NextWordPredictor.predict(textBefore: "We want the REST API ", sources: sources())

        // #then the sentence is still not shouted
        XCTAssertEqual(prediction?.words.first, "the")
    }

    func test_textOfNothingButKnownAcronyms_doesNotPutTheStripInCapitals() {
        // #given a text that is two words always written in capitals
        var sources = sources()
        sources.usualCapitals = { ["json": "JSON", "api": "API"][$0] }

        // #when predicting after them
        let prediction = NextWordPredictor.predict(textBefore: "JSON API ", sources: sources)

        // #then they say nothing about caps lock
        XCTAssertEqual(prediction?.words.first, "the")
    }

    func test_wordsInCapitals_putTheStripInCapitals() {
        // #given a writer in caps lock, three words in
        let prediction = NextWordPredictor.predict(textBefore: "THIS IS GREAT ", sources: sources())

        // #then the strip follows
        XCTAssertEqual(prediction?.words.first, "THE")
    }

    func test_aOneLetterWordInACapsLockSentence_keepsTheStripInCapitals() {
        // #given capitals that end in `A`, which is a capital in any sentence
        let prediction = NextWordPredictor.predict(textBefore: "THIS IS A ", sources: sources())

        // #then the words before it still decide
        XCTAssertEqual(prediction?.words.first, "THE")
    }

    func test_capitalLetterTypedInACapsLockSentence_isCompletedInCapitals() {
        let prediction = NextWordPredictor.predict(textBefore: "THIS IS G", sources: sources())

        XCTAssertEqual(prediction?.words.first, "GOOD")
    }

    func test_capitalLetterTypedAfterOneAcronym_isCompletedAsACapitalizedWord() {
        // #given one capital typed after an acronym: the start of a name, not caps lock
        let prediction = NextWordPredictor.predict(textBefore: "We want NASA G", sources: sources())

        // #then only the first letter is a capital
        XCTAssertEqual(prediction?.words.first, "Good")
    }

    func test_threeCapitalsTyped_areCompletedInCapitals_whateverCameBefore() {
        // #given a word begun in capitals with nothing in capitals before it
        let prediction = NextWordPredictor.predict(
            textBefore: "I think BEC", sources: sources(completions: ["because", "became"])
        )

        // #then a pick keeps the writer's capitals
        XCTAssertEqual(prediction?.words, ["BECAUSE", "BECAME"])
    }

    func test_twoCapitalsTyped_areAShiftHeldTooLong_notCapsLock() {
        let prediction = NextWordPredictor.predict(textBefore: "GR", sources: sources())

        XCTAssertEqual(prediction?.words, ["Great"])
    }

    // MARK: - Abbreviations do not end a sentence

    func test_dotOfAnAbbreviation_doesNotStartASentence() {
        // #given texts whose last dot belongs to `e.g.`, `i.e.` or `vs.`, one of them in a bracket
        for text in ["We want e.g. ", "We want (i.e. ", "We want it vs. "] {
            let prediction = NextWordPredictor.predict(textBefore: text, sources: sources())

            // #then the next word continues the sentence in lowercase
            XCTAssertEqual(prediction?.words.first, "the", text)
        }
    }

    func test_noWithADot_isTheWordNo_andEndsTheSentence() {
        // #given `No.`, which the abbreviation list has for `no. 5` but which before a word is an answer
        let prediction = NextWordPredictor.predict(textBefore: "We want it? No. ", sources: sources())

        // #then a new sentence starts
        XCTAssertEqual(Set(prediction?.words.prefix(2) ?? []), ["I", "The"])
    }

    // MARK: - A word begun after an opening single quote

    func test_wordBegunAfterASingleQuote_isCompletedLikeAfterADoubleQuote() {
        // #given the same word begun against each kind of opening quote
        let afterSingle = NextWordPredictor.predict(textBefore: "I want 't", sources: sources())
        let afterDouble = NextWordPredictor.predict(textBefore: "I want \"t", sources: sources())

        // #then both are completed, and the quote is not part of the letters a pick replaces
        XCTAssertEqual(afterSingle, afterDouble)
        XCTAssertEqual(afterSingle, NextWordPrediction(prefix: "t", words: ["to", "the"]))
    }

    func test_apostropheInsideAWord_stillBelongsToTheWord() {
        let prediction = NextWordPredictor.predict(textBefore: "We don't k", sources: sources())

        XCTAssertEqual(prediction?.words.first, "know")
    }

    func test_singleQuoteWithNoLetterYet_getsNoSuggestions_likeADoubleQuote() {
        XCTAssertNil(NextWordPredictor.predict(textBefore: "I want '", sources: sources()))
    }

    // MARK: - Pieces of words are not words

    func test_piecesOfNumbers_areNeverOffered_withOrWithoutTheLanguageModel() {
        // #given a table that counted `5th`, `1990s`, `1st`, `5h` and `49ers` as a number and then a "word"
        let table = NextWordModelFixture.make([
            "<num>": (100, [("years", 40), ("th", 30), ("s", 10), ("st", 8), ("h", 5), ("a", 4), ("ers", 3)])
        ])
        let text = "It took 5 "
        let model = LanguageModelFixture.scores(textBefore: text, ["th": 0.5, "years": 0.2, "s": 0.1])
        func predict(_ languageModel: LanguageModelScores?) -> [String]? {
            NextWordPredictor.predict(textBefore: text, sources: NextWordPredictor.Sources(
                model: table,
                completions: { _, _ in [] },
                personal: { _ in nil },
                languageModel: { _ in languageModel }
            ))?.words
        }

        // #then only the words are left
        XCTAssertEqual(predict(nil), ["years", "a"])
        XCTAssertEqual(predict(model), ["years", "a"])
    }

    // MARK: - Ordinals and joined words are English

    func test_numbersWithLettersOnThem_doNotReadAsAnotherLanguage() {
        // #given two ordinals among the last four words
        let text = "we go 1st to 2nd "

        // #then the strip keeps predicting
        XCTAssertFalse(NextWordPredictor.isOtherLanguage(text, model: model))
    }

    func test_hyphenatedEnglishWords_doNotReadAsAnotherLanguage() {
        // #given two hyphenated words whose parts are English words
        let known: Set<String> = ["well", "known", "long", "term"]

        // #then neither counts as foreign
        XCTAssertFalse(NextWordPredictor.isOtherLanguage("a well-known, long-term ", model: model, isKnownWord: known.contains))
    }

    func test_hyphenatedWordsWithNoEnglishPart_stillReadAsAnotherLanguage() {
        XCTAssertTrue(NextWordPredictor.isOtherLanguage("the zorb-quexel blar-fnop ", model: model))
    }

    func test_aSlipInThePrefixStillOffersTheWord() {
        // #given "gonig" is typed where "going" was meant
        var sources = sources()
        sources.fuzzyCompletions = { prefix, _ in prefix == "gon" ? ["going", "gone"] : [] }

        // #when predicting after the slip
        let prediction = NextWordPredictor.predict(textBefore: "I am gon", sources: sources)

        // #then the forgiven completions are offered
        XCTAssertEqual(prediction?.words.contains("going"), true)
    }

    func test_shortPrefixes_areNotForgiven() {
        var sources = sources()
        sources.fuzzyCompletions = { _, _ in ["zebra"] }

        let prediction = NextWordPredictor.predict(textBefore: "I want to g", sources: sources)

        XCTAssertEqual(prediction?.words.contains("zebra"), false)
    }

    func test_contextTokens_matchTheBuilderRules() {
        XCTAssertEqual(
            NextWordPredictor.contextTokens(of: "I don’t know Sam at 5"),
            ["<s>", "i", "don't", "know", "<name>", "at", "<num>"]
        )
    }

    func test_bundledModel_loadsAndPredictsEverydayEnglish() throws {
        let bundled = try XCTUnwrap(NextWordModel.bundled())
        let prediction = NextWordPredictor.predict(
            textBefore: "I would like ",
            sources: NextWordPredictor.Sources(
                model: bundled,
                completions: { _, _ in [] },
                personal: { _ in nil }
            )
        )

        XCTAssertEqual(prediction?.words.first, "to")
    }

    // MARK: - The writer's habits in the order

    /// Sources for a writer who has typed `total` words: `own` counts of their words, `after`
    /// counts following the one word before, `spread` in how many texts each appeared.
    private func writer(
        total: Int, own: [String: Int] = [:], after: [String: Int] = [:], afterTotal: Int = 0,
        spread: [String: Int] = [:], general: [String: Int] = [:], habits: NextWordPredictor.Habits = .init()
    ) -> NextWordPredictor.Sources {
        var sources = NextWordPredictor.Sources(
            model: NextWordModelFixture.make(["": (10, [("the", 10)])]),
            completions: { _, _ in [] },
            personal: { context in context.count == 1 && afterTotal > 0 ? (afterTotal, after) : nil }
        )
        sources.personalWords = { prefix in (total, own.filter { $0.key.hasPrefix(prefix) }) }
        sources.personalTotal = { total }
        sources.personalSpread = { spread[$0] ?? own[$0] ?? 0 }
        sources.generalCount = { general[$0] ?? 0 }
        sources.mix.habits = habits
        return sources
    }

    /// `signal` is common in general English and `stanza` is rare; counts as in the bundled list.
    private let general = ["signal": 30_000_000, "stanza": 300_000, "still": 300_000_000]

    func test_habits_nothingLearned_leavesTheScoresAlone() {
        // #given a writer who has typed nothing yet
        let scores = ["still": -2.0, "stanza": -3.0]

        // #when the habits are added
        let result = NextWordPredictor.withWritersHabits(scores, prefix: "st", context: ["the"], sources: writer(total: 0, general: general))

        // #then the order is the model's
        XCTAssertEqual(result, scores)
    }

    func test_habits_aWordTheWriterUsesFarMoreThanEnglishDoes_gains() {
        // #given 2,000 words typed, a rare word among them eight times in eight texts
        let sources = writer(total: 2_000, own: ["stanza": 8], general: general)

        // #when it competes with a common word the model prefers by a little
        let result = NextWordPredictor.withWritersHabits(["still": -2.0, "stanza": -3.0], prefix: "st", context: [], sources: sources)

        // #then the writer's word comes first
        XCTAssertGreaterThan(result["stanza"] ?? -.infinity, result["still"] ?? .infinity)
    }

    func test_habits_aCommonWordTypedOften_gainsNothing() {
        // #given a word typed as often as general English would have it (300M of 542G is 1.1 per 2,000)
        let sources = writer(total: 2_000, own: ["still": 1], general: general)

        // #when the habits are added
        let result = NextWordPredictor.withWritersHabits(["still": -2.0], prefix: "st", context: [], sources: sources)

        // #then its score has hardly moved
        XCTAssertEqual(result["still"] ?? 0, -2.0, accuracy: 0.05)
    }

    func test_habits_doNotOverturnAModelThatIsSure() {
        // #given the same habit, and a model that finds the other word 400 times likelier
        let sources = writer(total: 2_000, own: ["stanza": 8], general: general)

        // #when the habits are added
        let result = NextWordPredictor.withWritersHabits(["still": -1.0, "stanza": -7.0], prefix: "st", context: [], sources: sources)

        // #then the model's word stays first
        XCTAssertGreaterThan(result["still"] ?? -.infinity, result["stanza"] ?? .infinity)
    }

    func test_habits_aBurstInOneText_countsAsAFewUses() {
        // #given the same word typed 60 times, once in 20 texts and once all in one text
        let scores = ["stanza": -3.0]
        let habit = writer(total: 2_000, own: ["stanza": 60], spread: ["stanza": 20], general: general)
        let burst = writer(total: 2_000, own: ["stanza": 60], spread: ["stanza": 1], general: general)

        // #when the habits are added
        let asHabit = NextWordPredictor.withWritersHabits(scores, prefix: "st", context: [], sources: habit)["stanza"] ?? 0
        let asBurst = NextWordPredictor.withWritersHabits(scores, prefix: "st", context: [], sources: burst)["stanza"] ?? 0

        // #then the burst gains clearly less
        XCTAssertLessThan(asBurst, asHabit - 1)
    }

    func test_habits_whatTheWriterWroteAfterTheSameWord_gains() {
        // #given a writer who wrote `signal` after `the` six times, in six texts, of 40 uses of `the`
        let sources = writer(total: 2_000, after: ["signal": 6], afterTotal: 40, spread: ["signal": 6], general: general)

        // #when no letter is typed yet after `the`
        let result = NextWordPredictor.withWritersHabits(["signal": -4.0, "same": -4.0], prefix: "", context: ["the"], sources: sources)

        // #then their phrase is ahead of a word the model finds as likely
        XCTAssertGreaterThan(result["signal"] ?? -.infinity, result["same"] ?? .infinity)
    }

    func test_habits_aSightingAfterAWordWrittenAllDay_countsForLess() {
        // #given one sighting after a context seen 20 times, and one after a context seen 2,000 times
        let scores = ["signal": -4.0]
        let rare = writer(total: 5_000, after: ["signal": 1], afterTotal: 20, spread: ["signal": 1], general: general)
        let common = writer(total: 5_000, after: ["signal": 1], afterTotal: 2_000, spread: ["signal": 1], general: general)

        // #when the habits are added
        let afterRare = NextWordPredictor.withWritersHabits(scores, prefix: "", context: ["x"], sources: rare)["signal"] ?? 0
        let afterCommon = NextWordPredictor.withWritersHabits(scores, prefix: "", context: ["x"], sources: common)["signal"] ?? 0

        // #then the first says more
        XCTAssertGreaterThan(afterRare, afterCommon + 0.1)
    }

    func test_habitsOff_leavesTheScoresAlone() {
        // #given a writer with habits, and the habits turned off
        let sources = writer(total: 2_000, own: ["stanza": 8], general: general, habits: .off)
        let scores = ["still": -2.0, "stanza": -3.0]

        // #then nothing moves
        XCTAssertEqual(NextWordPredictor.withWritersHabits(scores, prefix: "st", context: [], sources: sources), scores)
    }

    func test_generalWordTotal_isTheSumOfTheBundledFrequencyDictionary() throws {
        // #given the dictionary the app ships
        let url = try XCTUnwrap(Bundle(for: SymSpellCorrector.self).url(forResource: "frequency_dictionary_en_82_765", withExtension: "txt")
            ?? Bundle.main.url(forResource: "frequency_dictionary_en_82_765", withExtension: "txt"))
        let contents = try String(contentsOf: url, encoding: .utf8)

        // #when its counts are added up
        let total = contents.split(separator: "\n").reduce(0.0) { sum, line in
            sum + (line.split(separator: " ").last.flatMap { Double($0) } ?? 0)
        }

        // #then the constant the habits divide by is that sum
        XCTAssertEqual(total, NextWordPredictor.generalWordTotal, accuracy: NextWordPredictor.generalWordTotal * 0.001)
    }
}

/// Encodes a table in the `CNW1` layout `Tools/ngram/export_binary.py` writes, so tests exercise the
/// real memory-mapped reader.
enum NextWordModelFixture {
    static func make(_ table: [String: (total: Int, entries: [(String, Int)])]) -> NextWordModel {
        var vocabulary = ["<s>", "<name>", "<num>"]
        func id(_ word: String) -> UInt16 {
            if let index = vocabulary.firstIndex(of: word) { return UInt16(index) }
            vocabulary.append(word)
            return UInt16(vocabulary.count - 1)
        }
        let rows = table.map { context, value in
            let ids = context.split(separator: " ").map { id(String($0)) }
            return (hash: NextWordModel.contextHash(ids), total: value.total, entries: value.entries.map { (id($0.0), $0.1) })
        }.sorted { $0.hash < $1.hash }
        var data = Data("CNW1".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let entryCount = rows.reduce(0) { $0 + $1.entries.count }
        append(UInt32(vocabulary.count))
        append(UInt32(rows.count))
        append(UInt32(entryCount))
        for word in vocabulary {
            data.append(UInt8(word.utf8.count))
            data.append(contentsOf: Array(word.utf8))
        }
        rows.forEach { append($0.hash) }
        rows.forEach { append(UInt32($0.total)) }
        var start: UInt32 = 0
        for row in rows {
            append(start)
            start += UInt32(row.entries.count)
        }
        append(start)
        rows.forEach { $0.entries.forEach { append($0.0) } }
        rows.forEach { $0.entries.forEach { append(UInt16($0.1)) } }
        return NextWordModel(data: data)!
    }
}
