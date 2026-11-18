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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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

    /// `first second count` lines into a table keyed by `"first second"`.
    ///
    /// Read as bytes: a quarter of a million lines went through `enumerateLines`, `split` and string
    /// interpolation, about 0.3 s at every launch during which fixes had no context to go on. A
    /// line in the plain shape (two single spaces, digits last) is cut directly; anything else goes
    /// through `parseLine`, the original reading, so the table is the same either way.
    static func parse(_ contents: String) -> [String: Int64] {
        var result: [String: Int64] = [:]
        result.reserveCapacity(250_000)
        var text = contents
        text.withUTF8 { bytes in
            var lineStart = 0
            while lineStart < bytes.count {
                var lineEnd = lineStart
                while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
                let line = UnsafeBufferPointer(rebasing: bytes[lineStart..<lineEnd])
                if let (key, count) = plainPair(line) {
                    result[key] = count
                } else if !line.isEmpty, let unusual = String(bytes: line, encoding: .utf8) {
                    // Unusual lines keep the reading they always had, line separators included.
                    unusual.enumerateLines { piece, _ in
                        if let (key, count) = parseLine(piece) { result[key] = count }
                    }
                }
                lineStart = lineEnd + 1
            }
        }
        return result
    }

    /// The key and count of a line that is exactly `word space word space digits` in ASCII, else nil.
    private static func plainPair(_ line: UnsafeBufferPointer<UInt8>) -> (String, Int64)? {
        var firstSpace = -1
        var secondSpace = -1
        for (index, byte) in line.enumerated() {
            guard byte < 0x80, byte != 0x0D, byte != 0x09 else { return nil }
            guard byte == 0x20 else { continue }
            if firstSpace < 0 {
                firstSpace = index
            } else if secondSpace < 0 {
                secondSpace = index
            } else {
                return nil
            }
        }
        guard firstSpace > 0, secondSpace > firstSpace + 1, secondSpace < line.count - 1, line.count - secondSpace <= 19 else {
            return nil
        }
        var count: Int64 = 0
        for index in (secondSpace + 1)..<line.count {
            let digit = line[index]
            guard digit >= 0x30, digit <= 0x39 else { return nil }
            count = count * 10 + Int64(digit - 0x30)
        }
        return String(bytes: UnsafeBufferPointer(rebasing: line[0..<secondSpace]), encoding: .utf8).map { ($0, count) }
    }

    /// One line read the general way: any run of spaces separates, three fields exactly.
    static func parseLine(_ line: String) -> (String, Int64)? {
        let fields = line.split(separator: " ")
        guard fields.count == 3, let count = Int64(fields[2]) else { return nil }
        return ("\(fields[0]) \(fields[1])", count)
    }

    static let bundledContents: ResourceLoader = {
        guard let url = Bundle.main.url(forResource: "frequency_bigramdictionary_en_243_342", withExtension: "txt") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
