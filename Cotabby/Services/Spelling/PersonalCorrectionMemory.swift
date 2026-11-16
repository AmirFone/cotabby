import Foundation

/// Remembers which replacement the writer chose for each misspelling.
///
/// Dictionaries rank corrections by how common a word is in books, but one person's recurring
/// misspellings are far more predictable than that: someone who always types `becuase` always means
/// `because`. Every accepted, auto-applied, or list-picked fix is recorded here and fed back into
/// `SpellingCandidateRanker`, so repeat fixes climb toward the auto-apply tier over days of use.
///
/// `CotabbyAppEnvironment` owns one instance for the app lifetime. Storage is a small UserDefaults
/// dictionary keyed by the lowercased typo; it holds only words the writer already typed into
/// fields where Cotabby was active and never leaves the Mac.
@MainActor
final class PersonalCorrectionMemory {
    static let defaultsKey = "cotabbyPersonalCorrections"
    static let keptDefaultsKey = "cotabbyKeptWords"
    /// Oldest-inserted typos are evicted past this size, bounding the plist.
    static let maximumTypos = 2_000

    private let userDefaults: UserDefaults
    private var entries: [String: [String: Int]]
    private var insertionOrder: [String]
    /// Words (or `previous word` pairs for real-word checks) the writer chose to keep as typed.
    private var kept: [String]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        entries = userDefaults.dictionary(forKey: Self.defaultsKey) as? [String: [String: Int]] ?? [:]
        insertionOrder = Array(entries.keys)
        kept = userDefaults.stringArray(forKey: Self.keptDefaultsKey) ?? []
    }

    /// Main-actor stores deallocated inside app-hosted tests need a nonisolated deinit; see
    /// `SuggestionQualityMetricsStore`.
    nonisolated deinit {}

    /// Accept counts per lowercased replacement for `typo`.
    func acceptedReplacements(for typo: String) -> [String: Int] {
        entries[typo.lowercased()] ?? [:]
    }

    func recordAccepted(typo: String, replacement: String) {
        let key = typo.lowercased()
        let value = replacement.lowercased()
        guard !key.isEmpty, !value.isEmpty, key != value else { return }
        if entries[key] == nil {
            insertionOrder.append(key)
        }
        entries[key, default: [:]][value, default: 0] += 1
        while entries.count > Self.maximumTypos, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        userDefaults.set(entries, forKey: Self.defaultsKey)
    }

    /// Picking the quoted "as typed" slot means "stop flagging this", so the bar does not come back
    /// for the same word a moment later.
    func recordKept(_ key: String) {
        let key = key.lowercased()
        guard !key.isEmpty, !kept.contains(key) else { return }
        kept.append(key)
        if kept.count > Self.maximumTypos { kept.removeFirst(kept.count - Self.maximumTypos) }
        userDefaults.set(kept, forKey: Self.keptDefaultsKey)
    }

    /// Settled automatic fixes: kept ones count as accepted, undone ones mark the typed word as
    /// intended.
    func record(changes: [(typed: String, fixed: String)], kept: Bool) {
        for change in changes {
            if kept {
                recordAccepted(typo: change.typed, replacement: change.fixed)
            } else {
                recordKept(change.typed)
            }
        }
    }

    enum ReviewOutcome {
        case accepted
        case kept
    }

    /// One decision on the sentence review card. A chosen replacement counts like a picked fix. A
    /// kept word stops being flagged: a real word under "previous word + word" (the key the
    /// wrong-word checks read, so `their house` is remembered without silencing every `their`), a
    /// misspelling under the word itself.
    @discardableResult
    func recordReviewChoice(typed: String, previous: String?, chosen: String, isRealWord: Bool) -> ReviewOutcome {
        guard chosen.lowercased() == typed.lowercased() else {
            recordAccepted(typo: typed, replacement: chosen)
            return .accepted
        }
        if let previous, isRealWord {
            recordKept("\(previous) \(typed)")
        } else {
            recordKept(typed)
        }
        return .kept
    }

    func isKept(_ key: String) -> Bool {
        kept.contains(key.lowercased())
    }

    func reset() {
        entries = [:]
        insertionOrder = []
        kept = []
        userDefaults.removeObject(forKey: Self.defaultsKey)
        userDefaults.removeObject(forKey: Self.keptDefaultsKey)
    }
}
