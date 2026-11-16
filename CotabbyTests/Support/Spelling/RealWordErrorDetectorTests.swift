import XCTest
@testable import Cotabby

/// The sentence-model rule for correctly spelled wrong words: flag only when an alternative clearly
/// fits the sentence better, and veto when the typed word fits.
final class RealWordErrorDetectorTests: XCTestCase {
    func test_alternativeMuchLikelierAfterTheSentence_isFlagged() {
        // #given "their" is rare here and "there" is likely
        let scores = ["their": 0.001, "there": 0.2, "they're": 0.0]

        // #when judging the typed word
        let verdict = RealWordErrorDetector.sentenceVerdict(word: "their", score: { scores[$0] ?? 0 })

        // #then "there" is offered and the typed word does not fit
        XCTAssertEqual(verdict.flagged.first?.term, "there")
        XCTAssertFalse(verdict.typedFits)
    }

    func test_typedWordThatFits_vetoesAnyFlag() {
        let scores = ["it's": 0.3, "its": 0.2]

        let verdict = RealWordErrorDetector.sentenceVerdict(word: "it's", score: { scores[$0] ?? 0 })

        XCTAssertTrue(verdict.typedFits)
    }

    func test_rareAlternative_isNotFlagged() {
        let scores = ["form": 0.0, "from": 0.005]

        let verdict = RealWordErrorDetector.sentenceVerdict(word: "form", score: { scores[$0] ?? 0 })

        XCTAssertTrue(verdict.flagged.isEmpty)
    }

    func test_wordOutsideAnyGroup_isAlwaysFine() {
        let verdict = RealWordErrorDetector.sentenceVerdict(word: "banana", score: { _ in 0 })

        XCTAssertTrue(verdict.flagged.isEmpty)
        XCTAssertTrue(verdict.typedFits)
    }
}
