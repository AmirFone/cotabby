import XCTest
@testable import Cotabby

/// Which of the words in a text are the writer's own (names, terms the dictionary lacks), and how
/// each should be written when it is offered back.
final class TextVocabularyTests: XCTestCase {
    private let dictionary: Set<String> = [
        "the", "and", "then", "asked", "about", "team", "told", "that", "for", "project", "lantern", "dana",
        "was", "late", "again", "moved", "after", "said", "will", "run", "engine", "our", "with"
    ]

    private func read(_ text: String) -> [TextVocabulary.Word] {
        TextVocabulary.read(text, isKnown: dictionary.contains)
    }

    func test_nameCapitalizedInsideASentence_isOfferedAfterOneUse() {
        // #given a name the dictionary lacks, used once, inside a sentence
        let words = read("Then the team asked Priyanka about the project.")

        // #then it is offered with its capital
        XCTAssertEqual(words, [.init(display: "Priyanka", lowercased: "priyanka", isNew: true)])
    }

    func test_unknownLowercaseWord_isOfferedOnlyFromItsSecondUse() {
        // #given a term used once: it may be a slip the writer has not corrected
        XCTAssertEqual(read("Then the cutover was late."), [])

        // #when it is used again
        let words = read("Then the cutover was late. The team moved the cutover.")

        // #then it is the writer's word
        XCTAssertEqual(words, [.init(display: "cutover", lowercased: "cutover", isNew: true)])
    }

    func test_unknownWordSeenOnlyAtSentenceStarts_needsTwoUsesAndKeepsItsCapital() {
        XCTAssertEqual(read("Priyanka asked about the project."), [])
        XCTAssertEqual(
            read("Priyanka asked about the project. Priyanka was late."),
            [.init(display: "Priyanka", lowercased: "priyanka", isNew: true)]
        )
    }

    func test_unknownWordWrittenInLowercaseToo_isOfferedInLowercase() {
        // #given a term that starts one sentence and sits inside another
        let words = read("Cutover was late. Then the team moved the cutover.")

        // #then the capital came from the sentence start, and the word itself is lowercase
        XCTAssertEqual(words.map(\.display), ["cutover"])
    }

    func test_acronym_keepsAllItsCapitals() {
        XCTAssertEqual(read("Then the ETL engine was late.").map(\.display), ["ETL"])
    }

    func test_possessive_countsAsAUseOfTheName_andItsEndingIsNotAWord() {
        // #given the name once on its own at a sentence start and once with an ending
        let words = read("Priyanka asked. Then the team told Priyanka's team that.")

        XCTAssertEqual(words.map(\.display), ["Priyanka"])
    }

    func test_stemOfANegativeContraction_isNotAWordOfTheWriters() {
        // #given `didn't` twice: read as `didn` plus an ending, that is a word the dictionary lacks, used twice
        let words = read("Then the team didn't run. The team didn’t run again.")

        // #then nothing is offered
        XCTAssertEqual(words, [])
    }

    func test_stemOfANegativeContractionInCapitals_isNotOfferedAsAnAcronym() {
        // #given the contraction in capitals inside a sentence, where one use is enough for a name
        let words = read("Then the team DIDN'T run.")

        // #then it is still no word
        XCTAssertEqual(words, [])
    }

    func test_dictionaryWordCapitalizedInsideSentencesTwice_isRespelledNotNew() {
        // #given `lantern`, a dictionary word, used as a project name
        let words = read("Then the team moved Lantern. Then the team told Dana that Lantern was late.")

        // #then it is to be shown with its capital; one capitalized use (Dana) is not enough
        XCTAssertEqual(words, [.init(display: "Lantern", lowercased: "lantern", isNew: false)])
    }

    func test_dictionaryWordAlsoWrittenInLowercase_keepsItsOrdinarySpelling() {
        XCTAssertEqual(read("The team moved Lantern and Lantern again, with the lantern."), [])
    }

    func test_shortStringsAndOrdinaryWords_areLeftOut() {
        XCTAssertEqual(read("Then the QA team told QA that Al was late and Al said that."), [])
    }

    func test_mostRecentlyUsedComeLast_andOnlyTheLastFewAreKept() {
        // #given more names than are kept, with the first one used again at the end
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let names: [String] = (0..<30).map { index in
            let first = String(letters[index % 26])
            let second = String(letters[index / 26])
            return "Name" + first + second
        }
        let text = names.map { "Then the team asked \($0)." }.joined(separator: " ") + " Then the team asked \(names[0])."

        let words = read(text)

        // #then the count is capped and the name used last is at the end
        XCTAssertEqual(words.count, TextVocabulary.maximumWords)
        XCTAssertEqual(words.last?.display, names[0])
        XCTAssertFalse(words.contains { $0.display == names[1] })
    }
}
