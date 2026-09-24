import Foundation
import Logging

/// File overview:
/// How often one English word follows another, from SymSpell's bundled bigram list (242k pairs
/// derived from Google Books Ngram data). It is the local "does this make sense here" signal for
/// corrections: `know wich` should become `which` and `with wich` should too, but `went their`
/// should become `there` even though `their` is spelled correctly.
///
/// Loaded once on a background queue (about 20 MB resident). Until the load finishes `count`
/// returns nil so callers fall back to context-free ranking instead of blocking a keystroke.
nonisolated final class BigramContextModel: @unchecked Sendable {
    typealias ResourceLoader = @Sendable () -> String?

    private let lock = NSLock()
    /// Guarded by `lock`. Keys are `"first second"`, lowercased.
    private var pairs: [String: Int64]?

    init(resourceLoader: @escaping ResourceLoader = BigramContextModel.bundledContents) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let parsed = resourceLoader().map(Self.parse) ?? [:]
            self?.lock.withLock { self?.pairs = parsed }
            CotabbyLogger.suggestion.debug("bigram context model loaded \(parsed.count) pairs")
        }
    }

    /// Synchronous constructor for tests.
    init(contents: String) {
        pairs = Self.parse(contents)
    }

    var isLoaded: Bool {
        lock.withLock { pairs != nil }
    }

    /// Occurrences of `second` directly after `first`: 0 when the pair is not in the list, nil while
    /// the list is still loading.
    func count(first: String, second: String) -> Int64? {
        let key = first.lowercased() + " " + second.lowercased()
        return lock.withLock { pairs.map { $0[key] ?? 0 } }
    }

    private static func parse(_ contents: String) -> [String: Int64] {
        var result: [String: Int64] = [:]
        result.reserveCapacity(250_000)
        contents.enumerateLines { line, _ in
            let fields = line.split(separator: " ")
            guard fields.count == 3, let count = Int64(fields[2]) else { return }
            result["\(fields[0]) \(fields[1])"] = count
        }
        return result
    }

    static let bundledContents: ResourceLoader = {
        guard let url = Bundle.main.url(forResource: "frequency_bigramdictionary_en_243_342", withExtension: "txt") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
