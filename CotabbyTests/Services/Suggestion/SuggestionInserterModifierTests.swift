import CoreGraphics
import XCTest
@testable import Cotabby

/// A replacement is a run of Backspaces and then text, posted as key events, and macOS adds the
/// modifiers held on the real keyboard to posted keys. These lock down that nothing is posted
/// while one of them would turn a Backspace into "delete the line".
///
/// Only the refusals are tested here: a replacement that goes through posts real key events to
/// whatever app is in front of the machine running the tests.
@MainActor
final class SuggestionInserterModifierTests: XCTestCase {
    func test_replace_withCommandControlOrOptionHeld_postsNothing() {
        for modifier in [CGEventFlags.maskCommand, .maskControl, .maskAlternate] {
            // #given a writer holding a modifier
            let inserter = SuggestionInserter(suppressionController: InputSuppressionController())
            inserter.heldModifiers = { modifier }
            var deletingEdits = 0
            inserter.onWillPostDeletingEdit = { deletingEdits += 1 }

            // #when a fix would be typed
            let replaced = inserter.replace(deletingUTF16Count: 3, with: "the")

            // #then it is refused before any key is made
            XCTAssertFalse(replaced)
            XCTAssertEqual(deletingEdits, 0)
            XCTAssertNotNil(inserter.lastErrorMessage)
        }
    }
}
