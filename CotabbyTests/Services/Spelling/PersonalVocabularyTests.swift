import XCTest
@testable import Cotabby

@MainActor
final class PersonalVocabularyTests: XCTestCase {
    private let dictionary: Set<String> = ["my", "name", "is", "we", "met", "at", "the", "and", "works"]

    private func learn(_ vocabulary: PersonalVocabulary, _ sentence: String, rejected: Set<String> = []) {
        vocabulary.learn(
            sentence: sentence,
            isDictionaryWord: { self.dictionary.contains($0) },
            isAcceptedSpelling: { !rejected.contains($0) }
        )
    }

    func test_aWordWrittenTwice_becomesACorrectionTargetInTheWritersCasing() {
        let vocabulary = PersonalVocabulary(fileURL: nil)
        learn(vocabulary, "My name is Lindqvist.")
        XCTAssertTrue(vocabulary.matches(for: "Lindqvsit").isEmpty, "Once is not enough to trust a word")

        learn(vocabulary, "We met Lindqvist at the works.")

        XCTAssertEqual(vocabulary.matches(for: "lindqvsit"), [PersonalVocabulary.Match(word: "Lindqvist", distance: 1, uses: 2)])
        XCTAssertEqual(vocabulary.preferredCasing(of: "lindqvist"), "Lindqvist")
    }

    func test_dictionaryWordsRejectedSpellingsAndShortWordsAreNotLearned() {
        let vocabulary = PersonalVocabulary(fileURL: nil)
        for _ in 0..<3 {
            learn(vocabulary, "We met Zo and teh Kubernetes.", rejected: ["teh"])
        }

        XCTAssertTrue(vocabulary.matches(for: "the").isEmpty)
        XCTAssertTrue(vocabulary.matches(for: "tehh").isEmpty)
        XCTAssertNil(vocabulary.preferredCasing(of: "zo"))
        XCTAssertEqual(vocabulary.matches(for: "Kubernets").first?.word, "Kubernetes")
    }

    func test_dictionaryWordsThatGotInEarlier_leaveTheNextTimeSomethingIsLearned() {
        // #given a vocabulary that learned ordinary words while the dictionary was not yet read
        // (every word looked like one it lacked)
        let vocabulary = PersonalVocabulary(fileURL: nil)
        for _ in 0..<2 {
            vocabulary.learn(sentence: "The works and Lindqvist.", isDictionaryWord: { _ in false }, isAcceptedSpelling: { _ in true })
        }
        XCTAssertEqual(vocabulary.preferredCasing(of: "works"), "works")

        // #when a sentence is learned with the dictionary there
        learn(vocabulary, "We met at noon.")

        // #then the ordinary words are gone and the writer's own word stays
        XCTAssertNil(vocabulary.preferredCasing(of: "works"))
        XCTAssertEqual(vocabulary.preferredCasing(of: "lindqvist"), "Lindqvist")
    }

    func test_theWordItselfAndDistantWordsAreNotMatches() {
        let vocabulary = PersonalVocabulary(fileURL: nil)
        learn(vocabulary, "My name is Lindqvist.")
        learn(vocabulary, "My name is Lindqvist.")

        XCTAssertTrue(vocabulary.matches(for: "lindqvist").isEmpty)
        XCTAssertTrue(vocabulary.matches(for: "houston").isEmpty)
    }

    func test_wordsPersistAndReset() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("personal-words-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let vocabulary = PersonalVocabulary(fileURL: url)
        learn(vocabulary, "My name is Lindqvist.")
        learn(vocabulary, "My name is Lindqvist.")

        XCTAssertEqual(PersonalVocabulary(fileURL: url).matches(for: "Lindqvsit").first?.word, "Lindqvist")

        vocabulary.reset()
        XCTAssertTrue(PersonalVocabulary(fileURL: url).matches(for: "Lindqvsit").isEmpty)
    }
}
