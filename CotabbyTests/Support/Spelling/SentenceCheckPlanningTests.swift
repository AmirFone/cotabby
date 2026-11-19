import XCTest
@testable import Cotabby

/// Pins which text counts as a just-finished sentence, the minimal keystroke edit that applies a fix,
/// and the word diff the proofreading card highlights.
final class SentenceCheckPlanningTests: XCTestCase {
    func test_extract_returnsTheSentenceFinishedByTheLastSpace() {
        let finished = FinishedSentenceExtractor.extract(from: "Hi Sarah. I recieved there email yesterday. ")

        XCTAssertEqual(finished?.sentence, "I recieved there email yesterday.")
        XCTAssertEqual(finished?.trailingWhitespace, " ")
        XCTAssertEqual(finished?.precedingContext, "Hi Sarah. ")
    }

    func test_extract_keepsAbbreviationsInsideOneSentence() {
        XCTAssertEqual(
            FinishedSentenceExtractor.extract(from: "We met Dr. Smith at the clinic today. ")?.sentence,
            "We met Dr. Smith at the clinic today."
        )
    }

    func test_extract_ignoresUnfinishedShortAndMachineText() {
        XCTAssertNil(FinishedSentenceExtractor.extract(from: "I recieved there email yesterday."), "no finishing space yet")
        XCTAssertNil(FinishedSentenceExtractor.extract(from: "Sounds good. "), "too short to check")
        XCTAssertNil(FinishedSentenceExtractor.extract(from: "Open https://example.com/a for the doc. "))
        XCTAssertNil(FinishedSentenceExtractor.extract(from: "Set the value to x == y in the config file. "))
        XCTAssertNil(FinishedSentenceExtractor.extract(from: "I am still typing this sentence "))
    }

    func test_plan_retypesOnlyFromTheFirstChangedCharacter() {
        let finished = FinishedSentence(sentence: "I recieved there email yesterday.", trailingWhitespace: " ", precedingContext: "")

        let plan = SentenceRewritePlanner.plan(
            precedingText: "Hi. I recieved there email yesterday. ",
            finished: finished,
            corrected: "I received their email yesterday."
        )

        XCTAssertEqual(plan?.replacementText, "eived their email yesterday. ")
        XCTAssertEqual(plan?.backspaceCount, "ieved there email yesterday. ".count)
    }

    func test_plan_countsAnEmojiInTheRetypedTailAsOneBackspace() {
        // #given a sentence with an emoji after the slip: `t like it 😀. ` is 13 keys but 14 UTF-16 units
        let finished = FinishedSentence(sentence: "I dont like it 😀.", trailingWhitespace: " ", precedingContext: "")

        // #when the fix is planned
        let plan = SentenceRewritePlanner.plan(
            precedingText: "I dont like it 😀. ", finished: finished, corrected: "I don't like it 😀."
        )

        // #then the `n` of `don` is not deleted: one key per character from the first change on
        XCTAssertEqual(plan, TypoCorrectionReplacement(backspaceCount: 13, replacementText: "'t like it 😀. "))
    }

    func test_plan_countsEveryKindOfEmojiSequenceAsOneBackspace() {
        // #given a doubled word before a skin tone, a flag, a family, a keycap and a subdivision flag
        for glyph in ["👍🏽", "🇺🇸", "👨‍👩‍👧‍👦", "👩🏽‍💻", "❤️", "1️⃣", "🏴󠁧󠁢󠁥󠁮󠁧󠁿"] {
            let sentence = "I went to the the store \(glyph) today."
            let finished = FinishedSentence(sentence: sentence, trailingWhitespace: " ", precedingContext: "")

            // #when the second `the` is removed
            let plan = SentenceRewritePlanner.plan(
                precedingText: sentence + " ", finished: finished, corrected: "I went to the store \(glyph) today."
            )

            // #then the glyph costs one key, so `I went to the ` stays whole
            XCTAssertEqual(plan?.backspaceCount, "the store X today. ".count, glyph)
        }
    }

    func test_plan_simulatedOnAFieldThatDeletesAGlyphPerKey_changesOnlyTheSentence() {
        // #given an earlier sentence the fix must not touch, and a fix at the very start of the next
        let finished = FinishedSentence(sentence: "i dont like it 😀 at all.", trailingWhitespace: " ", precedingContext: "Ok. ")
        let field = "Ok. i dont like it 😀 at all. "
        let plan = SentenceRewritePlanner.plan(precedingText: field, finished: finished, corrected: "I don't like it 😀 at all.")

        // #when the keys land in a field that removes one character per Backspace
        let result = plan.map { String(field.dropLast($0.backspaceCount)) + $0.replacementText }

        // #then the space after `Ok.` survives
        XCTAssertEqual(result, "Ok. I don't like it 😀 at all. ")
    }

    func test_plan_refusesATailWithADecomposedAccent() {
        // #given `café` written as `e` + U+0301 after the slip: one key in AppKit, two in Chromium
        let sentence = "I dont like the cafe\u{301} here."
        let finished = FinishedSentence(sentence: sentence, trailingWhitespace: " ", precedingContext: "")

        // #when the fix is planned
        let plan = SentenceRewritePlanner.plan(
            precedingText: sentence + " ", finished: finished, corrected: "I don't like the cafe\u{301} here."
        )

        // #then no edit is made, because no key count is right in every host
        XCTAssertNil(plan)
    }

    func test_plan_allowsADecomposedAccentBeforeTheFirstChange() {
        // #given the decomposed letter in the part of the sentence that is kept, not retyped
        let sentence = "The cafe\u{301} is nice but I dont go."
        let finished = FinishedSentence(sentence: sentence, trailingWhitespace: " ", precedingContext: "")

        // #when the fix is planned
        let plan = SentenceRewritePlanner.plan(
            precedingText: sentence + " ", finished: finished, corrected: "The cafe\u{301} is nice but I don't go."
        )

        // #then only the plain tail is counted
        XCTAssertEqual(plan, TypoCorrectionReplacement(backspaceCount: 6, replacementText: "'t go. "))
    }

    func test_plan_failsClosedWhenTheFieldMovedOn() {
        let finished = FinishedSentence(sentence: "I recieved there email yesterday.", trailingWhitespace: " ", precedingContext: "")

        XCTAssertNil(SentenceRewritePlanner.plan(
            precedingText: "I recieved there email yesterday. Then",
            finished: finished,
            corrected: "I received their email yesterday."
        ))
        XCTAssertNil(SentenceRewritePlanner.plan(
            precedingText: "I recieved there email yesterday. ",
            finished: finished,
            corrected: "I recieved there email yesterday."
        ), "an unchanged sentence has nothing to apply")
    }

    func test_plan_refusesRewritesTooLongToTypeSafely() {
        let sentence = "a" + String(repeating: " word", count: 30) + "."
        let finished = FinishedSentence(sentence: sentence, trailingWhitespace: " ", precedingContext: "")

        XCTAssertNil(SentenceRewritePlanner.plan(precedingText: sentence + " ", finished: finished, corrected: "A" + sentence.dropFirst()))
    }

    func test_wordDiff_marksOnlyChangedWords() {
        let segments = SentenceWordDiff.segments(
            original: "I recieved there email yesterday.",
            corrected: "I received their email yesterday."
        )

        XCTAssertEqual(segments.filter(\.isChanged).map(\.text), ["received", "their"])
        XCTAssertEqual(segments.map(\.text).joined(separator: " "), "I received their email yesterday.")
    }

    // MARK: - A line the writer has not ended

    func test_extractUnfinished_takesTheLineSoFar_oneSpaceAfterAWord() {
        // #given five words and a space, no closing mark
        let line = FinishedSentenceExtractor.extractUnfinished(from: "can you send the report ")

        // #then the line is the sentence, marked unfinished, with the space as what follows it
        XCTAssertEqual(line?.sentence, "can you send the report")
        XCTAssertEqual(line?.trailingWhitespace, " ")
        XCTAssertEqual(line?.isUnfinished, true)
    }

    func test_extractUnfinished_needsFiveWords() {
        XCTAssertNil(FinishedSentenceExtractor.extractUnfinished(from: "can you send the "))
    }

    func test_extractUnfinished_notInTheMiddleOfAWord() {
        XCTAssertNil(FinishedSentenceExtractor.extractUnfinished(from: "can you send the report ov"))
    }

    func test_extractUnfinished_leavesAFinishedSentenceToTheOtherExtractor() {
        // #given a sentence that has ended
        let text = "Can you send the report over. "

        // #then it is a finished sentence and not an unfinished line
        XCTAssertNil(FinishedSentenceExtractor.extractUnfinished(from: text))
        XCTAssertNotNil(FinishedSentenceExtractor.extract(from: text))
    }

    func test_extractUnfinished_startsAfterTheSentenceBefore() {
        // #given a finished sentence and five words of the next
        let line = FinishedSentenceExtractor.extractUnfinished(from: "That works. can you send the report ")

        // #then only the new line is taken, and the sentence before it is context
        XCTAssertEqual(line?.sentence, "can you send the report")
        XCTAssertEqual(line?.precedingContext, "That works. ")
    }

    func test_extractUnfinished_startsAtTheLineBreak() {
        let line = FinishedSentenceExtractor.extractUnfinished(from: "first line here\ncan you send the report ")

        XCTAssertEqual(line?.sentence, "can you send the report")
    }

    func test_extractUnfinished_refusesCodeAndLinks() {
        XCTAssertNil(FinishedSentenceExtractor.extractUnfinished(from: "see https://example.com for the full list "))
        XCTAssertNil(FinishedSentenceExtractor.extractUnfinished(from: "set x = y in the config file "))
    }

    func test_extractUnfinished_notAfterTwoSpacesOrALineBreak() {
        XCTAssertNil(FinishedSentenceExtractor.extractUnfinished(from: "can you send the report  "))
        XCTAssertNil(FinishedSentenceExtractor.extractUnfinished(from: "can you send the report\n"))
    }

    // MARK: - An unfinished line's verdict leaves the last word alone

    func test_leavingTheLastWordAlone_keepsAFixEarlierInTheLine() {
        // #given a fix to the third word of six
        let result = LocalProofreadResult(original: "I saw teh cat run away", autoCorrected: "I saw the cat run away", flags: [])

        // #then it stands
        XCTAssertEqual(result.leavingTheLastWordAlone?.autoCorrected, "I saw the cat run away")
    }

    func test_leavingTheLastWordAlone_dropsAVerdictThatChangedTheLastWord() {
        let result = LocalProofreadResult(original: "after lunch I went their", autoCorrected: "after lunch I went there", flags: [])

        XCTAssertNil(result.leavingTheLastWordAlone)
    }

    func test_leavingTheLastWordAlone_dropsAFlagOnTheLastWord_andKeepsEarlierOnes() throws {
        // #given a flag on a middle word and one on the last word
        let sentence = "we went their and then form"
        let their = try XCTUnwrap(sentence.range(of: "their"))
        let form = try XCTUnwrap(sentence.range(of: "form"))
        let result = LocalProofreadResult(original: sentence, autoCorrected: sentence, flags: [
            SentenceFlag(range: their, typed: "their", options: ["there"]),
            SentenceFlag(range: form, typed: "form", options: ["from"]),
        ])

        // #then only the middle word is still asked about
        XCTAssertEqual(result.leavingTheLastWordAlone?.flags.map(\.typed), ["their"])
    }

    func test_leavingTheLastWordAlone_isNilWhenOnlyTheLastWordWasFlagged() throws {
        let sentence = "we went home and then form"
        let form = try XCTUnwrap(sentence.range(of: "form"))
        let result = LocalProofreadResult(original: sentence, autoCorrected: sentence, flags: [
            SentenceFlag(range: form, typed: "form", options: ["from"]),
        ])

        XCTAssertNil(result.leavingTheLastWordAlone)
    }
}
