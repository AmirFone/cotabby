import XCTest
@testable import Cotabby

/// Alternatives and model inputs for correctly spelled wrong words, with a hand-built dictionary so
/// each rule is pinned without the bundled word list.
final class WrongWordDetectorTests: XCTestCase {
    private let counts: [String: Int64] = [
        "form": 90_000_000, "from": 2_000_000_000, "farm": 30_000_000, "forms": 60_000_000,
        "mussel": 300_000, "muscle": 20_000_000, "their": 800_000_000, "there": 900_000_000
    ]

    private func sources(
        neighbors: [String: [String]] = [:],
        soundAlikes: [String: [String]] = [:]
    ) -> WrongWordDetector.Sources {
        WrongWordDetector.Sources(
            count: { self.counts[$0] ?? 0 },
            neighbors: { word in (neighbors[word] ?? []).map { SymSpellSuggestion(term: $0, distance: 1, count: self.counts[$0] ?? 0) } },
            soundAlikes: { word in (soundAlikes[word] ?? []).map { SymSpellSuggestion(term: $0, distance: -1, count: self.counts[$0] ?? 0) } },
            commonCountFloor: 1_000_000
        )
    }

    private func position(
        scores: [String: Double] = [:],
        previous: String? = "am",
        next: String? = "london"
    ) -> WrongWordDetector.Position {
        WrongWordDetector.Position(
            textBefore: "I am ",
            previous: previous,
            next: next,
            afterNext: nil,
            pairCount: { _, _ in 0 },
            sentenceScore: { _, word in scores[word] ?? 0 }
        )
    }

    private func value(_ name: String, in vector: [Double]) -> Double {
        vector[WrongWordDetector.featureNames.firstIndex(of: name) ?? 0]
    }

    func test_alternatives_listConfusablesThenSoundAlikesThenCommonNeighbors() {
        let found = WrongWordDetector.alternatives(
            for: "Form",
            sources: sources(neighbors: ["form": ["farm", "from", "forms"]])
        )

        XCTAssertEqual(found.map(\.term), ["from", "farm"])
        XCTAssertEqual(found.first?.isConfusable, true)
    }

    func test_alternatives_includeWordsThatSoundTheSame() {
        let found = WrongWordDetector.alternatives(for: "mussel", sources: sources(soundAlikes: ["mussel": ["muscle"]]))

        XCTAssertEqual(found.map(\.term), ["muscle"])
        XCTAssertEqual(found.first?.soundsIdentical, true)
    }

    func test_alternatives_skipRareNeighborsAndTinyWords() {
        XCTAssertTrue(WrongWordDetector.alternatives(for: "muscle", sources: sources(neighbors: ["muscle": ["mussel"]])).isEmpty)
        XCTAssertTrue(WrongWordDetector.alternatives(for: "a", sources: sources(neighbors: ["a": ["from"]])).isEmpty)
    }

    func test_isInflection_onlyAPluralOrPastEnding() {
        XCTAssertTrue(WrongWordDetector.isInflection("cats", "cat"))
        XCTAssertTrue(WrongWordDetector.isInflection("use", "used"))
        XCTAssertFalse(WrongWordDetector.isInflection("to", "too"))
        XCTAssertFalse(WrongWordDetector.isInflection("it", "its"))
        XCTAssertFalse(WrongWordDetector.isInflection("form", "from"))
    }

    func test_features_oneVectorPerAlternativeWithPositiveDeltaWhenItFitsBetter() {
        let alternatives = WrongWordDetector.alternatives(for: "form", sources: sources(neighbors: ["form": ["farm", "from"]]))

        let vectors = WrongWordDetector.features(
            typed: "form",
            typedCount: 90_000_000,
            alternatives: alternatives,
            position: position(scores: ["from": 0.1, "form": 0.0001])
        )

        XCTAssertEqual(vectors.count, 2)
        XCTAssertTrue(vectors.allSatisfy { $0.count == WrongWordDetector.featureNames.count })
        XCTAssertEqual(value("leftDelta", in: vectors[0]), 3, accuracy: 1e-9)
        XCTAssertEqual(value("isAdjacentSwap", in: vectors[0]), 1)
        XCTAssertEqual(value("isConfusable", in: vectors[0]), 1)
        XCTAssertLessThan(value("contextDelta", in: vectors[1]), value("contextDelta", in: vectors[0]))
        XCTAssertEqual(value("bestRivalContextDelta", in: vectors[1]), value("contextDelta", in: vectors[0]), accuracy: 1e-9)
    }

    func test_features_markAMissingNeighbor() {
        let alternatives = WrongWordDetector.alternatives(for: "form", sources: sources(neighbors: ["form": ["from"]]))

        let vectors = WrongWordDetector.features(
            typed: "form",
            typedCount: 90_000_000,
            alternatives: alternatives,
            position: position(previous: nil, next: nil)
        )

        XCTAssertEqual(value("hasPrevious", in: vectors[0]), 0)
        XCTAssertEqual(value("hasNext", in: vectors[0]), 0)
        XCTAssertEqual(value("rightDelta", in: vectors[0]), 0)
    }

    func test_bundledModel_matchesThisBuildsFeatureList() {
        XCTAssertNotNil(WrongWordDetector.bundledModel(), "Retrain with Tools/autofix/run.sh after changing WrongWordDetector.featureNames")
    }
}

/// The sentence pass asks the trained check about every real word except names and the last word.
final class SentenceWrongWordTests: XCTestCase {
    private func checks(wrongWord: @escaping (String, LocalSentenceProofreader.WordPlace) -> [String]) -> LocalSentenceProofreader.Checks {
        LocalSentenceProofreader.Checks(
            isTypo: { _ in false },
            fix: { _, _ in nil },
            pairCount: { _, _ in 0 },
            sentenceScore: nil,
            wrongWord: wrongWord
        )
    }

    func test_flagsTheWordWithItsNeighborsAndCopiesCase() {
        var asked: [String: LocalSentenceProofreader.WordPlace] = [:]
        let result = LocalSentenceProofreader.proofread("Their was a big dog outside.", checks: checks { word, place in
            asked[word] = place
            return word == "Their" ? ["there"] : []
        })

        XCTAssertEqual(result.suggested, "There was a big dog outside.")
        XCTAssertEqual(result.autoCorrected, "Their was a big dog outside.")
        XCTAssertEqual(asked["big"]?.previous, "a")
        XCTAssertEqual(asked["big"]?.next, "dog")
        XCTAssertEqual(asked["big"]?.afterNext, "outside")
        XCTAssertEqual(asked["big"]?.textBefore, "Their was a ")
    }

    func test_neverAsksAboutNamesOrTheLastWord() {
        var asked: [String] = []
        _ = LocalSentenceProofreader.proofread("We met Rima in Paris yesterday.", checks: checks { word, _ in
            asked.append(word)
            return []
        })

        XCTAssertEqual(asked, ["We", "met", "in"])
    }

    func test_couldOf_becomesCouldHaveButNotOfCourse() {
        let none = checks { _, _ in [] }

        XCTAssertEqual(LocalSentenceProofreader.proofread("I could of done it better.", checks: none).autoCorrected, "I could have done it better.")
        XCTAssertEqual(LocalSentenceProofreader.proofread("You shouldn't of said that.", checks: none).autoCorrected, "You shouldn't have said that.")
        XCTAssertEqual(LocalSentenceProofreader.proofread("I could of course go later.", checks: none).autoCorrected, "I could of course go later.")
    }
}

/// A decision on the review card teaches the memory, so a kept word is not flagged again.
@MainActor
final class ReviewChoiceMemoryTests: XCTestCase {
    private func makeMemory() -> PersonalCorrectionMemory {
        let suite = "ReviewChoiceMemoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return PersonalCorrectionMemory(userDefaults: defaults)
    }

    func test_keptRealWord_isRememberedWithTheWordBeforeIt() {
        let memory = makeMemory()

        let outcome = memory.recordReviewChoice(typed: "their", previous: "in", chosen: "their", isRealWord: true)

        XCTAssertEqual(outcome, .kept)
        XCTAssertTrue(memory.isKept("in their"))
        XCTAssertFalse(memory.isKept("their"))
    }

    func test_keptMisspelling_isRememberedByItself() {
        let memory = makeMemory()

        memory.recordReviewChoice(typed: "Adeyemi", previous: "met", chosen: "Adeyemi", isRealWord: false)

        XCTAssertTrue(memory.isKept("adeyemi"))
    }

    func test_chosenReplacement_countsAsAnAcceptedFix() {
        let memory = makeMemory()

        let outcome = memory.recordReviewChoice(typed: "wich", previous: "know", chosen: "which", isRealWord: false)

        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(memory.acceptedReplacements(for: "wich"), ["which": 1])
        XCTAssertFalse(memory.isKept("wich"))
    }
}
