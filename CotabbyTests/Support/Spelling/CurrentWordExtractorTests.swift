import XCTest
@testable import Cotabby

final class CurrentWordExtractorTests: XCTestCase {
    func test_extractsTrailingWordAtCaret() {
        let result = CurrentWordExtractor.extract(from: "hi my nmae")
        XCTAssertEqual(result?.word, "nmae")
        XCTAssertEqual(result?.characterCount, 4)
    }

    func test_returnsNilWhenCaretFollowsWhitespace() {
        // A trailing space means there is no "current word" the caret sits inside.
        XCTAssertNil(CurrentWordExtractor.extract(from: "hi my nmae "))
    }

    func test_returnsNilForEmptyText() {
        XCTAssertNil(CurrentWordExtractor.extract(from: ""))
    }

    func test_returnsNilForSingleCharacterWord() {
        // Single-letter tokens are too noisy to act on.
        XCTAssertNil(CurrentWordExtractor.extract(from: "a"))
        XCTAssertNil(CurrentWordExtractor.extract(from: "I am a"))
    }

    func test_rejectsAllCapsAcronyms() {
        XCTAssertNil(CurrentWordExtractor.extract(from: "ship via HTTP"))
        XCTAssertNil(CurrentWordExtractor.extract(from: "parse JSON"))
    }

    func test_rejectsTokensWithDigits() {
        XCTAssertNil(CurrentWordExtractor.extract(from: "build v2"))
        XCTAssertNil(CurrentWordExtractor.extract(from: "room 101a"))
    }

    func test_rejectsCodeLikeTokens() {
        XCTAssertNil(CurrentWordExtractor.extract(from: "open https://example.com"))
        XCTAssertNil(CurrentWordExtractor.extract(from: "call user_name"))
        XCTAssertNil(CurrentWordExtractor.extract(from: "ping @jacob"))
        XCTAssertNil(CurrentWordExtractor.extract(from: "the file.swift"))
    }

    // MARK: - Words joined by a dot, a slash or a hyphen

    func test_wordAfterADotOrSlash_isTheCurrentWord_andMarkedJoined() {
        // #given a table name written the way it is said, and two words joined by a slash
        let afterDot = CurrentWordExtractor.extract(from: "sql table name is users.nmae")
        let afterSlash = CurrentWordExtractor.extract(from: "it is read/wriet")
        let deeper = CurrentWordExtractor.extract(from: "use schema.table.colum")

        // #then the word at the caret is the last one, flagged so that nothing is changed unasked
        XCTAssertEqual(afterDot, .init(word: "nmae", characterCount: 4, isJoined: true))
        XCTAssertEqual(afterSlash?.word, "wriet")
        XCTAssertEqual(afterSlash?.isJoined, true)
        XCTAssertEqual(deeper?.word, "colum")
    }

    func test_hyphenatedWord_staysWhole() {
        // The dictionary knows hyphenated words, so `well-knwon` is looked up as one.
        let result = CurrentWordExtractor.extract(from: "a well-knwon")

        XCTAssertEqual(result?.word, "well-knwon")
        XCTAssertEqual(result?.isJoined, false)
    }

    func test_wordFollowedByASlashOrHyphen_isStillTheTrailingWord() {
        // #given a word finished by a mark, not a space
        let slash = CurrentWordExtractor.extractTrailingWord(from: "did you recieve/")
        let hyphen = CurrentWordExtractor.extractTrailingWord(from: "I saw teh-")

        // #then it is checked like a word before a comma, and the mark is kept aside
        XCTAssertEqual(slash?.result.word, "recieve")
        XCTAssertEqual(slash?.trailingPunctuation, "/")
        XCTAssertEqual(hyphen?.result.word, "teh")
        XCTAssertEqual(hyphen?.trailingPunctuation, "-")
    }

    func test_addressesPathsFileNamesAndVersions_areNotJoinedWords() {
        for text in [
            "see example.com", "see www.exmaple.org", "open notes.txt", "the file.swift", "go to src/main/jva",
            "path /usr/lcal", "in ~/Desktop/fiel", "mail jo@exmaple.com", "version v1.2.x", "open https://exmaple.com/abuot",
            "two dots..teh", "call user_name.frist",
        ] {
            XCTAssertNil(CurrentWordExtractor.extract(from: text), text)
        }
    }

    func test_joinedWords_openEnd_isOnlyAcceptedWhenAsked() {
        XCTAssertNil(CurrentWordExtractor.joinedWords(in: "read/"))
        XCTAssertEqual(CurrentWordExtractor.joinedWords(in: "read/", allowingOpenEnd: true)?.map(String.init), ["read", ""])
        XCTAssertEqual(CurrentWordExtractor.joinedWords(in: "users.name")?.map(String.init), ["users", "name"])
    }

    func test_typoReplacement_ofAJoinedWord_touchesOnlyThatWord() {
        // #given the fix for the word after the dot, accepted with the caret still against it
        let replacement = TypoCorrectionReplacementPlanner.plan(
            precedingText: "table is users.nmae", expectedTypo: "nmae", correctedWord: "name", requiresTrailingSpace: false
        )

        // #then only its four letters are retyped; `users.` is not deleted
        XCTAssertEqual(replacement, TypoCorrectionReplacement(deletingUTF16Count: 4, replacementText: "name"))
    }

    func test_acceptsMixedCaseNaturalWord() {
        XCTAssertEqual(CurrentWordExtractor.extract(from: "fix teh")?.word, "teh")
        // Leading-capital natural words are fine; only ALL-caps tokens are rejected.
        XCTAssertEqual(CurrentWordExtractor.extract(from: "say Teh")?.word, "Teh")
    }

    func test_characterCountIsGraphemeCount() {
        // Accented letters that compose to a single grapheme count as one deletable character.
        let result = CurrentWordExtractor.extract(from: "a cafz")
        XCTAssertEqual(result?.word, "cafz")
        XCTAssertEqual(result?.characterCount, 4)
    }

    // MARK: - Tolerant trailing-space extraction

    func test_trailingWord_noSpaceMatchesStrictExtraction() {
        let extracted = CurrentWordExtractor.extractTrailingWord(from: "hi my nmae")
        XCTAssertEqual(extracted?.result.word, "nmae")
        XCTAssertEqual(extracted?.trailingSpaceCount, 0)
    }

    func test_trailingWord_toleratesOneTrailingSpace() {
        let extracted = CurrentWordExtractor.extractTrailingWord(from: "hi my nmae ")
        XCTAssertEqual(extracted?.result.word, "nmae")
        XCTAssertEqual(extracted?.trailingSpaceCount, 1)
    }

    func test_trailingWord_rejectsTwoTrailingSpaces() {
        XCTAssertNil(CurrentWordExtractor.extractTrailingWord(from: "hi my nmae  "))
    }

    func test_trailingWord_rejectsTrailingTabOrNewline() {
        XCTAssertNil(CurrentWordExtractor.extractTrailingWord(from: "hi my nmae\t"))
        XCTAssertNil(CurrentWordExtractor.extractTrailingWord(from: "hi my nmae\n"))
    }

    func test_trailingWord_rejectsImplausibleWordEvenWithSpace() {
        XCTAssertNil(CurrentWordExtractor.extractTrailingWord(from: "open https://example.com "))
    }

    // MARK: - Typo replacement planning

    func test_typoReplacement_preservesCommittedSpaceAndUsesUTF16Count() {
        let replacement = TypoCorrectionReplacementPlanner.plan(
            precedingText: "hi my nmae ",
            expectedTypo: "nmae",
            correctedWord: "name",
            requiresTrailingSpace: true
        )

        XCTAssertEqual(
            replacement,
            TypoCorrectionReplacement(deletingUTF16Count: 5, replacementText: "name ")
        )
    }

    func test_typoReplacement_rejectsAutomaticFixBeforeSpace() {
        XCTAssertNil(
            TypoCorrectionReplacementPlanner.plan(
                precedingText: "hi my nmae",
                expectedTypo: "nmae",
                correctedWord: "name",
                requiresTrailingSpace: true
            )
        )
    }

    func test_typoReplacement_rejectsChangedTrailingWord() {
        XCTAssertNil(
            TypoCorrectionReplacementPlanner.plan(
                precedingText: "hi my names ",
                expectedTypo: "nmae",
                correctedWord: "name",
                requiresTrailingSpace: false
            )
        )
    }
}
