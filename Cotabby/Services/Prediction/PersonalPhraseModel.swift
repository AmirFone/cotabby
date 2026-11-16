import AppKit
import Foundation
import Logging

/// The writer's own n-grams, learned from sentences they finish, so predictions pick up their names
/// for things, sign-offs, and habitual phrasing on top of the bundled corpus.
///
/// Counts are keyed exactly like the bundled table (up to three previous words, `<s>` at sentence
/// start, names and numbers as classes) so `NextWordPredictor` scores both the same way. Stored as
/// a small JSON file in Application Support; it never leaves the Mac. Oldest contexts are evicted
/// past `maximumContexts`, and writes are coalesced so typing never waits on disk.
@MainActor
final class PersonalPhraseModel {
    static let maximumContexts = 20_000
    static let learningDefaultsKey = "cotabbyLearnPhrasesEnabled"

    static var isLearningEnabledInDefaults: Bool {
        UserDefaults.standard.object(forKey: learningDefaultsKey) as? Bool ?? true
    }

    /// Only sentences made of dictionary words (names and numbers aside) are learned, so a typo the
    /// writer has not fixed yet never becomes a "phrase" that gets predicted back to them.
    static func isLearnable(_ sentence: String, isWord: (String) -> Bool) -> Bool {
        let tokens = NextWordPredictor.contextTokens(of: sentence).dropFirst()
        return tokens.count >= 2 && tokens.allSatisfy { $0.hasPrefix("<") || isWord($0) }
    }

    private let fileURL: URL?
    private var counts: [String: [String: Int]]
    /// Sum of `counts[context]`, kept alongside so a lookup on every keystroke does not re-add it.
    private var totals: [String: Int]
    private var insertionOrder: [String]
    /// The empty context split by first letter, so completing a half-typed word scans only the
    /// writer's words with that initial instead of every word they ever used.
    private var wordsByInitial: [Character: [String: Int]] = [:]
    private var saveScheduled = false
    private var terminationObserver: NSObjectProtocol?

    init(fileURL: URL? = PersonalPhraseModel.defaultFileURL()) {
        self.fileURL = fileURL
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([String: [String: Int]].self, from: data) {
            counts = stored
        } else {
            counts = [:]
        }
        totals = counts.mapValues { $0.values.reduce(0, +) }
        insertionOrder = Array(counts.keys)
        for (word, count) in counts[""] ?? [:] {
            if let initial = word.first { wordsByInitial[initial, default: [:]][word] = count }
        }
        // The coalesced save runs two seconds after the last sentence; quitting inside that window
        // would otherwise drop what was just learned.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.saveScheduled else { return }
                self.save()
            }
        }
    }

    nonisolated deinit {}

    nonisolated static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Cotabby", isDirectory: true)
            .appendingPathComponent("personal_phrases.json")
    }

    /// The writer's words starting with `prefix`, with the total of all their words, for completing
    /// a half-typed word.
    func words(startingWith prefix: String) -> (total: Int, counts: [String: Int])? {
        guard let initial = prefix.first, let bucket = wordsByInitial[initial], let total = totals[""] else { return nil }
        let matching = bucket.filter { $0.key.hasPrefix(prefix) }
        return matching.isEmpty ? nil : (total, matching)
    }

    /// Counts after a context of one to three words. The empty context is served by
    /// `words(startingWith:)`: scanning every word the writer used on each keystroke is too slow.
    func nextWords(after context: [String]) -> (total: Int, counts: [String: Int])? {
        guard !context.isEmpty else { return nil }
        let key = context.joined(separator: " ")
        guard let found = counts[key], let total = totals[key], total > 0 else { return nil }
        return (total, found)
    }

    /// Times the writer wrote `second` directly after `first` (both lowercased).
    func pairCount(first: String, second: String) -> Int {
        counts[first]?[second] ?? 0
    }

    /// Records every word of a finished sentence after each of its contexts.
    func learn(sentence: String) {
        let tokens = NextWordPredictor.contextTokens(of: sentence)
        guard tokens.count > 2 else { return }
        for index in 1..<tokens.count where !tokens[index].hasPrefix("<") {
            for length in 0...min(NextWordPredictor.maximumContext, index) {
                let key = tokens[(index - length)..<index].joined(separator: " ")
                if counts[key] == nil { insertionOrder.append(key) }
                counts[key, default: [:]][tokens[index], default: 0] += 1
                totals[key, default: 0] += 1
                if length == 0, let initial = tokens[index].first {
                    wordsByInitial[initial, default: [:]][tokens[index], default: 0] += 1
                }
            }
        }
        while counts.count > Self.maximumContexts, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            counts.removeValue(forKey: oldest)
            totals.removeValue(forKey: oldest)
        }
        scheduleSave()
    }

    func reset() {
        counts = [:]
        totals = [:]
        wordsByInitial = [:]
        insertionOrder = []
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func scheduleSave() {
        guard fileURL != nil, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    private func save() {
        saveScheduled = false
        guard let fileURL, let data = try? JSONEncoder().encode(counts) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            CotabbyLogger.app.error("Could not save personal phrases: \(error.localizedDescription)")
        }
    }
}
