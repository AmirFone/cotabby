import XCTest
@testable import Cotabby

/// Covers the Jev request shape, tolerant response parsing, verdict-to-candidate mapping, and the
/// refiner's rationing: nothing without a key, one call per word, a cached verdict afterwards, and
/// silence after the key is rejected.
@MainActor
final class WordIntentRefinerTests: XCTestCase {
    private let wichRequest = JevWordIntentRequest(
        typedWord: "wich",
        textBefore: "I don't know ",
        textAfter: " one to pick",
        options: ["which", "with", "wish"],
        includesTypedWord: false
    )

    func test_body_marksTheWordAndOffersEachCandidate() throws {
        // #when
        let body = JevWordIntentClient.body(for: wichRequest)

        // #then
        let state = try XCTUnwrap(body["state"] as? [String: String])
        XCTAssertEqual(state["text"], "I don't know [[wich]] one to pick")
        let questions = try XCTUnwrap(body["questions"] as? [String: Any])
        let question = try XCTUnwrap(questions[JevWordIntentClient.questionKey] as? [String: Any])
        XCTAssertEqual(question["type"] as? String, "choice")
        XCTAssertEqual(Set((question["criteria"] as? [String: String])?.keys ?? [:].keys), ["which", "with", "wish"])
        XCTAssertEqual(body["model"] as? String, "jev-latest")
    }

    func test_body_realWordCheckAddsKeepAsTypedOption() {
        let request = JevWordIntentRequest(
            typedWord: "their", textBefore: "I went ", textAfter: "", options: ["there"], includesTypedWord: true
        )

        XCTAssertEqual(JevWordIntentClient.allOptions(for: request), ["there", "their"])
    }

    func test_parse_readsProbabilityMap() throws {
        let json = #"{"model":"jev-1.13.0","answers":{"intended_word":{"type":"choice","choice":"which","probabilities":{"which":0.93,"with":0.05,"wish":0.02},"confidence":0.91}}}"#

        let verdict = try JevWordIntentClient.parse(Data(json.utf8), options: ["which", "with", "wish"])

        XCTAssertEqual(verdict.probabilities["which"], 0.93)
        XCTAssertEqual(verdict.confidence, 0.91)
    }

    func test_parse_readsProbabilityArrayInCriteriaOrder() throws {
        let json = #"{"answers":{"intended_word":{"choice":"with","probabilities":[0.2,0.8],"confidence":0.7}}}"#

        let verdict = try JevWordIntentClient.parse(Data(json.utf8), options: ["which", "with"])

        XCTAssertEqual(verdict.probabilities, ["which": 0.2, "with": 0.8])
    }

    func test_mapper_ordersByProbabilityAndReportsTypedWord() {
        let verdict = JevWordIntentVerdict(probabilities: ["there": 0.88, "their": 0.12], confidence: 0.8)

        let mapped = WordIntentVerdictMapper.candidates(from: verdict, typedWord: "Their", personal: [:])

        XCTAssertEqual(mapped.candidates.map(\.term), ["There"])
        XCTAssertEqual(mapped.typedProbability, 0.12)
    }

    func test_refiner_withoutKey_neverCalls() async {
        let calls = CallCounter()
        let refiner = WordIntentRefiner(apiKeyProvider: { nil }, fetch: { _, _ in
            await calls.increment()
            return JevWordIntentVerdict(probabilities: [:], confidence: 0)
        })

        refiner.request(wichRequest)
        try? await Task.sleep(nanoseconds: 300_000_000)

        let count = await calls.value
        XCTAssertEqual(count, 0)
        XCTAssertEqual(refiner.status, .noKey)
    }

    func test_refiner_cachesVerdictAndAnnounces() async {
        let refined = expectation(description: "refined")
        let refiner = WordIntentRefiner(apiKeyProvider: { "key" }, fetch: { _, _ in
            JevWordIntentVerdict(probabilities: ["which": 0.9, "with": 0.1], confidence: 0.9)
        })
        refiner.onRefined = { refined.fulfill() }

        refiner.request(wichRequest)
        await fulfillment(of: [refined], timeout: 2)

        let key = WordIntentRefiner.Key(word: "wich", textBefore: "I don't know ")
        XCTAssertEqual(refiner.verdict(for: key)?.probabilities["which"], 0.9)
    }

    func test_refiner_burstOfRequests_sendsOnlyTheLast() async {
        let calls = CallCounter()
        let refined = expectation(description: "refined")
        let refiner = WordIntentRefiner(apiKeyProvider: { "key" }, fetch: { request, _ in
            await calls.record(request.typedWord)
            return JevWordIntentVerdict(probabilities: ["x": 1], confidence: 1)
        })
        refiner.onRefined = { refined.fulfill() }

        for partial in ["reci", "recie", "reciev"] {
            refiner.request(JevWordIntentRequest(
                typedWord: partial, textBefore: "", textAfter: "", options: ["receive", "recipe"], includesTypedWord: false
            ))
        }
        await fulfillment(of: [refined], timeout: 2)

        let words = await calls.words
        XCTAssertEqual(words, ["reciev"])
    }

    func test_refiner_rejectedKey_stopsCalling() async {
        let refiner = WordIntentRefiner(apiKeyProvider: { "bad" }, fetch: { _, _ in
            throw JevWordIntentError.unauthorized
        })

        refiner.request(wichRequest)
        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(refiner.status, .unauthorized)
        XCTAssertFalse(refiner.isAvailable)
    }
}

private actor CallCounter {
    private(set) var value = 0
    private(set) var words: [String] = []

    func increment() { value += 1 }

    func record(_ word: String) {
        value += 1
        words.append(word)
    }
}
