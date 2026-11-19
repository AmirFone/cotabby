import XCTest
@preconcurrency @testable import Cotabby

/// Locks down the one clock the word strip and the spelling bar go away by: it counts from the
/// writer's last key, tells each panel once, and stays run out until the next key.
@MainActor
final class InlinePanelIdleTimerTests: XCTestCase {
    func test_runsOutOnce_afterTheTimeWithoutAKey() {
        // #given a short idle time and two panels listening
        let idle = InlinePanelIdleTimer(seconds: 0.05)
        var told = 0
        idle.whenRunOut { told += 1 }
        idle.whenRunOut { told += 10 }

        // #when a key is pressed and nothing follows
        idle.noteActivity()
        XCTAssertFalse(idle.hasRunOut)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))

        // #then both were told, once each, and the timer says so until the next key
        XCTAssertEqual(told, 11)
        XCTAssertTrue(idle.hasRunOut)
    }

    func test_aKeyStartsTheCountAgain() {
        // #given a key pressed
        let idle = InlinePanelIdleTimer(seconds: 0.2)
        var told = 0
        idle.whenRunOut { told += 1 }
        idle.noteActivity()

        // #when another key follows before the time is up, and that time then passes
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        idle.noteActivity()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))

        // #then it has not run out: the time counts from the second key
        XCTAssertEqual(told, 0)
        XCTAssertFalse(idle.hasRunOut)

        // #when the rest of the time passes
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        // #then it runs out
        XCTAssertEqual(told, 1)
    }

    func test_aKeyAfterRunningOut_clearsIt_andCountsAgain() {
        // #given a timer that ran out
        let idle = InlinePanelIdleTimer(seconds: 0.05)
        var told = 0
        idle.whenRunOut { told += 1 }
        idle.noteActivity()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(idle.hasRunOut)

        // #when the writer presses a key
        idle.noteActivity()

        // #then the panels may draw again, and are told again when this time runs out too
        XCTAssertFalse(idle.hasRunOut)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(told, 2)
    }

    func test_withoutAnyKey_nothingRunsOut() {
        // #given a timer nobody has typed against
        let idle = InlinePanelIdleTimer(seconds: 0.05)
        var told = 0
        idle.whenRunOut { told += 1 }

        // #when time passes
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        // #then no panel is told to go: there is nothing on screen that a key put there
        XCTAssertEqual(told, 0)
        XCTAssertFalse(idle.hasRunOut)
    }

    func test_fiveSecondsIsTheTimeTheAppUses() {
        XCTAssertEqual(InlinePanelIdleTimer.defaultSeconds, 5)
    }
}
