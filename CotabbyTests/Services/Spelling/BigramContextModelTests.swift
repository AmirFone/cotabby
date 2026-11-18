import XCTest
@testable import Cotabby

/// The word-pair table is read as bytes for speed. These pin that reading to the plain one it
/// replaced, on the real file and on the odd lines a file could contain.
final class BigramContextModelTests: XCTestCase {
    /// The table as the original line-by-line reading builds it.
    private func reference(_ contents: String) -> [String: Int64] {
        var result: [String: Int64] = [:]
        contents.enumerateLines { line, _ in
            if let (key, count) = BigramContextModel.parseLine(line) { result[key] = count }
        }
        return result
    }

    func test_bundledFile_readAsBytes_isTheSameTable() throws {
        // #given the bundled list of word pairs
        let url = try XCTUnwrap(Bundle.main.url(forResource: "frequency_bigramdictionary_en_243_342", withExtension: "txt"))
        let contents = try String(contentsOf: url, encoding: .utf8)

        // #when it is read both ways
        let fast = BigramContextModel.parse(contents)

        // #then nothing differs, and the table is the size the file's name says
        XCTAssertEqual(fast, reference(contents))
        XCTAssertGreaterThan(fast.count, 240_000)
    }

    func test_oddLines_areReadAsBefore() {
        // #given lines in every shape that is not `word word digits`
        let contents = [
            "know which 500", "two  spaces 7", "tab\tseparated 9", "carriage return 11\r", "caf\u{E9} noir 13",
            "signed count -4", "plus count +6", "only two", "four fields here 3", " leading space 5",
            "trailing space 5 ", "", "not a number x", "huge count 99999999999999999999", "last line 21",
        ].joined(separator: "\n")

        // #then both readings agree line for line
        XCTAssertEqual(BigramContextModel.parse(contents), reference(contents))
        XCTAssertEqual(BigramContextModel.parse(contents)["know which"], 500)
        XCTAssertEqual(BigramContextModel.parse(contents)["last line"], 21)
    }

    func test_count_answersFromTheParsedTable() {
        let model = BigramContextModel(contents: "know which 500\nwent there 90\n")

        XCTAssertEqual(model.count(first: "Know", second: "WHICH"), 500)
        XCTAssertEqual(model.count(first: "went", second: "their"), 0)
    }
}
