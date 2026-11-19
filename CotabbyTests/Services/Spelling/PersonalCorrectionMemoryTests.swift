import XCTest
@preconcurrency @testable import Cotabby

/// Locks down how a word the writer keeps writing becomes theirs without the quoted slot on the
/// bar: left standing in three finished lines, unless they have ever corrected it.
@MainActor
final class PersonalCorrectionMemoryTests: XCTestCase {
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "PersonalCorrectionMemoryTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeMemory() -> PersonalCorrectionMemory {
        PersonalCorrectionMemory(userDefaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    func test_wordLeftStandingInThreeLines_isKept() {
        // #given a flagged word left standing in two finished lines
        let memory = makeMemory()
        XCTAssertFalse(memory.recordLeftStanding("zorvex"))
        XCTAssertFalse(memory.recordLeftStanding("Zorvex"))
        XCTAssertFalse(memory.isKept("zorvex"))

        // #when it stands in a third
        let promoted = memory.recordLeftStanding("zorvex")

        // #then it is the writer's own word from now on
        XCTAssertTrue(promoted)
        XCTAssertTrue(memory.isKept("Zorvex"))
    }

    func test_tallySurvivesARelaunch() {
        // #given two lines counted before the app quit
        let first = makeMemory()
        first.recordLeftStanding("zorvex")
        first.recordLeftStanding("zorvex")

        // #when the third comes after a relaunch
        let second = makeMemory()

        // #then it still makes the word kept
        XCTAssertTrue(second.recordLeftStanding("zorvex"))
    }

    func test_wordTheWriterHasCorrected_isNeverCounted() {
        // #given a slip the writer once accepted a fix for
        let memory = makeMemory()
        memory.recordAccepted(typo: "becuase", replacement: "because")

        // #when it is left standing again and again
        let promotions = (0..<5).map { _ in memory.recordLeftStanding("becuase") }

        // #then it stays a slip
        XCTAssertEqual(promotions, [false, false, false, false, false])
        XCTAssertFalse(memory.isKept("becuase"))
    }

    func test_correctingAWordAfterTwoLines_startsItsTallyOver() {
        // #given a word left standing twice, then corrected by the writer
        let memory = makeMemory()
        memory.recordLeftStanding("thier")
        memory.recordLeftStanding("thier")
        memory.recordAccepted(typo: "thier", replacement: "their")

        // #then one more line does not make it kept
        XCTAssertFalse(memory.recordLeftStanding("thier"))
        XCTAssertFalse(memory.isKept("thier"))
    }

    func test_correctingAKeptWord_takesItBackOut() {
        // #given a word that became kept by standing in three lines
        let memory = makeMemory()
        (0..<3).forEach { _ in memory.recordLeftStanding("thier") }
        XCTAssertTrue(memory.isKept("thier"))

        // #when the writer accepts a fix for it
        memory.recordAccepted(typo: "thier", replacement: "their")

        // #then it is flagged again
        XCTAssertFalse(memory.isKept("thier"))
    }

    func test_veryShortWords_areNotLearnedThisWay() {
        let memory = makeMemory()

        let promotions = (0..<4).map { _ in memory.recordLeftStanding("zq") }

        XCTAssertEqual(promotions, [false, false, false, false])
    }

    func test_reset_forgetsTheTally() {
        // #given two lines counted, then everything learned is cleared
        let memory = makeMemory()
        memory.recordLeftStanding("zorvex")
        memory.recordLeftStanding("zorvex")
        memory.reset()

        // #then the count starts from nothing
        XCTAssertFalse(memory.recordLeftStanding("zorvex"))
        XCTAssertFalse(makeMemory().recordLeftStanding("zorvex"))
    }
}
