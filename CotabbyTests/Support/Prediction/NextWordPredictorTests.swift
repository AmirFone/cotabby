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
        personal: [String: [String: Int]] = [:]
    ) -> NextWordPredictor.Sources {
        NextWordPredictor.Sources(
            model: model,
            completions: { prefix, limit in Array(completions.filter { $0.hasPrefix(prefix) }.prefix(limit)) },
            personal: { context in
                personal[context.joined(separator: " ")].map { ($0.values.reduce(0, +), $0) }
            }
        )
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
