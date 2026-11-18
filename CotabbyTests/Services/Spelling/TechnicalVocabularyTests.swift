import XCTest
@testable import Cotabby

/// The bundled software-engineering word lists: what is in them, what is kept out of the spelling
/// dictionary, and the switch.
final class TechnicalVocabularyTests: XCTestCase {
    private func lines(_ name: String) throws -> [[Substring]] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "txt"), "\(name).txt is not in the app")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .filter { !$0.hasPrefix("#") }.map { $0.split(separator: " ") }
    }

    private func generalDictionary() throws -> Set<String> {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "frequency_dictionary_en_82_765", withExtension: "txt"))
        return Set(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) })
    }

    func test_stripList_isLowercaseWordsWithCounts() throws {
        let strip = try lines(TechnicalVocabulary.stripListName)

        XCTAssertGreaterThan(strip.count, 700)
        for fields in strip {
            XCTAssertTrue(fields.count == 2 || fields.count == 3, "\(fields)")
            XCTAssertTrue(fields[0].allSatisfy { $0.isLowercase && $0.isASCII }, "\(fields[0])")
            XCTAssertNotNil(Int(fields[1]), "\(fields)")
            // The usual capitals are the same word, only recased.
            if fields.count == 3 { XCTAssertEqual(fields[2].lowercased(), String(fields[0])) }
        }
    }

    func test_spellingList_takesOnlyLongerTermsTheDictionaryLacks() throws {
        // #given the terms the spelling dictionary is given
        let spelling = try lines(TechnicalVocabulary.spellingListName).map { String($0[0]) }
        let strip = Set(try lines(TechnicalVocabulary.stripListName).map { String($0[0]) })
        let dictionary = try generalDictionary()

        // #then they are all strip terms, none is a word the dictionary already has (whose count
        // must not be touched), and the short ones are few and chosen
        XCTAssertGreaterThan(spelling.count, 250)
        XCTAssertTrue(Set(spelling).isSubset(of: strip))
        XCTAssertEqual(spelling.filter { dictionary.contains($0) }, [])
        XCTAssertEqual(Set(spelling.filter { $0.count < 5 }), ["json", "yaml", "html", "http", "repo", "enum", "sudo"])
    }

    func test_shortTermsThatAreCommonSlips_stayOutOfTheSpellingDictionary() throws {
        // `aws` is how `was` comes out with two keys swapped, `iam` is `I am` run together, and
        // `util` is `until` with a letter dropped: as dictionary words they would make those slips
        // look right.
        let spelling = Set(try lines(TechnicalVocabulary.spellingListName).map { String($0[0]) })

        XCTAssertTrue(spelling.isDisjoint(with: ["aws", "iam", "util", "env", "api", "sso", "slo", "ide"]))
        XCTAssertTrue(spelling.isSuperset(of: ["backend", "frontend", "kubectl", "jsonb", "config", "async", "kubernetes", "upsert"]))
    }

    func test_capitals_areGivenToNamesAndAcronyms_notToOrdinaryWords() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: TechnicalVocabulary.stripListName, withExtension: "txt"))
        let capitals = TechnicalVocabulary.capitals(inStripList: try String(contentsOf: url, encoding: .utf8))

        XCTAssertEqual(capitals["github"], "GitHub")
        XCTAssertEqual(capitals["json"], "JSON")
        XCTAssertEqual(capitals["postgresql"], "PostgreSQL")
        XCTAssertEqual(capitals["python"], "Python")
        XCTAssertNil(capitals["kubectl"])
        // Also ordinary English: capitalizing these would spoil every sentence about the weather.
        for word in ["swift", "spring", "react", "rust", "ruby", "node", "spark", "slack", "express", "lambda"] {
            XCTAssertNil(capitals[word], word)
        }
    }

    func test_switch_isOnUntilTurnedOff_andOffMeansNoLists() {
        let suiteName = "cotabby.test.technical.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(TechnicalVocabulary.isEnabled(in: defaults))
        XCTAssertNotNil(TechnicalVocabulary.stripListURL(defaults: defaults))
        XCTAssertTrue(TechnicalVocabulary.spellingTerms(defaults: defaults).contains("backend"))

        defaults.set(false, forKey: TechnicalVocabulary.enabledDefaultsKey)

        XCTAssertNil(TechnicalVocabulary.stripListURL(defaults: defaults))
        XCTAssertEqual(TechnicalVocabulary.spellingLines(defaults: defaults), "")
        XCTAssertEqual(TechnicalVocabulary.spellingTerms(defaults: defaults), [])
    }
}
