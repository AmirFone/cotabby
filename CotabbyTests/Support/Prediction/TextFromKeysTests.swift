import XCTest
@testable import Cotabby

/// Locks down how a read of the field is placed against the keys typed since the last read: the
/// text now, an earlier state of it (a host that is behind), or other text.
final class TextFromKeysTests: XCTestCase {
    private func typed(_ added: String, after read: String) -> TextFromKeys {
        var keys = TextFromKeys()
        keys.settle(on: read)
        for character in added { keys.apply { $0 + String(character) } }
        return keys
    }

    func test_everyKeyIsApplied() {
        // #given a read and five keys
        let keys = typed("want ", after: "I ")

        // #then the text is the read with all five
        XCTAssertEqual(keys.text, "I want ")
        XCTAssertTrue(keys.holds("I want "))
    }

    func test_statesOnTheWay_areEarlierStates() {
        // #given a burst the host publishes one key at a time
        let keys = typed("want ", after: "I ")

        // #then each state before the last is one the field may still show
        for state in ["I ", "I w", "I wa", "I wan", "I want"] {
            XCTAssertTrue(keys.isEarlierState(state), state)
        }
    }

    func test_fieldThatShowsTheNextKeyAlready_isAhead() {
        // #given `we` typed, and a host that was told about the space before this model was
        let keys = typed("we", after: "")

        // #then the field with the space is one key ahead
        XCTAssertEqual(keys.isAhead("we ", by: " "), true)
    }

    func test_fieldThatDoesNotShowTheNextKeyYet_isNotAhead() {
        let keys = typed("we", after: "")

        XCTAssertEqual(keys.isAhead("we", by: " "), false)
    }

    func test_doubledLetter_aFieldOneKeyBehind_isNotAhead() {
        // #given `al` typed and a second `l` on its way: the field still reads `al`
        let keys = typed("l", after: "a")

        // #then that is the field before the key, although it ends with the key's letter
        XCTAssertEqual(keys.isAhead("al", by: "l"), false)
    }

    func test_whenTheTextIsNotKnown_aheadIsNotKnownEither() {
        // #given a key whose effect the key alone does not tell
        var keys = typed("we", after: "")
        keys.apply { _ in nil }

        XCTAssertNil(keys.isAhead("we ", by: " "))
    }

    func test_readWithTheCaretFromBeforeTheLastKeys_isNotACaretInsideAWord() {
        // #given `re` typed after `the `, and a read with the caret from before the `e`
        let keys = typed("re", after: "the ")

        // #then the `e` after that caret is the key just typed
        XCTAssertTrue(keys.isCaretBehindItsText(before: "the r", after: "e"))
    }

    func test_caretReallyInsideAWord_staysOne() {
        // #given the same keys, and a caret with other letters after it
        let keys = typed("re", after: "the ")

        XCTAssertFalse(keys.isCaretBehindItsText(before: "the re", after: "port"))
        XCTAssertFalse(keys.isCaretBehindItsText(before: "the r", after: "x"))
    }

    func test_nothingAfterTheCaret_isNoSuchRead() {
        let keys = typed("re", after: "the ")

        XCTAssertFalse(keys.isCaretBehindItsText(before: "the r", after: ""))
    }

    func test_theTextNow_isNotAnEarlierState() {
        let keys = typed("want ", after: "I ")

        XCTAssertFalse(keys.isEarlierState("I want "))
    }

    func test_textTheKeysNeverLeft_isNotAnEarlierState() {
        // #given the same burst
        let keys = typed("want ", after: "I ")

        // #then other text is not "behind", whether it differs inside, is shorter than the read
        // the keys started from, or is longer than what they typed
        XCTAssertFalse(keys.isEarlierState("I went"))
        XCTAssertFalse(keys.isEarlierState(""))
        XCTAssertFalse(keys.isEarlierState("I"))
        XCTAssertFalse(keys.isEarlierState("I want to"))
    }

    func test_deletedLetters_areStillShownByAHostThatIsBehind() {
        // #given two letters deleted since the read
        var keys = TextFromKeys()
        keys.settle(on: "I want to go")
        keys.apply { String($0.dropLast()) }
        keys.apply { String($0.dropLast()) }

        // #then the text with them is an earlier state, and the text now is not
        XCTAssertEqual(keys.text, "I want to ")
        XCTAssertTrue(keys.isEarlierState("I want to go"))
        XCTAssertTrue(keys.isEarlierState("I want to g"))
        XCTAssertFalse(keys.isEarlierState("I want to "))
    }

    func test_typedThenDeleted_theTextNowWinsOverTheSameEarlierState() {
        // #given a letter typed and deleted again: the text now equals a state it passed through
        var keys = TextFromKeys()
        keys.settle(on: "I want")
        keys.apply { $0 + "x" }
        keys.apply { String($0.dropLast()) }

        // #then a field that reads it is up to date, not behind
        XCTAssertTrue(keys.holds("I want"))
        XCTAssertFalse(keys.isEarlierState("I want"))
        XCTAssertTrue(keys.isEarlierState("I wantx"))
    }

    func test_aKeyWithAnUnknownEffect_endsWhatIsKnown() {
        // #given a burst, then a key whose effect the key does not tell
        var keys = typed("want", after: "I ")
        keys.apply { _ in nil }

        // #then nothing is known: no text, and no read is "behind"
        XCTAssertNil(keys.text)
        XCTAssertFalse(keys.isEarlierState("I wa"))
        XCTAssertFalse(keys.holds("I want"))

        // #when further keys follow before a read
        keys.apply { $0 + "x" }

        // #then still nothing is known
        XCTAssertNil(keys.text)
    }

    func test_aRead_forgetsTheStatesBeforeIt() {
        // #given a burst and then a read of the field
        var keys = typed("want", after: "I ")
        keys.settle(on: "I want")

        // #then states from before the read are no longer "behind": a field that shows one now
        // was changed by something else
        XCTAssertFalse(keys.isEarlierState("I wa"))
    }

    func test_aPick_remembersTheStatesItsOwnKeysPassThrough() {
        // #given `rep` typed and `report ` picked: three letters go, seven characters come
        var keys = typed("rep", after: "the ")
        keys.jump(to: "the report ", through: ["the re", "the r", "the ", "the r", "the re", "the rep", "the repo", "the repor", "the report"])

        // #then the field on its way there is behind, and the end is the text now
        XCTAssertTrue(keys.isEarlierState("the rep"))
        XCTAssertTrue(keys.isEarlierState("the "))
        XCTAssertTrue(keys.isEarlierState("the repor"))
        XCTAssertTrue(keys.holds("the report "))
    }

    func test_inALongDocument_textsAreComparedByTheirEnds() {
        // #given a document longer than the part compared, read through a window that slid by one
        // character when a key was typed
        let body = String(repeating: "word ", count: 100)
        let keys = typed("x", after: body)

        // #then the reading with its first character pushed out still holds the text
        XCTAssertTrue(keys.holds(String(body.dropFirst()) + "x"))
        XCTAssertTrue(keys.isEarlierState(String(body.dropFirst())))
    }

    func test_onlySoManyStatesAreKept() {
        // #given more keys than states are kept for
        let keys = typed(String(repeating: "a", count: TextFromKeys.mostEarlierStates + 10), after: "b")

        // #then the oldest are forgotten and the newest kept
        XCTAssertFalse(keys.isEarlierState("b"))
        XCTAssertTrue(keys.isEarlierState("b" + String(repeating: "a", count: TextFromKeys.mostEarlierStates + 9)))
    }
}
