import AppKit
import XCTest
@testable import Cotabby

/// Runs the real English dictionary and the real macOS spell checker through the confidence tiers,
/// so threshold changes are judged against actual dyslexic misspellings instead of hand-built scores.
@MainActor
final class SpellingCorrectionCalibrationTests: XCTestCase {
    private static var corrector: SymSpellCorrector?
    private static var bigrams: BigramContextModel?

    private func loadedBigrams() throws -> BigramContextModel {
        if let bigrams = Self.bigrams { return bigrams }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "frequency_bigramdictionary_en_243_342", withExtension: "txt"))
        let bigrams = BigramContextModel(contents: try String(contentsOf: url, encoding: .utf8))
        Self.bigrams = bigrams
        return bigrams
    }

    private func loadedCorrector() throws -> SymSpellCorrector {
        if let corrector = Self.corrector { return corrector }
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "frequency_dictionary_en_82_765", withExtension: "txt")
                ?? Bundle.main.url(forResource: "frequency_dictionary_en_82_765", withExtension: "txt", subdirectory: "SpellingDictionaries")
        )
        let corrector = SymSpellCorrector(preloadLanguage: nil)
        corrector.loadForTesting(contents: try String(contentsOf: url, encoding: .utf8))
        Self.corrector = corrector
        return corrector
    }

    private func decide(
        _ precedingText: String,
        personal: [String: Int] = [:],
        useContext: Bool = false
    ) throws -> TypoGateDecision {
        let corrector = try loadedCorrector()
        let checker = CurrentWordSpellChecker()
        let bigrams = useContext ? try loadedBigrams() : nil
        let previous = CurrentWordExtractor.wordBeforeTrailingWord(in: precedingText)
        let contextCount: ((String) -> Int64?)? = bigrams.flatMap { model in
            previous.map { previous in { model.count(first: previous, second: $0) } }
        }
        return TypoGate.resolve(
            precedingText: precedingText,
            settings: TypoGate.Settings(
                suppressCompletionsOnTypo: true,
                offerTypoCorrections: true,
                automaticallyFixTypos: true
            ),
            isTypo: { checker.isTypo($0, language: "en") },
            isWordInProgress: { corrector.candidates(for: $0, includePrefixMatches: true)?.isCommonWordPrefix ?? false },
            candidates: { word, isMidWord in
                SpellingCandidateRanker.rank(
                    word: word,
                    isMidWord: isMidWord,
                    sources: corrector.candidates(for: word, includePrefixMatches: isMidWord) ?? .empty,
                    native: checker.nativeCorrections(for: word, language: "en"),
                    personal: personal,
                    contextCount: contextCount
                )
            },
            realWordCandidates: { word in
                guard let bigrams, let previous else { return [] }
                return RealWordErrorDetector.candidates(word: word, previous: previous) {
                    bigrams.count(first: $0, second: $1)
                }
            }
        )
    }

    private func describe(_ decision: TypoGateDecision) -> String {
        switch decision {
        case .proceed: return "proceed"
        case .suppress: return "suppress"
        case let .offerCorrection(_, fix): return "ghost(\(fix))"
        case let .applyCorrection(_, fix): return "AUTO(\(fix))"
        case let .offerRankedCorrection(_, list): return "ghost+down(" + list.map { "\($0.term):\(String(format: "%.2f", $0.score))" }.joined(separator: ", ") + ")"
        case let .offerChoices(_, list): return "LIST(" + list.map { "\($0.term):\(String(format: "%.2f", $0.score))" }.joined(separator: ", ") + ")"
        case let .offerRealWordFix(_, list): return "REALWORD(" + list.map(\.term).joined(separator: ", ") + ")"
        }
    }

    func test_printCalibrationTable() throws {
        let finished = ["teh ", "becuase ", "wich ", "recieve ", "definately ", "freind ", "thier ", "untill ",
                        "occured ", "seperate ", "wierd ", "beleive ", "tommorow ", "goverment ", "alot ",
                        "adress ", "necesary ", "probaly ", "diffrent ", "wen ", "hte ", "form "]
        let midWord = ["recie", "questoi", "rece", "becau", "definat", "tomm", "wha", "diffr", "thie"]
        var lines: [String] = []
        for text in finished + midWord {
            lines.append("\(text.debugDescription.padding(toLength: 16, withPad: " ", startingAt: 0)) \(describe(try decide("I think " + text)))")
        }
        print("=== CALIBRATION ===\n" + lines.joined(separator: "\n") + "\n=== END ===")
    }

    func test_classicTransposition_autoFixesAfterSpace() throws {
        XCTAssertEqual(try decide("I think teh "), .applyCorrection(word: "teh", correctedWord: "the"))
        XCTAssertEqual(try decide("I think becuase "), .applyCorrection(word: "becuase", correctedWord: "because"))
    }

    func test_ambiguousWord_opensChoiceList() throws {
        guard case let .offerChoices(_, candidates) = try decide("I think wich ") else {
            return XCTFail("Expected a choice list for wich")
        }
        XCTAssertTrue(candidates.map(\.term).contains("which"))
        XCTAssertTrue(candidates.map(\.term).contains("with"))
    }

    func test_correctPartialWord_proceedsSoTheModelCanFinishIt() throws {
        XCTAssertEqual(try decide("I think rece"), .proceed)
    }

    func test_misspelledPartialWord_offersCompletions() throws {
        let decision = try decide("I think recie")
        let terms: [String]
        switch decision {
        case let .offerChoices(_, list), let .offerRankedCorrection(_, list): terms = list.map(\.term)
        case let .offerCorrection(_, fix): terms = [fix]
        default: return XCTFail("Expected an offer for recie, got \(describe(decision))")
        }
        XCTAssertTrue(terms.contains { $0.hasPrefix("recei") }, "got \(terms)")
    }

    func test_personalHistory_promotesTheWritersUsualFix() throws {
        guard case .offerChoices = try decide("I think wich ") else { return XCTFail("precondition") }
        let decision = try decide("I think wich ", personal: ["which": 3])
        if case .offerChoices = decision {
            XCTFail("Three accepted fixes should lift which out of the list, got \(describe(decision))")
        }
    }

    func test_printContextCalibrationTable() throws {
        let cases = ["I don't know wich ", "the one with wich ", "I want to go their ", "It is different form ",
                     "more then ", "I went their ", "over there ", "I want to ", "we need to by ", "I new ",
                     "their house ", "thank you for you're ", "It's to much ", "I dont know wich one",
                     "please recieve ", "I will definately "]
        let lines = try cases.map { text in
            "\(text.debugDescription.padding(toLength: 28, withPad: " ", startingAt: 0)) \(describe(try decide(text, useContext: true)))"
        }
        print("=== CONTEXT CALIBRATION ===\n" + lines.joined(separator: "\n") + "\n=== END ===")
    }

    func test_previousWord_resolvesWichToWhich() throws {
        let decision = try decide("I don't know wich ", useContext: true)
        let top: String?
        switch decision {
        case let .applyCorrection(_, fix): top = fix
        case let .offerChoices(_, list), let .offerRankedCorrection(_, list): top = list.first?.term
        default: top = nil
        }
        XCTAssertEqual(top, "which", describe(decision))
    }

    func test_realWordSlip_offersTheIntendedWord() throws {
        XCTAssertEqual(
            try decide("I went their ", useContext: true),
            .offerRealWordFix(word: "their", candidates: [SpellingCandidate(term: "there", score: try realWordScore("went", "their", "there"))])
        )
        guard case let .offerRealWordFix(_, list) = try decide("It is different form ", useContext: true) else {
            return XCTFail("different form should be flagged")
        }
        XCTAssertEqual(list.first?.term, "from")
    }

    func test_correctRealWords_proceed() throws {
        XCTAssertEqual(try decide("over there ", useContext: true), .proceed)
        XCTAssertEqual(try decide("I want to ", useContext: true), .proceed)
        XCTAssertEqual(try decide("their house ", useContext: true), .proceed)
    }

    private func realWordScore(_ previous: String, _ typed: String, _ intended: String) throws -> Double {
        let bigrams = try loadedBigrams()
        return RealWordErrorDetector.candidates(word: typed, previous: previous) {
            bigrams.count(first: $0, second: $1)
        }.first { $0.term == intended }?.score ?? -1
    }
}
