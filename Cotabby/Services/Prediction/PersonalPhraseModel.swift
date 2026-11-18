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
    /// The key, among the contexts, of "in how many learned texts each word appeared". Stored with
    /// the counts so the file stays one dictionary and an older file still loads; no real context
    /// can collide with it, because a context is made of words and the three class marks.
    static let spreadKey = "<texts>"
    static let learningDefaultsKey = "cotabbyLearnPhrasesEnabled"

    static var isLearningEnabledInDefaults: Bool {
        UserDefaults.standard.object(forKey: learningDefaultsKey) as? Bool ?? true
    }

    /// Which words of a finished sentence may be counted as the writer's.
    ///
    /// Why word by word: the rule used to be "learn the sentence only if every word is in the
    /// dictionary", so that a misspelling never came back as a suggestion. But a writer's working
    /// sentences are exactly the ones with a system name, an acronym or a term of the trade in
    /// them, and one such word threw away the whole sentence, the ordinary words around it
    /// included. The strip then never learned the vocabulary it was most needed for. Judging each
    /// word keeps the guard (an unknown spelling is still not counted, so it is never offered) and
    /// lets everything else in the sentence teach.
    nonisolated struct Vouching {
        /// A word written in lowercase that is safe to offer back: the dictionary or a bundled
        /// list has it, the writer has used it often enough to be in their own vocabulary, or they
        /// kept it when a fix was offered.
        var isWord: (String) -> Bool
        /// A capitalized word inside a sentence (lowercased here) that is a term of the writer's,
        /// not just any name: `Kubernetes`, a product, a client. Other names stay a class, as the
        /// bundled table has them, and are never offered from here.
        var isOwnName: (String) -> Bool = { _ in false }

        /// Every lowercase word counts. For the measuring tool's upper bound; the app never uses it.
        static let everything = Vouching(isWord: { _ in true })
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
        // A file from before spread was kept: the best guess for a word is that each use was in a
        // text of its own, which leaves what was learned from it weighing what it did.
        if counts[Self.spreadKey] == nil, let words = counts[""] { counts[Self.spreadKey] = words }
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

    /// How many words the writer has typed in everything learned so far.
    var totalWords: Int { totals[""] ?? 0 }

    /// In how many learned texts `word` appeared (see `NextWordPredictor.Sources.personalSpread`).
    func spread(of word: String) -> Int {
        counts[Self.spreadKey]?[word] ?? 0
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

    /// Records the vouched words of a finished sentence after each of their contexts.
    ///
    /// The words before a counted word are keyed as they are (an unknown word included): a context
    /// with a misspelling in it is only found again if the same misspelling is typed again, and
    /// nothing is offered from a key, only from what was counted after it.
    func learn(sentence: String, vouching: Vouching = .everything, at now: Date = Date()) {
        learn(text: [sentence], vouching: vouching, at: now)
    }

    /// How long one sitting lasts. A word's spread goes up once per sitting it was used in.
    ///
    /// Why not once per sentence: the strip trusts a word more the more separate occasions it was
    /// used on (`NextWordPredictor.Habits.usesCountedPerText`), so that a page pasted and sent, or
    /// one afternoon spent on one subject, does not read as a lasting habit. The app learns
    /// sentence by sentence, and forty messages in a row about one thing would be forty occasions.
    /// Half an hour of writing counts as one.
    static let sitting: TimeInterval = 30 * 60
    private var sittingStart: Date?
    private var wordsCountedThisSitting = Set<String>()

    /// Learns the sentences of one text (a message, a note) together: each is counted as `learn`
    /// describes, and a word's spread goes up by one, however many of the sentences use it, unless
    /// it already went up in this sitting.
    func learn(text sentences: [String], vouching: Vouching = .everything, at now: Date = Date()) {
        var counted = Set<String>()
        for sentence in sentences {
            let written = NextWordPredictor.tokens(in: Substring(sentence))
            let tokens = NextWordPredictor.contextTokens(of: sentence)
            guard tokens.count > 2 else { continue }
            for index in 1..<tokens.count {
                // `tokens` starts with the sentence mark, so the word as written is one place back.
                guard let word = Self.countedWord(tokens[index], written: written[index - 1], vouching: vouching) else { continue }
                counted.insert(word)
                for length in 0...min(NextWordPredictor.maximumContext, index) {
                    let key = tokens[(index - length)..<index].joined(separator: " ")
                    if counts[key] == nil { insertionOrder.append(key) }
                    counts[key, default: [:]][word, default: 0] += 1
                    totals[key, default: 0] += 1
                    if length == 0, let initial = word.first {
                        wordsByInitial[initial, default: [:]][word, default: 0] += 1
                    }
                }
            }
        }
        guard !counted.isEmpty else { return }
        raiseSpread(of: counted, at: now)
        // The empty context is the first key ever learned, so it would be the first to go, and it
        // is the one that holds every word the writer uses: without it the strip stops completing
        // their words until the next sentence. Longer contexts are what there are too many of.
        while counts.count > Self.maximumContexts,
              let index = insertionOrder.firstIndex(where: { !$0.isEmpty && $0 != Self.spreadKey }) {
            let oldest = insertionOrder.remove(at: index)
            counts.removeValue(forKey: oldest)
            totals.removeValue(forKey: oldest)
        }
        scheduleSave()
    }

    /// Adds one to the spread of each word not yet counted in the sitting that `now` falls in.
    private func raiseSpread(of words: Set<String>, at now: Date) {
        let isSameSitting = sittingStart.map { now >= $0 && now.timeIntervalSince($0) < Self.sitting } ?? false
        if !isSameSitting {
            sittingStart = now
            wordsCountedThisSitting = []
        }
        for word in words where wordsCountedThisSitting.insert(word).inserted {
            counts[Self.spreadKey, default: [:]][word, default: 0] += 1
        }
    }

    /// The key a word of the sentence is counted under, or nil when it is not counted: a number, a
    /// name that is not a term of the writer's, or a word nothing vouches for.
    private static func countedWord(_ token: String, written: String, vouching: Vouching) -> String? {
        if token == NextWordModel.name {
            let lowered = written.lowercased()
            return vouching.isOwnName(lowered) ? lowered : nil
        }
        guard !token.hasPrefix("<"), vouching.isWord(token) else { return nil }
        return token
    }

    func reset() {
        sittingStart = nil
        wordsCountedThisSitting = []
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
