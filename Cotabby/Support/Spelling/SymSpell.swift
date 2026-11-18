import Foundation

/// File overview:
/// Self-contained Swift implementation of SymSpell (Wolf Garbe's Symmetric Delete spelling
/// correction, https://github.com/wolfgarbe/symspell). Given a frequency dictionary of correct
/// words it returns the most frequent word within a small edit distance of a query in roughly
/// constant time, by precomputing a "delete index": every dictionary word is reduced by up to
/// `maxDictionaryEditDistance` single-character deletions, and a query is matched by reducing it the
/// same way and intersecting. Two strings are within edit distance k iff one of their delete-sets
/// intersects, which is what makes lookup independent of dictionary size.
///
/// We use this as the *correction* source for inline autocorrect. Detection (is-this-a-typo) stays
/// with `NSSpellChecker` so proper nouns and the user's learned words are respected and a fixed
/// dictionary never mis-"corrects" a real name.
///
/// Ported in-repo (rather than added as a dependency) so it is reviewable and unit-tested. The
/// delete index is memory-heavy but small next to the app's llama runtime, and is built once off
/// the main thread (see `SymSpellCorrector`).
///
/// Attribution — this is a Swift port of SymSpell, used under the MIT License:
///
///   Copyright (c) 2018 Wolf Garbe (https://github.com/wolfgarbe/SymSpell)
///
///   Permission is hereby granted, free of charge, to any person obtaining a copy of this software
///   and associated documentation files (the "Software"), to deal in the Software without
///   restriction, including without limitation the rights to use, copy, modify, merge, publish,
///   distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
///   Software is furnished to do so, subject to the following conditions: The above copyright
///   notice and this permission notice shall be included in all copies or substantial portions of
///   the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
///
/// The bundled `frequency_dictionary_en_82_765.txt` also ships with SymSpell and is derived from
/// Google Books Ngram data (CC BY 3.0) and SCOWL.

struct SymSpellSuggestion: Equatable {
    let term: String
    let distance: Int
    let count: Int64
}

/// A dictionary word whose *beginning* is close to a partially typed word. `recie` matches
/// `receive` at distance 1 (a transposition against `recei`) even though the whole words are far
/// apart, which is what the in-progress word candidate list needs.
struct SymSpellPrefixMatch: Equatable {
    let term: String
    /// Edit distance between the partial word and the closest prefix of `term`, in half-edits: a
    /// swap of two neighboring letters costs 1 and every other edit costs 2. Swaps are the signature
    /// dyslexic slip (`recie` for `recei…`), so they should outrank a dropped or wrong letter.
    let halfEditDistance: Int
    let count: Int64
}

/// A common word that sounds like the query (same `PhoneticKey`), with spelling similarity in [0, 1].
struct SymSpellPhoneticMatch: Equatable {
    let term: String
    let similarity: Double
    let count: Int64
    /// Same `PhoneticKey.vowelKey`: sounds the same vowels included, not just the same consonants.
    var soundsIdentical = false
    /// The sound keys are one slip apart rather than equal (`apsolootly` ~ absolutely): a weaker
    /// match, found only for finished words.
    var isApproximate = false
}

/// A way to read a non-word as two common words typed without the space (`nextdoor` → next door).
struct SymSpellSplit: Equatable {
    let first: String
    let second: String
    /// Corpus count of the rarer half.
    let minimumCount: Int64
    /// How often `second` follows `first` (bigram list); filled in by `TypoGateInputs`.
    var pairCount: Int64 = 0
}

/// `nonisolated` so the index can be built and queried off the main actor (the project defaults to
/// `@MainActor` isolation). It is not `Sendable` on its own: `SymSpellCorrector` owns the only
/// instance and serializes the one-time build against later reads with a lock.
nonisolated final class SymSpell {
    let maxDictionaryEditDistance: Int
    let prefixLength: Int

    /// word -> frequency count. Doubles as the dictionary-membership set.
    private var words: [String: Int64] = [:]
    /// index -> word, so the delete buckets can store compact `Int32` indices rather than strings.
    private var wordsList: [String] = []
    /// index -> count, beside `wordsList`, so a scan over a bucket reads a count without hashing the
    /// word.
    private var countsList: [Int64] = []
    /// The letters of every ASCII word laid end to end, with where each word starts and how long it
    /// is (0 for a word with any non-ASCII letter, which is compared as characters instead).
    ///
    /// The scans below run on every keystroke over a bucket of several thousand words. Comparing
    /// Swift `Character`s there meant building an array per word and walking grapheme clusters;
    /// for ASCII, which is every English word, a letter is a byte and the comparison is a few
    /// machine instructions on memory that is already in the cache.
    private var asciiLetters: [UInt8] = []
    private var asciiStart: [Int32] = []
    private var asciiLength: [UInt8] = []
    /// FNV-1a hash of a delete-variant -> the dictionary word indices that produce it. Hash
    /// collisions are harmless: every candidate is verified with a real bounded edit-distance check,
    /// so a colliding entry is simply discarded.
    private var deletes: [Int: [Int32]] = [:]
    private var maxDictionaryWordLength = 0
    /// First character -> word indices, in load order. Prefix matching scans one or two of these
    /// buckets instead of the whole dictionary; dyslexic misspellings almost always keep the first
    /// letter or swap the first two.
    private var initialBuckets: [Character: [Int32]] = [:]
    /// Frequency of roughly the 30,000th most common word, fixed after `loadDictionary`. Prefixes of
    /// words at least this common count as "a real word in progress" rather than a typo.
    private(set) var commonWordCountFloor: Int64 = 0
    /// Phonetic key -> common word indices (see `PhoneticKey`). Only the common vocabulary is indexed:
    /// a sound-alike guess should land on a word people actually write, not a rare near-miss.
    private var phoneticBuckets: [String: [Int32]] = [:]
    /// `PhoneticKey.vowelKey` -> common word indices; the narrow "sounds exactly like" index.
    private var vowelKeyBuckets: [String: [Int32]] = [:]
    /// A phonetic key, or that key with one sound removed -> common word indices. Two keys that share
    /// an entry are at most one substituted, swapped, added, or dropped sound apart, which is how a
    /// sounded-out spelling with one wrong sound (`comfterbul`) still reaches its word.
    private var nearPhoneticBuckets: [String: [Int32]] = [:]
    /// Short keys have huge neighborhoods (most three-sound words are one sound from each other).
    static let minimumApproximateKeyLength = 4
    /// An approximate sound match must also look this much like the typed word.
    static let minimumApproximateSimilarity = 0.72

    static let commonVocabularySize = 30_000

    init(maxDictionaryEditDistance: Int = 2, prefixLength: Int = 7) {
        self.maxDictionaryEditDistance = maxDictionaryEditDistance
        self.prefixLength = prefixLength
    }

    var wordCount: Int { wordsList.count }

    // MARK: - Dictionary loading

    /// Parses `word<space-or-tab>count` lines (the SymSpell frequency-dictionary format). Malformed
    /// lines are skipped. Call once, off the main thread — building the index is the expensive part.
    ///
    /// The two slow parts, the delete-variants of every word and the sound keys of the common ones,
    /// are worked out on all cores and then put into the buckets on this thread in word order, so
    /// the index is the same one a single thread would build, in about a third of the time. Until
    /// it is built the app has no spelling help, which is why the time matters at launch.
    func loadDictionary(contents: String) {
        var added: [Int32] = []
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, let count = Int64(parts[1]) else { continue }
            if let index = registerWord(key: String(parts[0]), count: count) { added.append(index) }
        }
        insertDeletes(for: added)
        let sortedCounts = words.values.sorted(by: >)
        if !sortedCounts.isEmpty {
            commonWordCountFloor = sortedCounts[min(Self.commonVocabularySize, sortedCounts.count) - 1]
        }
        buildPhoneticIndex()
    }

    private func buildPhoneticIndex() {
        phoneticBuckets = [:]
        vowelKeyBuckets = [:]
        nearPhoneticBuckets = [:]
        struct Sounds {
            var keys: [(key: String, near: [String])] = []
            var vowelKey = ""
        }
        let common = wordsList.indices.filter { countsList[$0] >= commonWordCountFloor }
        let sounds: [Sounds] = Self.inParallel(count: common.count) { position in
            let word = self.wordsList[common[position]]
            var result = Sounds()
            for key in PhoneticKey.keys(for: word) {
                let near = key.count >= Self.minimumApproximateKeyLength ? Array(Self.keyWithEachSoundRemoved(key)) : []
                result.keys.append((key, near))
            }
            result.vowelKey = PhoneticKey.vowelKey(for: word)
            return result
        }
        for (position, wordIndex) in common.enumerated() {
            let index = Int32(wordIndex)
            for entry in sounds[position].keys {
                phoneticBuckets[entry.key, default: []].append(index)
                for variant in entry.near {
                    nearPhoneticBuckets[variant, default: []].append(index)
                }
            }
            if !sounds[position].vowelKey.isEmpty {
                vowelKeyBuckets[sounds[position].vowelKey, default: []].append(index)
            }
        }
    }

    /// `work(0)` to `work(count - 1)`, run on all cores, results in order. `work` must only read
    /// shared state. A handful of items is done on the calling thread: starting threads would cost
    /// more than the work.
    private static func inParallel<Result>(count: Int, _ work: (Int) -> Result) -> [Result] {
        guard count >= 256 else { return (0..<count).map(work) }
        let chunk = 256
        let chunks = (count + chunk - 1) / chunk
        return withoutActuallyEscaping(work) { work in
            [Result](unsafeUninitializedCapacity: count) { buffer, initialized in
                // Each iteration fills its own stretch of the buffer, so no two threads touch the
                // same element; the buffer's address is passed as a plain number because a pointer
                // is not something Swift lets a concurrent closure capture.
                let base = UInt(bitPattern: buffer.baseAddress)
                DispatchQueue.concurrentPerform(iterations: chunks) { chunkIndex in
                    guard let pointer = UnsafeMutablePointer<Result>(bitPattern: base) else { return }
                    for position in (chunkIndex * chunk)..<min(count, (chunkIndex + 1) * chunk) {
                        (pointer + position).initialize(to: work(position))
                    }
                }
                initialized = count
            }
        }
    }

    /// `key` and every version of it with one sound removed.
    private static func keyWithEachSoundRemoved(_ key: String) -> Set<String> {
        let sounds = Array(key)
        var variants: Set<String> = [key]
        for index in sounds.indices {
            var shorter = sounds
            shorter.remove(at: index)
            variants.insert(String(shorter))
        }
        return variants
    }

    /// Common words whose sound is one slip from `input`'s and whose spelling is still close, most
    /// similar first. Excludes exact sound matches, which `phoneticMatches` already returns.
    func approximatePhoneticMatches(for input: String, limit: Int = 6) -> [SymSpellPhoneticMatch] {
        let lowered = input.lowercased()
        let letters = Array(lowered)
        let keys = PhoneticKey.keys(for: lowered).filter { $0.count >= Self.minimumApproximateKeyLength }
        var seen = Set<Int32>()
        for key in keys {
            for index in phoneticBuckets[key] ?? [] { seen.insert(index) }
        }
        var matches: [SymSpellPhoneticMatch] = []
        for key in keys {
            for variant in Self.keyWithEachSoundRemoved(key) {
                for index in nearPhoneticBuckets[variant] ?? [] where seen.insert(index).inserted {
                    let term = wordsList[Int(index)]
                    guard term != lowered, abs(term.count - letters.count) <= 3 else { continue }
                    let similarity = Self.jaroWinkler(letters, Array(term))
                    guard similarity >= Self.minimumApproximateSimilarity else { continue }
                    matches.append(SymSpellPhoneticMatch(term: term, similarity: similarity, count: words[term] ?? 0, isApproximate: true))
                }
            }
        }
        return Array(matches.sorted { $0.similarity > $1.similarity }.prefix(limit))
    }

    /// Common words that sound like `input`, most similar spelling first. `similarity` is Jaro-Winkler
    /// on the spellings, which separates `enough` from `inch` inside the same sound bucket.
    func phoneticMatches(for input: String, limit: Int = 8) -> [SymSpellPhoneticMatch] {
        let lowered = input.lowercased()
        var seen = Set<Int32>()
        var matches: [SymSpellPhoneticMatch] = []
        for key in PhoneticKey.keys(for: lowered) {
            for index in phoneticBuckets[key] ?? [] where seen.insert(index).inserted {
                let term = wordsList[Int(index)]
                guard term != lowered else { continue }
                matches.append(SymSpellPhoneticMatch(
                    term: term,
                    similarity: Self.jaroWinkler(Array(lowered), Array(term)),
                    count: words[term] ?? 0
                ))
            }
        }
        let vowelKey = PhoneticKey.vowelKey(for: lowered)
        let identical = Set((vowelKeyBuckets[vowelKey] ?? []).map { wordsList[Int($0)] })
        for index in vowelKeyBuckets[vowelKey] ?? [] where seen.insert(index).inserted {
            let term = wordsList[Int(index)]
            guard term != lowered else { continue }
            matches.append(SymSpellPhoneticMatch(
                term: term,
                similarity: Self.jaroWinkler(Array(lowered), Array(term)),
                count: words[term] ?? 0
            ))
        }
        for position in matches.indices where identical.contains(matches[position].term) {
            matches[position].soundsIdentical = true
        }
        // Identical-sounding words first, so the cut never drops the strongest sound evidence.
        return Array(matches.sorted {
            $0.soundsIdentical != $1.soundsIdentical ? $0.soundsIdentical : $0.similarity > $1.similarity
        }.prefix(limit))
    }

    static func jaroWinkler(_ lhs: [Character], _ rhs: [Character]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let window = max(0, max(lhs.count, rhs.count) / 2 - 1)
        var lhsMatched = [Bool](repeating: false, count: lhs.count)
        var rhsMatched = [Bool](repeating: false, count: rhs.count)
        var matches = 0
        for index in lhs.indices {
            let low = max(0, index - window), high = min(rhs.count - 1, index + window)
            guard low <= high else { continue }
            for other in low...high where !rhsMatched[other] && lhs[index] == rhs[other] {
                lhsMatched[index] = true
                rhsMatched[other] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }
        var transpositions = 0, other = 0
        for index in lhs.indices where lhsMatched[index] {
            while !rhsMatched[other] { other += 1 }
            if lhs[index] != rhs[other] { transpositions += 1 }
            other += 1
        }
        let matchCount = Double(matches)
        let jaro = (matchCount / Double(lhs.count) + matchCount / Double(rhs.count)
            + (matchCount - Double(transpositions / 2)) / matchCount) / 3
        var prefix = 0
        while prefix < min(4, lhs.count, rhs.count), lhs[prefix] == rhs[prefix] { prefix += 1 }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }

    /// A word seen again keeps the larger count, so a correction list appended after the main
    /// dictionary (`frequency_overrides_en.txt`) can raise words the corpus undercounts.
    func createDictionaryEntry(key: String, count: Int64) {
        guard let index = registerWord(key: key, count: count) else { return }
        insertDeletes(for: [index])
    }

    /// Adds `key` to the word list and the letter buckets and returns its index; nil when the word
    /// was already there (its count is raised if this one is larger) or the count is not positive.
    /// The delete-variants are added separately (`insertDeletes`), so a whole dictionary's can be
    /// worked out together.
    private func registerWord(key: String, count: Int64) -> Int32? {
        guard count > 0 else { return nil }
        if let existing = words[key] {
            words[key] = max(existing, count)
            // The slot beside the word list follows; a repeated word is rare (the override lists).
            if count > existing, let index = wordsList.firstIndex(of: key) { countsList[index] = count }
            return nil
        }
        words[key] = count
        let index = Int32(wordsList.count)
        wordsList.append(key)
        countsList.append(count)
        let bytes = key.utf8
        asciiStart.append(Int32(asciiLetters.count))
        if bytes.count <= Int(UInt8.max), bytes.allSatisfy({ $0 < 0x80 }) {
            asciiLetters.append(contentsOf: bytes)
            asciiLength.append(UInt8(bytes.count))
        } else {
            asciiLength.append(0)
        }
        if let first = key.first {
            initialBuckets[first, default: []].append(index)
        }
        maxDictionaryWordLength = max(maxDictionaryWordLength, key.count)
        return index
    }

    /// Files the words at `indices` under each of their delete-variants, in the order given.
    private func insertDeletes(for indices: [Int32]) {
        let variants: [[Int]] = Self.inParallel(count: indices.count) { position in
            self.editsPrefix(Array(self.wordsList[Int(indices[position])])).map { Self.hash($0) }
        }
        for (position, index) in indices.enumerated() {
            for hash in variants[position] {
                deletes[hash, default: []].append(index)
            }
        }
    }

    /// All delete-variants of a word's prefix (capped at `prefixLength`) down to
    /// `maxDictionaryEditDistance`, plus the empty string for words short enough to delete entirely.
    private func editsPrefix(_ key: [Character]) -> Set<String> {
        var result = Set<String>()
        if key.count <= maxDictionaryEditDistance {
            result.insert("")
        }
        let prefix = key.count > prefixLength ? Array(key.prefix(prefixLength)) : key
        result.insert(String(prefix))
        edits(prefix, editDistance: 0, into: &result)
        return result
    }

    private func edits(_ word: [Character], editDistance: Int, into result: inout Set<String>) {
        let nextDistance = editDistance + 1
        guard word.count > 1 else { return }
        for index in word.indices {
            var deleted = word
            deleted.remove(at: index)
            if result.insert(String(deleted)).inserted, nextDistance < maxDictionaryEditDistance {
                edits(deleted, editDistance: nextDistance, into: &result)
            }
        }
    }

    // MARK: - Lookup

    /// Returns dictionary words within `maxEditDistance` of `input`, sorted best-first (lowest edit
    /// distance, then highest frequency). For autocorrect we take the first element. An exact
    /// dictionary match short-circuits to distance 0.
    func lookup(_ input: String, maxEditDistance: Int? = nil) -> [SymSpellSuggestion] {
        let maxED = min(maxEditDistance ?? maxDictionaryEditDistance, maxDictionaryEditDistance)
        let inputChars = Array(input)
        let inputLen = inputChars.count

        // Too long to be within maxED of any dictionary word.
        if inputLen - maxED > maxDictionaryWordLength { return [] }

        if let count = words[input] {
            return [SymSpellSuggestion(term: input, distance: 0, count: count)]
        }
        if maxED == 0 { return [] }
        return search(input, inputChars: inputChars, maxED: maxED)
    }

    /// Dictionary words within `maxEditDistance` of `input` other than `input` itself, best first.
    /// Unlike `lookup`, a word that is in the dictionary still gets its neighbors, which is what the
    /// wrong-word check needs: `form` is a word, and so is `from`, one swap away.
    func neighbors(of input: String, maxEditDistance: Int) -> [SymSpellSuggestion] {
        let maxED = min(maxEditDistance, maxDictionaryEditDistance)
        let inputChars = Array(input)
        guard maxED > 0, inputChars.count - maxED <= maxDictionaryWordLength else { return [] }
        return search(input, inputChars: inputChars, maxED: maxED)
    }

    private func search(_ input: String, inputChars: [Character], maxED: Int) -> [SymSpellSuggestion] {
        let inputLen = inputChars.count
        var suggestions: [SymSpellSuggestion] = []
        var consideredSuggestions = Set<String>([input])
        var consideredDeletes = Set<String>()

        let query = Query(input: input, chars: inputChars, maxED: maxED)
        let inputPrefixLen = min(inputLen, prefixLength)
        var candidates: [[Character]] = [Array(inputChars.prefix(inputPrefixLen))]
        var candidatePointer = 0

        while candidatePointer < candidates.count {
            let candidate = candidates[candidatePointer]
            candidatePointer += 1

            matchDictionaryWords(
                forCandidate: candidate,
                query: query,
                considered: &consideredSuggestions,
                into: &suggestions
            )

            // Enqueue the candidate's own deletes (the input side of the symmetric search), bounded
            // by the prefix window and the max edit distance.
            if inputPrefixLen - candidate.count < maxED, candidate.count <= prefixLength {
                enqueueDeletes(of: candidate, considered: &consideredDeletes, into: &candidates)
            }
        }

        if suggestions.count > 1 {
            suggestions.sort { lhs, rhs in
                lhs.distance != rhs.distance ? lhs.distance < rhs.distance : lhs.count > rhs.count
            }
        }
        return suggestions
    }

    /// The immutable per-lookup query, bundled so the helpers stay within the parameter-count rule.
    private struct Query {
        let input: String
        let chars: [Character]
        let maxED: Int
    }

    /// Verifies every dictionary word in `candidate`'s delete bucket with a real bounded edit-distance
    /// check and appends those within `query.maxED` to `suggestions`. Extracted from `lookup` to keep
    /// that function within the project's cyclomatic-complexity budget.
    private func matchDictionaryWords(
        forCandidate candidate: [Character],
        query: Query,
        considered: inout Set<String>,
        into suggestions: inout [SymSpellSuggestion]
    ) {
        guard let dictIndices = deletes[Self.hash(String(candidate))] else { return }
        for index in dictIndices {
            let suggestion = wordsList[Int(index)]
            if suggestion == query.input { continue }
            let suggestionChars = Array(suggestion)
            // Cheap length prune before the O(n*m) distance computation.
            if abs(suggestionChars.count - query.chars.count) > query.maxED { continue }
            if !considered.insert(suggestion).inserted { continue }

            let distance = Self.damerauOSA(query.chars, suggestionChars, maxDistance: query.maxED)
            if distance >= 0 {
                suggestions.append(
                    SymSpellSuggestion(term: suggestion, distance: distance, count: words[suggestion] ?? 0)
                )
            }
        }
    }

    private func enqueueDeletes(
        of candidate: [Character],
        considered: inout Set<String>,
        into candidates: inout [[Character]]
    ) {
        for index in candidate.indices {
            var deleted = candidate
            deleted.remove(at: index)
            if considered.insert(String(deleted)).inserted {
                candidates.append(deleted)
            }
        }
    }

    func contains(_ word: String) -> Bool {
        words[word] != nil
    }

    /// Every way to cut `input` into two common words of at least two letters each.
    func splits(of input: String) -> [SymSpellSplit] {
        let letters = Array(input)
        guard letters.count >= 4 else { return [] }
        var found: [SymSpellSplit] = []
        for cut in 2...(letters.count - 2) {
            guard let first = words[String(letters[..<cut])], first >= commonWordCountFloor,
                  let second = words[String(letters[cut...])], second >= commonWordCountFloor else { continue }
            found.append(SymSpellSplit(
                first: String(letters[..<cut]),
                second: String(letters[cut...]),
                minimumCount: min(first, second)
            ))
        }
        return found
    }

    /// How often `word` (lowercased) occurs in the corpus; 0 when it is not a dictionary word.
    func count(of word: String) -> Int64 {
        words[word] ?? 0
    }

    /// Common words that sound exactly like `word`, vowels included (`mussel` ~ muscle).
    func soundsIdentical(to word: String) -> [SymSpellSuggestion] {
        let key = PhoneticKey.vowelKey(for: word)
        guard !key.isEmpty else { return [] }
        return (vowelKeyBuckets[key] ?? []).compactMap { index in
            let term = wordsList[Int(index)]
            return term == word ? nil : SymSpellSuggestion(term: term, distance: -1, count: words[term] ?? 0)
        }
    }

    /// Dictionary words that start with `prefix` (lowercased), most frequent first. The bundled
    /// dictionary is sorted by frequency, so a bucket in load order is already ranked.
    func completions(of prefix: String, limit: Int) -> [String] {
        guard let first = prefix.first, let bucket = initialBuckets[first] else { return [] }
        let prefixBytes = Self.asciiBytes(of: prefix)
        var result: [String] = []
        for index in bucket {
            let position = Int(index)
            if let prefixBytes, asciiLength[position] > 0 {
                // A longer word that starts with the same letters; equal length would be the prefix itself.
                guard Int(asciiLength[position]) > prefixBytes.count, startsWith(prefixBytes, wordAt: position) else { continue }
            } else {
                let term = wordsList[position]
                guard term != prefix, term.hasPrefix(prefix) else { continue }
            }
            result.append(wordsList[position])
            if result.count == limit { break }
        }
        return result
    }

    /// The bytes of `text` when it is all ASCII, else nil (and the character comparison is used).
    private static func asciiBytes(of text: String) -> [UInt8]? {
        let bytes = Array(text.utf8)
        return bytes.allSatisfy { $0 < 0x80 } ? bytes : nil
    }

    /// True when the ASCII word at `position` begins with `prefix`.
    private func startsWith(_ prefix: [UInt8], wordAt position: Int) -> Bool {
        guard Int(asciiLength[position]) >= prefix.count else { return false }
        let start = Int(asciiStart[position])
        for offset in 0..<prefix.count where asciiLetters[start + offset] != prefix[offset] { return false }
        return true
    }

    // MARK: - Prefix matching

    /// True when some common dictionary word starts with `partial`, i.e. the user may simply not have
    /// finished typing a correctly spelled word yet.
    func isCommonWordPrefix(_ partial: String) -> Bool {
        let lowered = partial.lowercased()
        guard let first = lowered.first, let bucket = initialBuckets[first] else { return false }
        let prefixBytes = Self.asciiBytes(of: lowered)
        for index in bucket {
            let position = Int(index)
            guard countsList[position] >= commonWordCountFloor else { continue }
            if let prefixBytes, asciiLength[position] > 0 {
                if startsWith(prefixBytes, wordAt: position) { return true }
            } else if wordsList[position].hasPrefix(lowered) {
                return true
            }
        }
        return false
    }

    /// Words whose opening letters are within `maxEditDistance` of `partial`, best first (lowest
    /// distance, then most frequent). Scans the bucket for the partial's first letter plus the bucket
    /// for its second letter, so a swapped opening pair (`hte`) still finds `the`.
    ///
    /// - Parameter comparingCharacters: true takes the general character-by-character path for
    ///   every word. It is what non-ASCII words always get; tests pass it to check that the byte
    ///   path, which every English word takes, gives exactly the same answer.
    func prefixMatches(
        for partial: String, maxEditDistance: Int, limit: Int, comparingCharacters: Bool = false
    ) -> [SymSpellPrefixMatch] {
        let lowered = partial.lowercased()
        let query = Array(lowered)
        guard query.count >= 2, maxEditDistance >= 0, limit > 0 else { return [] }
        let queryBytes = comparingCharacters ? nil : Self.asciiBytes(of: lowered)
        // One set of rows for the whole scan, instead of three arrays per word.
        var rows = PrefixDistanceRows(columns: query.count + maxEditDistance + 1)

        var matches: [SymSpellPrefixMatch] = []
        var bucketKeys = [query[0]]
        if query[1] != query[0] { bucketKeys.append(query[1]) }
        for (bucketPosition, key) in bucketKeys.enumerated() {
            for index in initialBuckets[key] ?? [] {
                let position = Int(index)
                let distance: Int
                if let queryBytes, asciiLength[position] > 0 {
                    let start = Int(asciiStart[position])
                    let length = min(Int(asciiLength[position]), queryBytes.count + maxEditDistance)
                    if bucketPosition == 1, !(length > 1 && asciiLetters[start + 1] == queryBytes[0]) { continue }
                    if length + maxEditDistance < queryBytes.count { continue }
                    distance = asciiLetters.withUnsafeBufferPointer { letters in
                        Self.bestPrefixHalfEditDistance(
                            queryBytes, UnsafeBufferPointer(rebasing: letters[start..<(start + length)]),
                            maxHalfEdits: maxEditDistance * 2, rows: &rows
                        )
                    }
                } else {
                    let target = Array(wordsList[position].prefix(query.count + maxEditDistance))
                    if bucketPosition == 1, !(target.count > 1 && target[1] == query[0]) { continue }
                    if target.count + maxEditDistance < query.count { continue }
                    distance = Self.bestPrefixHalfEditDistance(query, target, maxHalfEdits: maxEditDistance * 2)
                }
                if distance >= 0 {
                    matches.append(SymSpellPrefixMatch(
                        term: wordsList[position], halfEditDistance: distance, count: countsList[position]
                    ))
                }
            }
        }
        matches.sort { lhs, rhs in
            lhs.halfEditDistance != rhs.halfEditDistance
                ? lhs.halfEditDistance < rhs.halfEditDistance
                : lhs.count > rhs.count
        }
        return Array(matches.prefix(limit))
    }

    /// The smallest weighted OSA distance (see `SymSpellPrefixMatch.halfEditDistance`) between
    /// `query` and any prefix of `target` whose length is within `maxHalfEdits / 2` letters of the
    /// query's. One DP pass yields every prefix distance in its last row.
    static func bestPrefixHalfEditDistance(_ query: [Character], _ target: [Character], maxHalfEdits: Int) -> Int {
        let maxDistance = maxHalfEdits
        let rows = query.count
        let cols = target.count
        guard rows > 0, cols > 0 else { return -1 }

        var prevPrev = [Int](repeating: 0, count: cols + 1)
        var prev = (0...cols).map { $0 * 2 }
        var curr = [Int](repeating: 0, count: cols + 1)
        for row in 1...rows {
            curr[0] = row * 2
            var rowMin = curr[0]
            for col in 1...cols {
                let substitution = query[row - 1] == target[col - 1] ? 0 : 2
                var value = min(prev[col] + 2, curr[col - 1] + 2, prev[col - 1] + substitution)
                if row > 1, col > 1, query[row - 1] != target[col - 1],
                   query[row - 1] == target[col - 2], query[row - 2] == target[col - 1] {
                    value = min(value, prevPrev[col - 2] + 1)
                }
                curr[col] = value
                rowMin = min(rowMin, value)
            }
            if rowMin > maxDistance { return -1 }
            swap(&prevPrev, &prev)
            swap(&prev, &curr)
        }

        let letterSlack = maxHalfEdits / 2
        let lower = max(1, rows - letterSlack)
        let upper = min(cols, rows + letterSlack)
        guard lower <= upper else { return -1 }
        let best = prev[lower...upper].min() ?? Int.max
        return best <= maxDistance ? best : -1
    }

    /// The three rows of the distance table, kept between words of one scan.
    struct PrefixDistanceRows {
        var beforePrevious: [Int]
        var previous: [Int]
        var current: [Int]

        init(columns: Int) {
            beforePrevious = [Int](repeating: 0, count: columns)
            previous = [Int](repeating: 0, count: columns)
            current = [Int](repeating: 0, count: columns)
        }
    }

    /// `bestPrefixHalfEditDistance` over bytes, with the rows handed in. Same table, same result.
    static func bestPrefixHalfEditDistance(
        _ query: [UInt8], _ target: UnsafeBufferPointer<UInt8>, maxHalfEdits: Int, rows: inout PrefixDistanceRows
    ) -> Int {
        let rowCount = query.count
        let cols = target.count
        guard rowCount > 0, cols > 0 else { return -1 }
        for col in 0...cols { rows.previous[col] = col * 2 }
        for row in 1...rowCount {
            rows.current[0] = row * 2
            var rowMin = rows.current[0]
            let letter = query[row - 1]
            for col in 1...cols {
                let other = target[col - 1]
                var value = min(rows.previous[col] + 2, rows.current[col - 1] + 2, rows.previous[col - 1] + (letter == other ? 0 : 2))
                if row > 1, col > 1, letter != other, letter == target[col - 2], query[row - 2] == other {
                    value = min(value, rows.beforePrevious[col - 2] + 1)
                }
                rows.current[col] = value
                rowMin = min(rowMin, value)
            }
            if rowMin > maxHalfEdits { return -1 }
            swap(&rows.beforePrevious, &rows.previous)
            swap(&rows.previous, &rows.current)
        }
        let letterSlack = maxHalfEdits / 2
        let lower = max(1, rowCount - letterSlack)
        let upper = min(cols, rowCount + letterSlack)
        guard lower <= upper else { return -1 }
        var best = Int.max
        for col in lower...upper { best = min(best, rows.previous[col]) }
        return best <= maxHalfEdits ? best : -1
    }

    /// The single best correction for `input`, or nil when nothing is within `maxDictionaryEditDistance`.
    func bestSuggestion(for input: String) -> SymSpellSuggestion? {
        lookup(input).first
    }

    // MARK: - Edit distance

    /// Bounded Damerau optimal-string-alignment distance (allows adjacent transposition). Returns -1
    /// when the distance exceeds `maxDistance`, so callers can prune cheaply.
    static func damerauOSA(_ source: [Character], _ target: [Character], maxDistance: Int) -> Int {
        let sourceLen = source.count
        let targetLen = target.count
        if sourceLen == 0 { return targetLen <= maxDistance ? targetLen : -1 }
        if targetLen == 0 { return sourceLen <= maxDistance ? sourceLen : -1 }
        if abs(sourceLen - targetLen) > maxDistance { return -1 }

        var prevPrev = [Int](repeating: 0, count: targetLen + 1)
        var prev = [Int](repeating: 0, count: targetLen + 1)
        var curr = [Int](repeating: 0, count: targetLen + 1)
        for col in 0...targetLen { prev[col] = col }

        for row in 1...sourceLen {
            curr[0] = row
            var rowMin = curr[0]
            for col in 1...targetLen {
                let cost = source[row - 1] == target[col - 1] ? 0 : 1
                var value = min(prev[col] + 1, curr[col - 1] + 1, prev[col - 1] + cost)
                if row > 1, col > 1, source[row - 1] == target[col - 2], source[row - 2] == target[col - 1] {
                    value = min(value, prevPrev[col - 2] + cost)
                }
                curr[col] = value
                rowMin = min(rowMin, value)
            }
            // Every remaining row can only add to the running minimum, so once the whole row exceeds
            // the budget the final distance cannot come back under it.
            if rowMin > maxDistance { return -1 }
            swap(&prevPrev, &prev)
            swap(&prev, &curr)
        }

        let distance = prev[targetLen]
        return distance <= maxDistance ? distance : -1
    }

    // MARK: - Hashing

    /// FNV-1a over UTF-8. Deterministic within a run; the index is rebuilt each launch so we do not
    /// depend on a stable hash across processes.
    static func hash(_ string: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(bitPattern: UInt(truncatingIfNeeded: hash))
    }
}
