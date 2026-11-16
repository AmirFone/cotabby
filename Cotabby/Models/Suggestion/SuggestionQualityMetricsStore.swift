import Combine
import Foundation

/// Local, always-on counters that answer "is suggestion quality improving for real use": how many
/// completions were generated, how many were shown, why the withheld ones were withheld, and how
/// many shown suggestions the user actually accepted.
///
/// Latency tracking (`PerformanceMetricsStore`) stays opt-in because it records per-request rows;
/// these are lifetime counters with zero content, so they run unconditionally and survive restarts.
/// Acceptance rate (accepted / shown) is the closest thing to ground truth the app can measure on
/// device, and the suppression histogram tells the difference between "the model produced nothing"
/// and "a specific guard fired", which otherwise only exists scattered through debug-only JSONL.
@MainActor
final class SuggestionQualityMetricsStore: ObservableObject {
    struct Counters: Codable, Equatable {
        var generated = 0
        var shown = 0
        /// Sessions the user accepted at least once. Counted per suggestion, not per Tab press,
        /// so word-by-word acceptance of one suggestion is one acceptance.
        var acceptedSuggestions = 0
        /// Keyed by `CompletionSuppressionReason` raw values plus coordinator-level reasons
        /// (the seam guard verdicts). String-keyed so new reasons never need a schema migration.
        var suppressedByReason: [String: Int] = [:]
        var firstRecordedAt: Date?
        /// Spelling fixes shown as a green ghost or a pick-list (once per misspelled word).
        var correctionsOffered = 0
        /// Fixes the writer accepted with Tab, Return, or a click.
        var correctionsAccepted = 0
        /// The subset of accepted fixes chosen from the pick-list.
        var correctionsChosenFromList = 0
        /// Confident fixes Cotabby applied on its own at a Space.
        var correctionsAutoApplied = 0
        /// Auto-fixes the writer undid (the typed spelling came back); the word is then left alone.
        var correctionsAutoReverted = 0
        /// Words typed by picking them from the next-word strip.
        var wordPredictionsPicked = 0
        var alternatesOpened = 0
        /// Alternates chosen instead of the primary continuation.
        var alternatesPicked = 0
        var sentenceFixesOffered = 0
        var sentenceFixesAccepted = 0

        init() {}

        /// Counters saved before a field existed decode with that field at zero instead of failing and
        /// wiping every lifetime count.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            generated = try container.decodeIfPresent(Int.self, forKey: .generated) ?? 0
            shown = try container.decodeIfPresent(Int.self, forKey: .shown) ?? 0
            acceptedSuggestions = try container.decodeIfPresent(Int.self, forKey: .acceptedSuggestions) ?? 0
            suppressedByReason = try container.decodeIfPresent([String: Int].self, forKey: .suppressedByReason) ?? [:]
            firstRecordedAt = try container.decodeIfPresent(Date.self, forKey: .firstRecordedAt)
            correctionsOffered = try container.decodeIfPresent(Int.self, forKey: .correctionsOffered) ?? 0
            correctionsAccepted = try container.decodeIfPresent(Int.self, forKey: .correctionsAccepted) ?? 0
            correctionsChosenFromList = try container.decodeIfPresent(Int.self, forKey: .correctionsChosenFromList) ?? 0
            correctionsAutoApplied = try container.decodeIfPresent(Int.self, forKey: .correctionsAutoApplied) ?? 0
            correctionsAutoReverted = try container.decodeIfPresent(Int.self, forKey: .correctionsAutoReverted) ?? 0
            wordPredictionsPicked = try container.decodeIfPresent(Int.self, forKey: .wordPredictionsPicked) ?? 0
            alternatesOpened = try container.decodeIfPresent(Int.self, forKey: .alternatesOpened) ?? 0
            alternatesPicked = try container.decodeIfPresent(Int.self, forKey: .alternatesPicked) ?? 0
            sentenceFixesOffered = try container.decodeIfPresent(Int.self, forKey: .sentenceFixesOffered) ?? 0
            sentenceFixesAccepted = try container.decodeIfPresent(Int.self, forKey: .sentenceFixesAccepted) ?? 0
        }

        var suppressedTotal: Int { suppressedByReason.values.reduce(0, +) }

        var acceptanceRate: Double? {
            guard shown > 0 else { return nil }
            return Double(acceptedSuggestions) / Double(shown)
        }
    }

    @Published private(set) var counters: Counters

    private let userDefaults: UserDefaults
    private static let defaultsKey = "cotabbyQualityMetricsCounters"

    /// Stored-property @MainActor classes deallocated inside app-hosted tests double-free without
    /// an explicitly nonisolated deinit (the isolated-deinit runtime path over-releases). Same
    /// workaround as the other main-actor stores exercised by tests.
    nonisolated deinit {}

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(Counters.self, from: data) {
            counters = decoded
        } else {
            counters = Counters()
        }
    }

    func recordGenerated() {
        mutate { $0.generated += 1 }
    }

    func recordShown() {
        mutate { $0.shown += 1 }
    }

    func recordAcceptedSuggestion() {
        mutate { $0.acceptedSuggestions += 1 }
    }

    func recordSuppressed(reason: String) {
        mutate { $0.suppressedByReason[reason, default: 0] += 1 }
    }

    func recordCorrectionOffered() {
        mutate { $0.correctionsOffered += 1 }
    }

    func recordCorrectionAccepted(fromList: Bool) {
        mutate {
            $0.correctionsAccepted += 1
            if fromList { $0.correctionsChosenFromList += 1 }
        }
    }

    func recordCorrectionAutoApplied() {
        mutate { $0.correctionsAutoApplied += 1 }
    }

    func recordCorrectionReverted() {
        mutate { $0.correctionsAutoReverted += 1 }
    }

    func recordWordPredictionPicked() {
        mutate { $0.wordPredictionsPicked += 1 }
    }

    func recordAlternatesOpened() {
        mutate { $0.alternatesOpened += 1 }
    }

    func recordAlternatePicked() {
        mutate { $0.alternatesPicked += 1 }
    }

    func recordSentenceFixOffered() {
        mutate { $0.sentenceFixesOffered += 1 }
    }

    func recordSentenceFixAccepted() {
        mutate { $0.sentenceFixesAccepted += 1 }
    }

    func reset() {
        counters = Counters()
        userDefaults.removeObject(forKey: Self.defaultsKey)
    }

    private func mutate(_ change: (inout Counters) -> Void) {
        var updated = counters
        change(&updated)
        if updated.firstRecordedAt == nil {
            updated.firstRecordedAt = Date()
        }
        counters = updated
        if let data = try? JSONEncoder().encode(updated) {
            userDefaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
