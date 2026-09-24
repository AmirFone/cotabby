import AppKit
import SwiftUI
import XCTest
@testable import Cotabby

/// Opt-in checks against the real Groq API and the real SwiftUI panels. Skipped unless
/// `COTABBY_GROQ_LIVE_KEY` is set (pass it to xcodebuild as `TEST_RUNNER_COTABBY_GROQ_LIVE_KEY`),
/// so CI and ordinary test runs never touch the network or the window server.
@MainActor
final class GroqLiveSmokeTests: XCTestCase {
    private var liveKey: String? {
        ProcessInfo.processInfo.environment["COTABBY_GROQ_LIVE_KEY"].flatMap { $0.isEmpty ? nil : $0 }
    }

    func test_live_cloudContinuationStreamsPrimaryAndAlternates() async throws {
        try XCTSkipUnless(liveKey != nil, "set COTABBY_GROQ_LIVE_KEY to run")
        let key = liveKey ?? ""
        let configuration = try OpenAICompatibleEndpointConfiguration(
            baseURLString: OpenAICompatibleProviderPreset.groqBaseURLString,
            modelName: OpenAICompatibleProviderPreset.groqDefaultModelName,
            apiMode: .chatCompletions,
            provider: .groq
        )
        let engine = OpenAICompatibleSuggestionEngine(
            client: OpenAICompatibleAPIClient(),
            configurationProvider: { configuration },
            apiKeyProvider: { key },
            rateGovernor: EndpointRateGovernor(tokensPerMinute: 250_000)
        )
        let context = CotabbyTestFixtures.focusedInputContext(
            precedingText: "Hey Sarah,\n\nThanks for sending over the contract. I read throught it last night and I have a few questions about the ",
            trailingText: ""
        )
        let settings = CotabbyTestFixtures.settingsSnapshot(
            selectedEngine: .openAICompatible,
            selectedWordCountPreset: .fourToSeven,
            endpointProvider: .groq
        )
        let request = SuggestionRequestFactory.buildRequest(context: context, settings: settings, configuration: .standard).request

        var partials = 0
        let started = Date()
        let result = try await engine.generateSuggestion(for: request) { _ in partials += 1 }
        let milliseconds = Int(Date().timeIntervalSince(started) * 1_000)

        print("LIVE continuation (\(milliseconds) ms, \(partials) partials): \(result.text.debugDescription) alternates=\(result.alternates)")
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertFalse(result.text.contains("###"))
        XCTAssertFalse(result.alternates.isEmpty, "gpt-oss-20b should return alternates after the marker")
    }

    func test_live_sentenceCheckFixesRealWordErrors() async throws {
        try XCTSkipUnless(liveKey != nil, "set COTABBY_GROQ_LIVE_KEY to run")
        let key = liveKey ?? ""
        let configuration = try OpenAICompatibleEndpointConfiguration(
            baseURLString: OpenAICompatibleProviderPreset.groqBaseURLString,
            modelName: OpenAICompatibleProviderPreset.groqDefaultModelName,
            apiMode: .chatCompletions,
            provider: .groq
        )
        let finished = try XCTUnwrap(FinishedSentenceExtractor.extract(from: "Hi Sarah. I recieved there email yesterday and form it I learned alot. "))

        let started = Date()
        let result = try await OpenAICompatibleAPIClient().checkSentence(
            configuration: configuration,
            apiKey: key,
            sentence: finished.sentence,
            precedingContext: finished.precedingContext,
            knownTerms: nil
        )
        let milliseconds = Int(Date().timeIntervalSince(started) * 1_000)
        let fix = try XCTUnwrap(result)
        let plan = SentenceRewritePlanner.plan(
            precedingText: "Hi Sarah. " + finished.sentence + " ",
            finished: finished,
            corrected: fix.corrected
        )

        print("LIVE sentence (\(milliseconds) ms): \(fix.corrected) edits=\(fix.edits.map { "\($0.from)->\($0.to)@\($0.confidence)" }) plan=\(String(describing: plan))")
        XCTAssertTrue(fix.corrected.contains("received"))
        XCTAssertTrue(fix.corrected.contains("their"))
        XCTAssertNotNil(plan)
    }

    func test_render_candidatePanelsToPNG() throws {
        let renderDirectory = ProcessInfo.processInfo.environment["COTABBY_RENDER_DIR"]
        try XCTSkipUnless(renderDirectory != nil, "set COTABBY_RENDER_DIR to run")
        let directory = renderDirectory ?? ""
        let model = CandidateListViewModel()
        let states: [(String, CandidateListViewModel.Content, Int)] = [
            ("bar", .bar(rows: [
                .init(text: "wich", confidence: 0),
                .init(text: "which", confidence: 0.9),
                .init(text: "with", confidence: 0.6)
            ], isContextRefined: false), 1),
            ("bar-refined", .bar(rows: [
                .init(text: "their", confidence: 0),
                .init(text: "there", confidence: 0.88)
            ], isContextRefined: true), 1),
            ("list", .choices(header: "wich", rows: [
                .init(text: "which", confidence: 0.99),
                .init(text: "with", confidence: 0.9),
                .init(text: "wish", confidence: 0.6),
                .init(text: "witch", confidence: 0.4)
            ]), 1),
            ("alternates", .choices(header: nil, rows: [
                .init(text: "tomorrow morning instead?", confidence: nil),
                .init(text: "next week instead?", confidence: nil)
            ]), 0),
            ("flash", .flash(typo: "teh", correction: "the"), 0),
            ("sentence", .sentenceFix(SentenceWordDiff.segments(
                original: "I recieved there email yesterday.",
                corrected: "I received their email yesterday."
            )), 0)
        ]
        for (name, content, selected) in states {
            model.content = content
            model.selectedIndex = selected
            let view = CandidateListView(model: model) { _ in }
                .padding(20)
                .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("panel-\(name).png"))
        }
    }
}
