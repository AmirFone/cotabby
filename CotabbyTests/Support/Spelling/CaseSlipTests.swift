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
}
