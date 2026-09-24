import XCTest
@testable import Cotabby

/// Pins the cloud chat prompt contract: stable context first, caret text last, both sides of the
/// caret present, and the alternates instruction only when alternates were requested.
final class EndpointChatPromptRendererTests: XCTestCase {
    func test_render_putsSuffixBeforePrefixAndPrefixLast() {
        // #given a request with clipboard, screen, and text on both sides of the caret
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "Can we move our meeting to ",
            clipboardContext: "Q3 deck",
            visualContextSummary: "Calendar: Friday 2pm",
            suffixText: " so I can prep the deck?"
        )

        // #when the prompt is rendered
        let prompt = EndpointChatPromptRenderer.render(for: request)

        // #then the caret prefix is the final block and the suffix precedes it
        XCTAssertTrue(prompt.user.hasSuffix("Can we move our meeting to "))
        let suffixRange = try? XCTUnwrap(prompt.user.range(of: "so I can prep the deck?"))
        let prefixRange = try? XCTUnwrap(prompt.user.range(of: "Can we move our meeting to"))
        XCTAssertLessThan(suffixRange!.lowerBound, prefixRange!.lowerBound)
        XCTAssertTrue(prompt.user.contains("(the caret follows a space)"))
        XCTAssertTrue(prompt.user.hasPrefix("On the clipboard:"))
    }

    func test_systemPrompt_mentionsAlternateMarkerOnlyWhenRequested() {
        let withAlternates = CotabbyTestFixtures.suggestionRequest(alternateCount: 2)
        let withoutAlternates = CotabbyTestFixtures.suggestionRequest(alternateCount: 0)

        XCTAssertTrue(EndpointChatPromptRenderer.systemPrompt(for: withAlternates).contains("###ALT###"))
        XCTAssertFalse(EndpointChatPromptRenderer.systemPrompt(for: withoutAlternates).contains("###ALT###"))
    }

    func test_systemPrompt_carriesPersonaNotesAndLength() {
        let request = CotabbyTestFixtures.suggestionRequest(
            completionLengthInstruction: "Return only the next 4 to 7 words.",
            userName: "Sam",
            extendedContext: "Cotabby, Groq"
        )

        let system = EndpointChatPromptRenderer.systemPrompt(for: request)

        XCTAssertTrue(system.contains("The writer's name is Sam."))
        XCTAssertTrue(system.contains("Cotabby, Groq"))
        XCTAssertTrue(system.contains("Return only the next 4 to 7 words."))
    }

    func test_userPrompt_prefixScaleKeepsTextNearestTheCaret() {
        let request = CotabbyTestFixtures.suggestionRequest(prefixText: "0123456789")

        let user = EndpointChatPromptRenderer.userPrompt(for: request, prefixScale: 0.5)

        XCTAssertTrue(user.hasSuffix("\n56789"))
    }

    // MARK: - AlternateCandidateSplitter

    func test_split_separatesPrimaryAndDeduplicatedAlternates() {
        let raw = "and I have a few questions.\n\n###ALT###\nand I have a couple of concerns.\nand I have a few questions.\n\nand I noticed a few typos."

        let split = AlternateCandidateSplitter.split(raw, maxAlternates: 2)

        XCTAssertEqual(split.primary, "and I have a few questions.")
        XCTAssertEqual(split.alternates, ["and I have a couple of concerns.", "and I noticed a few typos."])
    }

    func test_split_withoutMarkerReturnsWholeTextAsPrimary() {
        let split = AlternateCandidateSplitter.split("tomorrow morning", maxAlternates: 2)

        XCTAssertEqual(split, .init(primary: "tomorrow morning", alternates: []))
    }

    func test_primaryForPartial_neverLeaksMarkerOrItsPrefix() {
        XCTAssertEqual(AlternateCandidateSplitter.primaryForPartial("terms and\n\n###"), "terms and")
        XCTAssertEqual(AlternateCandidateSplitter.primaryForPartial("terms and\n\n###ALT###\nclau"), "terms and")
        XCTAssertEqual(AlternateCandidateSplitter.primaryForPartial("terms and conditions"), "terms and conditions")
    }

    // MARK: - PartialWordOverlapTrimmer

    func test_trim_dropsRepeatedPartialWord() {
        XCTAssertEqual(
            PartialWordOverlapTrimmer.trim("terms and conditions.", precedingText: "questions about the ter"),
            "ms and conditions."
        )
    }

    func test_trim_isCaseInsensitiveAndKeepsSuggestionCase() {
        XCTAssertEqual(PartialWordOverlapTrimmer.trim("Thanks again", precedingText: "th"), "anks again")
    }

    func test_trim_leavesSuggestionAloneAfterWhitespaceOrOnMismatch() {
        XCTAssertEqual(PartialWordOverlapTrimmer.trim("terms", precedingText: "about the "), "terms")
        XCTAssertEqual(PartialWordOverlapTrimmer.trim("ms and", precedingText: "about the ter"), "ms and")
        XCTAssertEqual(PartialWordOverlapTrimmer.trim(" and more", precedingText: "about the ter"), " and more")
    }
}
