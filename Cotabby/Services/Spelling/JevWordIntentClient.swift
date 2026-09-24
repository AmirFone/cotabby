import Foundation

/// File overview:
/// Asks TypeSafe's Jev model which word the writer meant. Jev is a "System One" decision model: it
/// does not write text, it picks among options the caller supplies and returns calibrated
/// probabilities, which is exactly the shape of a spelling decision. Cotabby supplies the local
/// candidates (SymSpell, the system spell checker, personal history) and Jev reads the surrounding
/// text to decide between them, typically in 70–500 ms.
///
/// API: `POST https://api.typesafe.ai/v1/systemone` with a `state` and a map of typed questions.
/// See https://docs.typesafe.ai/api.
nonisolated struct JevWordIntentRequest: Equatable, Sendable {
    let typedWord: String
    let textBefore: String
    let textAfter: String
    /// Lowercased candidate words, best local guess first.
    let options: [String]
    /// Whether "the typed word is right" is one of the options (real-word checks, not typos).
    let includesTypedWord: Bool
}

nonisolated struct JevWordIntentVerdict: Equatable, Sendable {
    /// Probability per lowercased option, typed word included when it was offered.
    let probabilities: [String: Double]
    let confidence: Double
}

nonisolated enum JevWordIntentError: Error, Equatable {
    case unauthorized
    case rateLimited
    case failed(String)
}

nonisolated enum JevWordIntentClient {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let model = "jev-latest"
    static let questionKey = "intended_word"
    /// Enough surrounding text to carry the sentence's meaning without paying for a whole document.
    static let maximumContextCharacters = 400

    static func verdict(
        for request: JevWordIntentRequest,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> JevWordIntentVerdict {
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: 2.5)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body(for: request))

        let (data, response) = try await session.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            return try parse(data, options: allOptions(for: request))
        case 401, 403:
            throw JevWordIntentError.unauthorized
        case 429, 529:
            throw JevWordIntentError.rateLimited
        default:
            let message = String(bytes: data.prefix(300), encoding: .utf8) ?? ""
            throw JevWordIntentError.failed("HTTP \(status) \(message)")
        }
    }

    static func allOptions(for request: JevWordIntentRequest) -> [String] {
        let typed = request.typedWord.lowercased()
        var options = request.options.filter { $0 != typed }
        if request.includesTypedWord {
            options.append(typed)
        }
        return options
    }

    static func body(for request: JevWordIntentRequest) -> [String: Any] {
        let typed = request.typedWord.lowercased()
        var criteria: [String: String] = [:]
        for option in allOptions(for: request) {
            criteria[option] = option == typed
                ? "Keep \"\(request.typedWord)\" exactly as typed; it is already the intended word."
                : "The writer meant \"\(option)\"."
        }
        let marked = String(request.textBefore.suffix(maximumContextCharacters))
            + "[[\(request.typedWord)]]"
            + String(request.textAfter.prefix(maximumContextCharacters / 2))
        let instructions = request.includesTypedWord
            ? "The writer is dyslexic and sometimes types a real word that is the wrong word. "
                + "Given the meaning of the text, which word did they intend at the position marked [[ ]]?"
            : "The writer is dyslexic and misspelled the word marked [[ ]]. "
                + "Given the meaning of the text, which word did they intend?"
        return [
            "model": model,
            "state": ["text": marked, "typed_word": request.typedWord],
            "questions": [
                questionKey: [
                    "type": "choice",
                    "instructions": instructions,
                    "criteria": criteria
                ]
            ]
        ]
    }

    /// Accepts probabilities as an option→value map or as an array in criteria order, and falls back
    /// to the single chosen option when neither is present.
    static func parse(_ data: Data, options: [String]) throws -> JevWordIntentVerdict {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any],
              let answer = answers[questionKey] as? [String: Any] else {
            throw JevWordIntentError.failed("unexpected response shape")
        }
        let confidence = (answer["confidence"] as? NSNumber)?.doubleValue ?? 0
        var probabilities: [String: Double] = [:]
        if let map = answer["probabilities"] as? [String: Any] {
            for (key, value) in map {
                if let number = value as? NSNumber { probabilities[key.lowercased()] = number.doubleValue }
            }
        } else if let list = answer["probabilities"] as? [NSNumber], list.count == options.count {
            for (option, value) in zip(options, list) { probabilities[option] = value.doubleValue }
        }
        if probabilities.isEmpty, let choice = answer["choice"] as? String {
            probabilities[choice.lowercased()] = confidence
        }
        guard !probabilities.isEmpty else { throw JevWordIntentError.failed("no probabilities") }
        return JevWordIntentVerdict(probabilities: probabilities, confidence: confidence)
    }
}
