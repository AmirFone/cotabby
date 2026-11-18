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

    func test_spellingList_takesOnlyTermsTheDictionaryLacks() throws {
        // #given the terms the spelling dictionary is given
        let spelling = try lines(TechnicalVocabulary.spellingListName).map { String($0[0]) }
        let strip = Set(try lines(TechnicalVocabulary.stripListName).map { String($0[0]) })
        let dictionary = try generalDictionary()

        // #then they are all strip terms, and none is a word the dictionary already has (whose
        // count must not be touched) or a two-letter term
        XCTAssertGreaterThan(spelling.count, 250)
        XCTAssertTrue(Set(spelling).isSubset(of: strip))
        XCTAssertEqual(spelling.filter { dictionary.contains($0) }, [])
        XCTAssertEqual(spelling.filter { $0.count < 3 }, [])
    }

    func test_shortTerms_areAcceptedAsTyped_andOnlyTheChosenSevenAreFixedToward() throws {
        // A term of three or four letters is one slip from too many ordinary words to be what a slip
        // is fixed to. All but seven have a count under the engine's common-word floor (about half
        // a million): `ttl` and `sdk` are no longer flagged, and `sad` mistyped is not offered `sdk`.
        let short = try lines(TechnicalVocabulary.spellingListName).filter { $0[0].count < 5 }
        let fixedToward = short.filter { (Int($0[1]) ?? 0) > 200_000 }.map { String($0[0]) }

        XCTAssertEqual(Set(fixedToward), ["json", "yaml", "html", "http", "repo", "enum", "sudo"])
        XCTAssertTrue(Set(short.map { String($0[0]) }).isSuperset(of: ["ttl", "sdk", "gcp", "rpc", "cdn", "uid", "saml", "nuxt", "grpc"]))
    }

    func test_termsThatAreCommonSlips_stayOutOfTheSpellingDictionary() throws {
        // `aws` is how `was` comes out with two keys swapped, `iam` is `I am` run together, `util`
        // is `until` with a letter dropped, `paas` is `pass` with the key beside it, `systemd` is
        // `systems` the same way and `cors` is `course` spelled by sound: as dictionary words they
        // would make those slips look right.
        let spelling = Set(try lines(TechnicalVocabulary.spellingListName).map { String($0[0]) })

        XCTAssertTrue(spelling.isDisjoint(with: ["aws", "iam", "util", "env", "api", "sso", "slo", "ide"]))
        XCTAssertTrue(spelling.isDisjoint(with: ["cors", "asan", "paas", "systemd", "elt", "aks"]))
        XCTAssertTrue(spelling.isSuperset(of: ["backend", "frontend", "kubectl", "jsonb", "config", "async", "kubernetes", "upsert"]))
        XCTAssertTrue(spelling.isSuperset(of: ["tokio", "reqwest", "thiserror", "serde", "asyncio", "kwargs"]))
    }

    func test_capitals_areGivenToNamesAndAcronyms_notToOrdinaryWords() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: TechnicalVocabulary.stripListName, withExtension: "txt"))
        let capitals = TechnicalVocabulary.capitals(inStripList: try String(contentsOf: url, encoding: .utf8))

        XCTAssertEqual(capitals["github"], "GitHub")
        XCTAssertEqual(capitals["json"], "JSON")
        XCTAssertEqual(capitals["postgresql"], "PostgreSQL")
        XCTAssertEqual(capitals["python"], "Python")
        XCTAssertEqual(capitals["uuid"], "UUID")
        XCTAssertNil(capitals["kubectl"])
        // Their projects write these in lowercase, so the strip must not capitalize them.
        for word in ["pytest", "nginx", "webpack", "minikube", "reqwest"] {
            XCTAssertNil(capitals[word], word)
        }
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
