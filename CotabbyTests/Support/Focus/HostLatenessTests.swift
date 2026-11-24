import XCTest
@testable import Cotabby

/// Locks down what counts as an app that is slow to show keys.
final class HostLatenessTests: XCTestCase {
    private let chat = "com.example.chat"

    func test_appThatShowsKeysPromptly_isNotLate() {
        var lateness = HostLateness()
        for _ in 0..<10 { lateness.note(publishedAfter: 25, inApp: chat) }

        XCTAssertFalse(lateness.isLate(inApp: chat, lastReadMilliseconds: 2))
    }

    func test_oneLateKeyInAQuickApp_doesNotMakeItLate() {
        // #given a quick app with one key that took 100 ms
        var lateness = HostLateness()
        for _ in 0..<10 { lateness.note(publishedAfter: 25, inApp: chat) }
        lateness.note(publishedAfter: 100, inApp: chat)

        XCTAssertFalse(lateness.isLate(inApp: chat, lastReadMilliseconds: 2))
    }

    func test_appThatKeepsShowingKeysLate_isLate() {
        var lateness = HostLateness()
        for _ in 0..<3 { lateness.note(publishedAfter: 180, inApp: chat) }

        XCTAssertTrue(lateness.isLate(inApp: chat, lastReadMilliseconds: 2))
    }

    func test_latenessBelongsToOneApp() {
        // #given a late chat app
        var lateness = HostLateness()
        for _ in 0..<3 { lateness.note(publishedAfter: 180, inApp: chat) }

        // #then another app is not late because of it
        XCTAssertFalse(lateness.isLate(inApp: "com.example.notes", lastReadMilliseconds: 2))
    }

    func test_slowRead_makesAnyAppLate() {
        let lateness = HostLateness()

        XCTAssertTrue(lateness.isLate(inApp: chat, lastReadMilliseconds: 95))
    }
}
