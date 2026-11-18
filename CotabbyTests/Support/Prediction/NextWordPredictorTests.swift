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
