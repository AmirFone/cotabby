import XCTest
@testable import Cotabby

/// Locks down the memory `InputMonitor`'s two taps use to tell whether the other has had a key.
final class RecentKeyDownsTests: XCTestCase {
    func test_rememberedKey_isFoundOnce() {
        // #given a key one tap has handled
        var keys = RecentKeyDowns()
        keys.insert(41)

        // #then the other tap finds it, and only the first time it asks
        XCTAssertTrue(keys.remove(41))
        XCTAssertFalse(keys.remove(41))
    }

    func test_keyNeverRemembered_isNotFound() {
        var keys = RecentKeyDowns()
        keys.insert(41)

        XCTAssertFalse(keys.remove(42))
    }

    func test_twoKeysWaiting_areBothFound_inEitherOrder() {
        // #given two keys handled before the other tap had its turn for the first
        var keys = RecentKeyDowns()
        keys.insert(41)
        keys.insert(42)

        // #then neither is lost, which a single remembered key could not promise
        XCTAssertTrue(keys.remove(41))
        XCTAssertTrue(keys.remove(42))
    }

    func test_keysNobodyAsksFor_doNotPileUp() {
        // #given a tap that is switched off and never asks
        var keys = RecentKeyDowns()
        for timestamp in 0..<UInt64(RecentKeyDowns.capacity + 8) { keys.insert(timestamp) }

        // #then the oldest are gone and the newest are still there
        XCTAssertFalse(keys.remove(0))
        XCTAssertTrue(keys.remove(UInt64(RecentKeyDowns.capacity + 7)))
    }
}
