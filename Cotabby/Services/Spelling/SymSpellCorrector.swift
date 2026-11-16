import Foundation
import Logging

/// File overview:
/// Owns Cotabby's language-specific `SymSpell` indexes and exposes synchronous correction lookups
/// for the prediction gate. Index construction is expensive, so dictionaries load on a background
/// queue only when needed. Until a requested language is ready, lookup returns nil and the caller
/// falls back to `NSSpellChecker`.
///
/// `nonisolated` + `@unchecked Sendable` (mirroring `LlamaRuntimeCore`/`FileLogWriter`) because the
/// builds run off the main actor while `bestCorrection` is called from it. The lock protects cache
/// publication, loading state, and LRU metadata. Each `SymSpell` becomes immutable before entering
/// the cache, so readers can safely query a retained instance after releasing the lock.
nonisolated final class SymSpellCorrector: @unchecked Sendable {
    private struct CacheEntry {
        let symSpell: SymSpell
        var lastAccessSequence: UInt64
    }

    typealias ResourceLoader = @Sendable (SpellingDictionaryLanguage) -> String?

    private let lock = NSLock()
    private let maxEditDistance: Int
    private let prefixLength: Int
    private let cacheLimit: Int
    private let resourceLoader: ResourceLoader
    /// All mutable fields below are guarded by `lock`.
    private var cache: [SpellingDictionaryLanguage: CacheEntry] = [:]
    private var loadingLanguages = Set<SpellingDictionaryLanguage>()
    private var accessSequence: UInt64 = 0

    /// `preloadLanguage` preserves the existing fast English startup by default. Production may
    /// pass another sole-enabled language, or nil when the user disabled every bundled dictionary.
    init(
        maxEditDistance: Int = 2,
        prefixLength: Int = 7,
        cacheLimit: Int = 2,
        preloadLanguage: SpellingDictionaryLanguage? = .english,
        resourceLoader: ResourceLoader? = nil
    ) {
        self.maxEditDistance = maxEditDistance
        self.prefixLength = prefixLength
        self.cacheLimit = max(1, cacheLimit)
        self.resourceLoader = resourceLoader ?? Self.bundledContents(for:)

        if let preloadLanguage {
            requestLoad(for: preloadLanguage)
        }
    }

    /// The best single-word correction for `word`, recased to match it, or nil when the index is not
    /// ready yet, the word is in the dictionary, or nothing is within edit distance. The lookup is
    /// case-insensitive: the dictionary is lowercase, and `TypoCaseTransfer` reapplies the typo's case.
    func bestCorrection(
        for word: String,
        language: SpellingDictionaryLanguage = .english
    ) -> String? {
        guard let symSpell = cachedIndexOrRequestLoad(for: language) else {
            return nil
        }

        let lowered = word.lowercased()
        guard let suggestion = symSpell.bestSuggestion(for: lowered),
              suggestion.distance > 0,
              suggestion.term.lowercased() != lowered else {
            return nil
        }
        return TypoCaseTransfer.applying(caseOf: word, to: suggestion.term)
    }

    /// Everything the correction ranker needs for one word, or nil while the index is still loading.
    /// `isWordInProgress` is only meaningful when the caret sits directly after the word.
    func candidates(
        for word: String,
        language: SpellingDictionaryLanguage = .english,
        includePrefixMatches: Bool
    ) -> SpellingCandidateSources? {
        guard let symSpell = cachedIndexOrRequestLoad(for: language) else {
            return nil
        }
        let lowered = word.lowercased()
        let fullWord = symSpell.lookup(lowered).filter { $0.distance > 0 }
        let phonetic = symSpell.phoneticMatches(for: lowered)
        guard includePrefixMatches else {
            // A finished word that sounds one slip away from a common word: only worth the extra
            // lookup once the word is complete, and only when it is not already an exact sound match.
            let known = Set(phonetic.map(\.term))
            let approximate = symSpell.approximatePhoneticMatches(for: lowered).filter { !known.contains($0.term) }
            return SpellingCandidateSources(
                fullWord: fullWord,
                prefix: [],
                isCommonWordPrefix: false,
                phonetic: phonetic + approximate,
                splits: symSpell.splits(of: lowered)
            )
        }
        let prefixDistance = lowered.count >= 5 ? 2 : 1
        return SpellingCandidateSources(
            fullWord: fullWord,
            prefix: symSpell.prefixMatches(for: lowered, maxEditDistance: prefixDistance, limit: 24),
            isCommonWordPrefix: symSpell.isCommonWordPrefix(lowered),
            phonetic: phonetic
        )
    }

    /// Dictionary words starting with `prefix`, most frequent first; empty while the index loads.
    func completions(of prefix: String, language: SpellingDictionaryLanguage = .english, limit: Int) -> [String] {
        cachedIndexOrRequestLoad(for: language)?.completions(of: prefix.lowercased(), limit: limit) ?? []
    }

    /// Words whose beginning is within one slip of `prefix` (two from five letters), most frequent
    /// first: completions that forgive a misspelling in what has been typed so far.
    func fuzzyCompletions(of prefix: String, language: SpellingDictionaryLanguage = .english, limit: Int) -> [String] {
        let lowered = prefix.lowercased()
        guard let symSpell = cachedIndexOrRequestLoad(for: language) else { return [] }
        return symSpell.prefixMatches(for: lowered, maxEditDistance: lowered.count >= 5 ? 2 : 1, limit: limit).map(\.term)
    }

    /// The dictionary lookups the wrong-word check needs, or nil while the index is still loading.
    func wrongWordSources(language: SpellingDictionaryLanguage = .english) -> WrongWordDetector.Sources? {
        guard let symSpell = cachedIndexOrRequestLoad(for: language) else { return nil }
        return WrongWordDetector.Sources(
            count: { symSpell.count(of: $0) },
            neighbors: { symSpell.neighbors(of: $0, maxEditDistance: 1) },
            soundAlikes: { symSpell.soundsIdentical(to: $0) },
            commonCountFloor: symSpell.commonWordCountFloor
        )
    }

    func isDictionaryWord(_ word: String, language: SpellingDictionaryLanguage = .english) -> Bool {
        cachedIndexOrRequestLoad(for: language)?.contains(word.lowercased()) ?? false
    }

    /// Test seam: synchronously publishes a small in-memory dictionary without touching the bundle.
    func loadForTesting(
        contents: String,
        language: SpellingDictionaryLanguage = .english
    ) {
        let symSpell = makeEmptyIndex()
        symSpell.loadDictionary(contents: contents)

        lock.lock()
        publish(symSpell, for: language)
        loadingLanguages.remove(language)
        lock.unlock()
    }

    /// Test-only visibility into the bounded cache. The sorted result avoids exposing LRU order.
    var cachedLanguagesForTesting: [SpellingDictionaryLanguage] {
        lock.lock()
        let languages = cache.keys.sorted { $0.rawValue < $1.rawValue }
        lock.unlock()
        return languages
    }

    private func cachedIndexOrRequestLoad(for language: SpellingDictionaryLanguage) -> SymSpell? {
        lock.lock()
        if var entry = cache[language] {
            accessSequence &+= 1
            entry.lastAccessSequence = accessSequence
            cache[language] = entry
            lock.unlock()
            return entry.symSpell
        }
        let shouldLoad = loadingLanguages.insert(language).inserted
        lock.unlock()

        if shouldLoad {
            loadInBackground(language)
        }
        return nil
    }

    private func requestLoad(for language: SpellingDictionaryLanguage) {
        lock.lock()
        let shouldLoad = cache[language] == nil
            && loadingLanguages.insert(language).inserted
        lock.unlock()
        if shouldLoad {
            loadInBackground(language)
        }
    }

    private func loadInBackground(_ language: SpellingDictionaryLanguage) {
        DispatchQueue.global(qos: .utility).async { [self] in
            guard let contents = resourceLoader(language) else {
                lock.lock()
                loadingLanguages.remove(language)
                lock.unlock()
                CotabbyLogger.app.error(
                    "SymSpell dictionary resource \(language.resourceName).txt not found in bundle"
                )
                return
            }

            let symSpell = makeEmptyIndex()
            symSpell.loadDictionary(contents: contents)

            lock.lock()
            publish(symSpell, for: language)
            loadingLanguages.remove(language)
            lock.unlock()
            CotabbyLogger.app.info(
                "SymSpell loaded \(symSpell.wordCount) \(language.displayName) words for correction"
            )
        }
    }

    /// Must be called with `lock` held. The newly loaded index is newest, so eviction removes the
    /// least recently used older language and keeps memory bounded even for multilingual users.
    private func publish(_ symSpell: SymSpell, for language: SpellingDictionaryLanguage) {
        accessSequence &+= 1
        cache[language] = CacheEntry(
            symSpell: symSpell,
            lastAccessSequence: accessSequence
        )

        while cache.count > cacheLimit,
              let leastRecentlyUsed = cache.min(by: {
                  $0.value.lastAccessSequence < $1.value.lastAccessSequence
              })?.key {
            cache.removeValue(forKey: leastRecentlyUsed)
        }
    }

    private func makeEmptyIndex() -> SymSpell {
        SymSpell(
            maxDictionaryEditDistance: maxEditDistance,
            prefixLength: prefixLength
        )
    }

    private static func bundledContents(for language: SpellingDictionaryLanguage) -> String? {
        guard let url = resourceURL(for: language), let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return language == .english ? contents + "\n" + englishOverrides() : contents
    }

    /// Counts for everyday words the Google-derived frequency list undercounts or lacks: it splits
    /// `cannot` into `can not` (88k uses against 200M+ for `think`) and predates `instagram`.
    /// Without this, `connot` became `cont`.
    static func englishOverrides(in bundle: Bundle = .main) -> String {
        guard let url = bundle.url(forResource: "frequency_overrides_en", withExtension: "txt") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Xcode may flatten resources or preserve their source folder, so probe both bundle layouts.
    private static func resourceURL(
        for language: SpellingDictionaryLanguage,
        in bundle: Bundle = .main
    ) -> URL? {
        bundle.url(forResource: language.resourceName, withExtension: "txt")
            ?? bundle.url(
                forResource: language.resourceName,
                withExtension: "txt",
                subdirectory: "SpellingDictionaries"
            )
            ?? bundle.url(
                forResource: language.resourceName,
                withExtension: "txt",
                subdirectory: "Resources/SpellingDictionaries"
            )
    }
}
