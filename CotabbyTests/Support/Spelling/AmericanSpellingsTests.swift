import XCTest
@testable import Cotabby

/// The choice between two spellings of one word, and where it applies.
final class AmericanSpellingsTests: XCTestCase {
    private let spellings = AmericanSpellings(contents: "neighbour neighbor\nfavourite favorite\ntravelling traveling\nnot a pair\n")

    func test_britishSpelling_becomesTheAmericanOne_keepingItsCapitals() {
        XCTAssertEqual(spellings.american(for: "neighbour"), "neighbor")
        XCTAssertEqual(spellings.american(for: "Neighbour"), "Neighbor")
        XCTAssertEqual(spellings.american(for: "NEIGHBOUR"), "NEIGHBOR")
    }

    func test_anyOtherWord_isLeftAlone() {
        XCTAssertNil(spellings.american(for: "neighbor"))
        XCTAssertNil(spellings.american(for: "four"))
        XCTAssertNil(spellings.american(for: "not"))
    }

    func test_list_offersEachWordOnce_inItsFirstPlace() {
        // #given a list with both spellings of one word, the British one first
        let words = ["favourite", "favor", "favorite", "travelling"]

        // #then the American spelling takes the first place and is not repeated
        XCTAssertEqual(spellings.preferring(words), ["favorite", "favor", "traveling"])
    }

    func test_preference_followsTheRegion_unlessTheWriterChoseOtherwise() throws {
        let suite = "AmericanSpellingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // #given the list in the app bundle: on in the United States, off elsewhere
        XCTAssertNotNil(AmericanSpellings.preferredOnThisMac(defaults: defaults, region: "US"))
        XCTAssertNil(AmericanSpellings.preferredOnThisMac(defaults: defaults, region: "GB"))

        // #when the writer sets a style, it wins over the region
        defaults.set("british", forKey: AmericanSpellings.styleDefaultsKey)
        XCTAssertNil(AmericanSpellings.preferredOnThisMac(defaults: defaults, region: "US"))
        defaults.set("american", forKey: AmericanSpellings.styleDefaultsKey)
        XCTAssertNotNil(AmericanSpellings.preferredOnThisMac(defaults: defaults, region: "GB"))
    }

    func test_bundledList_hasTheCommonPairs_andNoneOfTheLookAlikes() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "american_spellings_en", withExtension: "txt"))
        let bundled = AmericanSpellings(contents: try String(contentsOf: url, encoding: .utf8))

        XCTAssertEqual(bundled.american(for: "colour"), "color")
        XCTAssertEqual(bundled.american(for: "organised"), "organized")
        XCTAssertEqual(bundled.american(for: "theatre"), "theater")
        // Different words that only look like a spelling pair.
        for word in ["four", "filled", "timbre", "scoured", "boeing", "tilled", "dialogue", "glamour"] {
            XCTAssertNil(bundled.american(for: word), word)
        }
    }

    func test_supplementLinesForSpelling_areTheCommonLongerWordsOnly() {
        // #given supplement lines: a common long word, a short one, a rare one, a contraction
        let contents = "neighbor 7829316\nmins 900000\nwhitespace 201000\nyou've 102919293\n"

        // #then only the first is safe to add to the spelling dictionary
        XCTAssertEqual(SymSpellCorrector.spellingLines(ofSupplement: contents), "neighbor 7829316")
    }
}
