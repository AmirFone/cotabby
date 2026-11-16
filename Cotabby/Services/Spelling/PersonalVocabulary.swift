import Foundation
import Logging

/// File overview:
/// The words this writer uses that the bundled dictionary does not have: their surname, a friend's
/// name, the product they work on. The spelling engine can only correct toward words it knows, so a
/// slip in such a word (`Lindqvsit` for Lindqvist) used to be "corrected" to the nearest dictionary word
/// (`Lundqvist`). Words learned here become candidates, in the casing the writer uses.
///
/// A word is learned only from a finished sentence, only when the dictionary lacks it and the system
/// checker accepts it (or the writer explicitly kept it), and it is trusted as a correction target
/// only after it has been written twice, so a one-off slip the checker happens to accept cannot
/// teach itself. Stored locally next to the learned phrases and cleared with them.
@MainActor
final class PersonalVocabulary {
    struct Match: Equatable {
        /// The word in the casing the writer uses most.
        let word: String
        let distance: Int
        let uses: Int
    }

    static let maximumWords = 2_000
    /// Written at least this many times before it can replace anything.
    static let minimumUses = 2
    static let minimumLength = 3
    static let maximumDistance = 2

    private let fileURL: URL?
    /// The word exactly as typed -> how many finished sentences used it.
    private var uses: [String: Int]
    /// Lowercased word -> its commonest casing and total uses, rebuilt after each change.
    private var byLowercase: [String: Entry] = [:]

    private struct Entry {
        var word: String
        var uses: Int
        /// Uses of `word` in exactly that casing, to pick the commonest one.
        var usesInThisCasing: Int
    }

    init(fileURL: URL?) {
        self.fileURL = fileURL
        uses = fileURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        rebuildIndex()
    }

    nonisolated static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Cotabby", isDirectory: true)
            .appendingPathComponent("personal_words.json")
    }

    /// Counts the sentence's words that are the writer's own vocabulary.
    /// - Parameters:
    ///   - isDictionaryWord: the bundled dictionary has the (lowercased) word, so it needs no learning.
    ///   - isAcceptedSpelling: the system checker accepts the word as typed, or the writer kept it.
    func learn(sentence: String, isDictionaryWord: (String) -> Bool, isAcceptedSpelling: (String) -> Bool) {
        var changed = false
        for token in WordToken.tokens(in: sentence) {
            let word = token.text
            guard word.count >= Self.minimumLength, !word.contains("'"), !word.contains("’"),
                  !isDictionaryWord(word.lowercased()), isAcceptedSpelling(word) else { continue }
            uses[word, default: 0] += 1
            changed = true
        }
        guard changed else { return }
        if uses.count > Self.maximumWords {
            // The least-used words go first; ties drop arbitrarily, which is fine for one-off words.
            let keep = uses.sorted { $0.value > $1.value }.prefix(Self.maximumWords)
            uses = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        rebuildIndex()
        save()
    }

    /// The writer's words within two edits of `typo` (case ignored), closest first.
    func matches(for typo: String) -> [Match] {
        let typed = Array(typo.lowercased())
        guard typed.count >= Self.minimumLength else { return [] }
        var found: [Match] = []
        for (lowered, entry) in byLowercase where entry.uses >= Self.minimumUses && lowered.count >= Self.minimumLength {
            let letters = Array(lowered)
            guard abs(letters.count - typed.count) <= Self.maximumDistance, letters != typed else { continue }
            let distance = SymSpell.damerauOSA(typed, letters, maxDistance: Self.maximumDistance)
            if distance > 0 {
                found.append(Match(word: entry.word, distance: distance, uses: entry.uses))
            }
        }
        return found.sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.uses > $1.uses }
    }

    /// The casing the writer uses for a word they have written often enough, or nil.
    func preferredCasing(of word: String) -> String? {
        guard let entry = byLowercase[word.lowercased()], entry.uses >= Self.minimumUses else { return nil }
        return entry.word
    }

    func reset() {
        uses = [:]
        byLowercase = [:]
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func rebuildIndex() {
        var index: [String: Entry] = [:]
        for (word, count) in uses {
            var entry = index[word.lowercased()] ?? Entry(word: word, uses: 0, usesInThisCasing: 0)
            entry.uses += count
            if count > entry.usesInThisCasing {
                entry.word = word
                entry.usesInThisCasing = count
            }
            index[word.lowercased()] = entry
        }
        byLowercase = index
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(uses) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            CotabbyLogger.app.error("Could not save personal words: \(error.localizedDescription)")
        }
    }
}
