import XCTest
@testable import Cotabby

final class CaseSlipTests: XCTestCase {
    private let words: Set<String> = ["the", "hello", "king", "llama", "lama", "ids", "there", "don't"]
    private func fix(_ word: String) -> String? {
        CaseSlip.fix(for: word, isWord: { self.words.contains($0) })
    }

    func test_shiftHeldOneLetterTooLong() {
        XCTAssertEqual(fix("THe"), "The")
        XCTAssertEqual(fix("HEllo"), "Hello")
        XCTAssertEqual(fix("DOn't"), "Don't")
    }

    func test_shiftPressedOneLetterTooLate() {
        XCTAssertEqual(fix("kKing"), "King")
        XCTAssertEqual(fix("tThe"), "The")
        XCTAssertEqual(fix("Tthe"), "The")
    }

    func test_leavesAcronymsUnitsNamesAndRealWordsAlone() {
        XCTAssertNil(fix("IDs"))
        XCTAssertNil(fix("MHz"))
        XCTAssertNil(fix("USA"))
        XCTAssertNil(fix("iPhone"))
        XCTAssertNil(fix("McDonald"))
        XCTAssertNil(fix("Llama"))
        XCTAssertNil(fix("The"))
        XCTAssertNil(fix("the"))
        XCTAssertNil(fix("THERE"))
        XCTAssertNil(fix("ZZzzq"))
    }

    // MARK: - Words that only have the shape of a slip

    /// A dictionary that, like the bundled one, holds units, plurals and brand names in lowercase,
    /// and a caller that knows how each recased word is written. `Ghz` and `Oses` are missing from
    /// the spellings because nobody writes them.
    private let lowercaseEntries: Set<String> = ["the", "king", "ghz", "oses", "oauth", "iphone", "json"]
    private let spellings = ["The": "The", "King": "King", "Oauth": "OAuth", "Iphone": "iPhone", "Json": "JSON"]
    private func fixAsWritten(_ word: String) -> String? {
        CaseSlip.fix(for: word, isWord: { self.lowercaseEntries.contains($0) }, acceptedSpelling: { self.spellings[$0] })
    }

    func test_twoCapitals_whoseRecasingIsNotAnAcceptedWord_areLeftAsTyped() {
        // #given a unit and a plural acronym: the dictionary has `ghz` and `oses`, but nobody
        // writes `Ghz` or `Oses`

        // #when they are checked for a Shift slip
        let fixes = ["GHz", "OSes"].map(fixAsWritten)

        // #then neither is touched
        XCTAssertEqual(fixes, [nil, nil])
    }

    func test_termTypedInItsKnownCapitals_isLeftAsTyped() {
        // #given a term whose known form is two capitals and then lowercase

        // #when it is typed exactly that way
        let fix = fixAsWritten("OAuth")

        // #then it is not recased to `Oauth`
        XCTAssertNil(fix)
    }

    func test_slipInAWordWithKnownCapitals_isFixedToThoseCapitals() {
        // #given words the caller knows with capitals of their own (iPhone, JSON)

        // #when Shift was held one letter too long, or the first letter was typed twice
        let fixes = ["IPhone", "JSon", "jJson"].map(fixAsWritten)

        // #then the fix is the known form, never the plain capital (`Iphone`, `Json`)
        XCTAssertEqual(fixes, ["iPhone", "JSON", "JSON"])
    }

    func test_ordinarySlips_areStillFixed_whenTheCallerChecksTheSpelling() {
        // #given ordinary words the caller accepts as they stand

        // #when Shift was held too long, or pressed too late
        let fixes = ["THe", "kKing"].map(fixAsWritten)

        // #then they are fixed as before
        XCTAssertEqual(fixes, ["The", "King"])
    }
}
