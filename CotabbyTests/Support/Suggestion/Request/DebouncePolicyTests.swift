import XCTest
@testable import Cotabby

final class DebouncePolicyTests: XCTestCase {
    func testNoLatencyDataUsesFallback() {
        XCTAssertEqual(DebouncePolicy.milliseconds(lastGenerationLatencyMilliseconds: nil, fallback: 20), 20)
        XCTAssertEqual(DebouncePolicy.milliseconds(lastGenerationLatencyMilliseconds: 0, fallback: 20), 20)
    }

    func testFastGenerationsGetTheShortDebounce() {
        XCTAssertEqual(DebouncePolicy.milliseconds(lastGenerationLatencyMilliseconds: 45, fallback: 20), 15)
        XCTAssertEqual(DebouncePolicy.milliseconds(lastGenerationLatencyMilliseconds: 70, fallback: 20), 15)
    }

    func testMediumGenerationsGetTheMiddleDebounce() {
        XCTAssertEqual(DebouncePolicy.milliseconds(lastGenerationLatencyMilliseconds: 71, fallback: 20), 25)
        XCTAssertEqual(DebouncePolicy.milliseconds(lastGenerationLatencyMilliseconds: 140, fallback: 20), 25)
    }

    func testSlowGenerationsBackOff() {
        XCTAssertEqual(DebouncePolicy.milliseconds(lastGenerationLatencyMilliseconds: 141, fallback: 20), 55)
        XCTAssertEqual(DebouncePolicy.milliseconds(lastGenerationLatencyMilliseconds: 900, fallback: 20), 55)
    }

    func testEndpointUsesTrailingDebounceToCollapseTypingBursts() {
        XCTAssertEqual(
            DebouncePolicy.milliseconds(
                lastGenerationLatencyMilliseconds: nil,
                fallback: 20,
                engine: .openAICompatible
            ),
            180
        )
        XCTAssertEqual(
            DebouncePolicy.milliseconds(
                lastGenerationLatencyMilliseconds: 250,
                fallback: 20,
                engine: .openAICompatible
            ),
            100
        )
        XCTAssertEqual(
            DebouncePolicy.milliseconds(
                lastGenerationLatencyMilliseconds: 600,
                fallback: 20,
                engine: .openAICompatible
            ),
            150
        )
        XCTAssertEqual(
            DebouncePolicy.milliseconds(
                lastGenerationLatencyMilliseconds: 1_000,
                fallback: 20,
                engine: .openAICompatible
            ),
            220
        )
    }

    func test_cloudEndpoint_usesShortPausesKeyedToGroqLatency() {
        // #given a Groq-backed endpoint with no latency yet and with typical round trips
        // #when the debounce is chosen
        // #then it stays well under the local-endpoint pauses
        XCTAssertEqual(
            DebouncePolicy.milliseconds(lastGenerationLatencyMilliseconds: nil, fallback: 20, engine: .openAICompatible, isCloudEndpoint: true),
            90
        )
        XCTAssertEqual(
            DebouncePolicy.milliseconds(lastGenerationLatencyMilliseconds: 180, fallback: 20, engine: .openAICompatible, isCloudEndpoint: true),
            60
        )
        XCTAssertEqual(
            DebouncePolicy.milliseconds(lastGenerationLatencyMilliseconds: 450, fallback: 20, engine: .openAICompatible, isCloudEndpoint: true),
            100
        )
        XCTAssertEqual(
            DebouncePolicy.milliseconds(lastGenerationLatencyMilliseconds: 900, fallback: 20, engine: .openAICompatible, isCloudEndpoint: true),
            160
        )
    }
}
