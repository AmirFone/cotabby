import Combine
import Foundation

/// File overview:
/// Settings-facing owner of the optional Jev API key. The key lives in Keychain (never
/// UserDefaults or logs); saving or removing it tells `WordIntentRefiner` to reload, so Jev turns
/// on or off without a relaunch. "Test" sends one sample decision so the writer can see the key work
/// and how fast Jev answers from this network.
@MainActor
final class JevKeyModel: ObservableObject {
    @Published private(set) var hasKey = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var isTesting = false

    let credentialStore: KeychainOpenAICompatibleCredentialStore
    var onKeyChanged: (() -> Void)?

    init(credentialStore: KeychainOpenAICompatibleCredentialStore? = nil) {
        let credentialStore = credentialStore ?? KeychainOpenAICompatibleCredentialStore(account: "jev-api-key")
        self.credentialStore = credentialStore
        hasKey = (try? credentialStore.readAPIKey()) != nil
    }

    nonisolated deinit {}

    func readAPIKey() -> String? {
        try? credentialStore.readAPIKey()
    }

    func save(_ key: String) {
        do {
            try credentialStore.saveAPIKey(key)
            hasKey = readAPIKey() != nil
            statusMessage = hasKey ? "Saved. Press Test to check it." : nil
            onKeyChanged?()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func remove() {
        try? credentialStore.deleteAPIKey()
        hasKey = false
        statusMessage = "Removed. Corrections are fully local."
        onKeyChanged?()
    }

    func test() {
        guard let key = readAPIKey(), !isTesting else { return }
        isTesting = true
        statusMessage = "Testing…"
        let request = JevWordIntentRequest(
            typedWord: "wich",
            textBefore: "I can't decide ",
            textAfter: " one to buy.",
            options: ["with", "which", "wish"],
            includesTypedWord: false
        )
        Task {
            let start = Date()
            do {
                let verdict = try await JevWordIntentClient.verdict(for: request, apiKey: key)
                let milliseconds = Int(Date().timeIntervalSince(start) * 1000)
                let best = verdict.probabilities.max { $0.value < $1.value }
                statusMessage = best.map {
                    "Works. \"I can't decide wich one\" → \($0.key) (\(Int($0.value * 100))%) in \(milliseconds) ms."
                } ?? "Jev answered in \(milliseconds) ms."
            } catch JevWordIntentError.unauthorized {
                statusMessage = "Jev rejected this key."
            } catch JevWordIntentError.rateLimited {
                statusMessage = "Jev is rate limiting this key. Try again in a minute."
            } catch {
                statusMessage = "Test failed: \(error.localizedDescription)"
            }
            isTesting = false
        }
    }
}
