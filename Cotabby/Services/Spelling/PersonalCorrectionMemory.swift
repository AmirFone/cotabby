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
    static let standingDefaultsKey = "cotabbyWordsLeftStanding"
    /// A flagged word left standing in this many finished lines is the writer's own word (see
    /// `recordLeftStanding`).
    static let linesBeforeAWordIsKept = 3
    /// Oldest-inserted typos are evicted past this size, bounding the plist.
    static let maximumTypos = 2_000

    private let userDefaults: UserDefaults
    private var entries: [String: [String: Int]]
    private var insertionOrder: [String]
    /// Words (or `previous word` pairs for real-word checks) the writer chose to keep as typed.
    private var kept: [String]
    /// How many finished lines each flagged word was left standing in, for words not yet kept.
    private var leftStanding: [String: Int]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        entries = userDefaults.dictionary(forKey: Self.defaultsKey) as? [String: [String: Int]] ?? [:]
        insertionOrder = Array(entries.keys)
        kept = userDefaults.stringArray(forKey: Self.keptDefaultsKey) ?? []
        leftStanding = userDefaults.dictionary(forKey: Self.standingDefaultsKey) as? [String: Int] ?? [:]
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
        // Correcting a word says it was not meant as typed, whatever an earlier undo suggested.
        // Without this, undoing one wrong automatic fix (`wich` made into `with` when `which` was
        // meant) marked the slip as intended and it was never flagged again.
        if let index = kept.firstIndex(of: key) {
            kept.remove(at: index)
            userDefaults.set(kept, forKey: Self.keptDefaultsKey)
        }
        if leftStanding.removeValue(forKey: key) != nil {
            userDefaults.set(leftStanding, forKey: Self.standingDefaultsKey)
        }
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

    /// The writer undid an automatic fix, or changed it into another word. Returns true when that
    /// fix was a habit of theirs (made often enough to be automatic), in which case it is only
    /// taken down a step: it still leads the bar, and is automatic again once they make it again.
    ///
    /// Why not simply "keep the word as typed", as for any other undone fix: a kept word is never
    /// flagged again, and one undo then switched off a fix the writer had made dozens of times.
    /// In a recorded day the commonest slip of all (a ninth of every slip made) was undone once,
    /// possibly by a stray key, and from then on stood in the text unflagged. One undo against a
    /// habit is a doubt, not a verdict.
    @discardableResult
    func demoteHabit(typo: String, fix: String) -> Bool {
        let key = typo.lowercased(), value = fix.lowercased()
        guard let count = entries[key]?[value], count >= SpellingCandidateRanker.habitAutoCount else { return false }
        entries[key]?[value] = SpellingCandidateRanker.habitLeadCount
        userDefaults.set(entries, forKey: Self.defaultsKey)
        return true
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

    /// A word Cotabby flags was still there, as typed, in a line the writer finished: they saw
    /// the offer, or would have, and wrote on. The third such line makes the word kept, as if
    /// they had picked the quoted slot on the bar. Returns true when this call did that.
    ///
    /// Why: nothing used to learn from typing past the bar, only from the quoted slot, which this
    /// fork's writer never used in a day of work. A product name they wrote 25 times was flagged
    /// 24 times, with the same wrong fix offered each time, and the sentence model "corrected" it
    /// besides.
    ///
    /// Why three lines and not one: a slip the writer did not notice is also left standing. On
    /// that same day every such slip (53 forms) stood in exactly one line; the words that came
    /// back were real ones. A word with a fix on record is never counted (the writer has said
    /// what it should have been), and accepting a fix later takes a kept word back out
    /// (`recordAccepted`), so a wrong lesson can be unlearned by correcting the word once.
    @discardableResult
    func recordLeftStanding(_ word: String) -> Bool {
        let key = word.lowercased()
        guard key.count >= 3, !kept.contains(key), entries[key] == nil else { return false }
        let lines = (leftStanding[key] ?? 0) + 1
        defer { userDefaults.set(leftStanding, forKey: Self.standingDefaultsKey) }
        guard lines >= Self.linesBeforeAWordIsKept else {
            // Mostly one-off slips, which never come back: when the tally is full, the singles go.
            if leftStanding.count >= Self.maximumTypos { leftStanding = leftStanding.filter { $0.value > 1 } }
            leftStanding[key] = lines
            return false
        }
        leftStanding.removeValue(forKey: key)
        recordKept(key)
        return true
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

    /// True when a kept word begins with `letters` (lowercase): the writer may be in the middle
    /// of typing it.
    func isStartOfKeptWord(_ letters: String) -> Bool {
        !letters.isEmpty && kept.contains { $0.hasPrefix(letters) }
    }

    /// Forgets every learned fix and kept word, here and in UserDefaults. Called when the writer
    /// clears what Cotabby learned in Settings (`CotabbyAppEnvironment.forgetEverythingLearned`);
    /// until it was, nothing in the app could undo a wrongly learned fix.
    func reset() {
        entries = [:]
        insertionOrder = []
        kept = []
        leftStanding = [:]
        userDefaults.removeObject(forKey: Self.defaultsKey)
        userDefaults.removeObject(forKey: Self.keptDefaultsKey)
        userDefaults.removeObject(forKey: Self.standingDefaultsKey)
    }
}
