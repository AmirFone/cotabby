import XCTest
@testable import Cotabby

/// Learning from the writer going back and retyping a word themselves.
final class SelfCorrectionDetectorTests: XCTestCase {
    private let words: Set<String> = ["i", "saw", "because", "the", "cat", "dog", "went"]
    private func plausible(_ typed: String, _ corrected: String) -> Bool {
        SelfCorrectionDetector.isPlausibleFix(typed: typed, corrected: corrected) { self.words.contains($0) }
    }

    func test_retypingAMisspelledWord_isReported() {
        // #given a finished misspelled word
        var detector = SelfCorrectionDetector()
        _ = detector.observe("I saw becuase ", isPlausible: plausible)

        // #when the writer deletes back into it and types the right word
        XCTAssertNil(detector.observe("I saw becu", isPlausible: plausible))
        let correction = detector.observe("I saw because ", isPlausible: plausible)

        // #then the pair is reported
        XCTAssertEqual(correction, .init(typed: "becuase", corrected: "because"))
    }

    func test_deletingTheWholeWordThenRetyping_isReported() {
        var detector = SelfCorrectionDetector()
        _ = detector.observe("the monkee ", isPlausible: { _, _ in true })

        _ = detector.observe("the ", isPlausible: { _, _ in true })
        _ = detector.observe("the mon", isPlausible: { _, _ in true })

        XCTAssertEqual(detector.observe("the monkey ", isPlausible: { _, _ in true }), .init(typed: "monkee", corrected: "monkey"))
    }

    func test_deletingOneCharacterPastTheWord_thenRetyping_isReported() {
        // #given a finished misspelled word
        var detector = SelfCorrectionDetector()
        _ = detector.observe("I saw becuase ", isPlausible: plausible)

        // #when the writer deletes it and the space before it too, then types the space and the word
        XCTAssertNil(detector.observe("I saw", isPlausible: plausible))
        XCTAssertNil(detector.observe("I saw ", isPlausible: plausible))
        let correction = detector.observe("I saw because ", isPlausible: plausible)

        // #then it is still their fix of that word
        XCTAssertEqual(correction, .init(typed: "becuase", corrected: "because"))
    }

    func test_deletingIntoTheWordBefore_andWritingSomethingElse_isNotAFix() {
        // #given a finished misspelled word
        var detector = SelfCorrectionDetector()
        _ = detector.observe("I saw becuase ", isPlausible: plausible)

        // #when the writer deletes back into the word before it and goes another way
        _ = detector.observe("I sa", isPlausible: plausible)
        let correction = detector.observe("I sat because ", isPlausible: plausible)

        // #then nothing is learned: the text before the word is not what it was
        XCTAssertNil(correction)
    }

    func test_changeOfMind_isNotAFix() {
        var detector = SelfCorrectionDetector()
        _ = detector.observe("I saw the cat ", isPlausible: plausible)

        XCTAssertNil(detector.observe("I saw the dog ", isPlausible: plausible))
    }

    func test_typingOn_movesTheWatchToTheNewWord() {
        var detector = SelfCorrectionDetector()
        _ = detector.observe("I saw becuase ", isPlausible: plausible)
        _ = detector.observe("I saw becuase the ", isPlausible: plausible)

        XCTAssertNil(detector.observe("I saw becuase the cat ", isPlausible: plausible))
    }

    func test_resetForgetsTheWatchedWord() {
        var detector = SelfCorrectionDetector()
        _ = detector.observe("I saw becuase ", isPlausible: plausible)

        detector.reset()

        XCTAssertNil(detector.observe("I saw because ", isPlausible: plausible))
    }

    func test_plausibility_needsATypoBecomingASimilarWord() {
        XCTAssertTrue(plausible("becuase", "because"))
        XCTAssertFalse(plausible("cat", "dog"), "a real word replaced by another is a change of mind")
        XCTAssertFalse(plausible("xqzv", "because"), "too different to be the same word")
    }
}

/// The journal writes one line per event and respects its switch.
@MainActor
final class CorrectionJournalTests: XCTestCase {
    func test_recordsOneLinePerEvent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = CorrectionJournal(fileURL: url, isEnabled: { true })

        journal.record(.selfCorrected, typed: "becuase", final: "because")
        journal.record(.autoFixUndone, typed: "teh", final: "teh")

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"kind\":\"selfCorrected\""))
    }

    func test_disabledJournal_writesNothing() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).jsonl")
        let journal = CorrectionJournal(fileURL: url, isEnabled: { false })

        journal.record(.picked, typed: "wich", final: "which")

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
