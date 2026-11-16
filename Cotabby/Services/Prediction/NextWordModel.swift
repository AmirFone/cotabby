import Foundation

/// File overview:
/// The bundled next-word table: for each context of up to three previous words, the most likely
/// next words with their counts, built from ~2M everyday English sentences (Tatoeba, CC BY 2.0 FR)
/// by `Tools/ngram/build_model.py` and `export_binary.py`.
///
/// The file is memory-mapped, not parsed: contexts are 64-bit hashes of word ids in one sorted array,
/// so a lookup is a binary search (about 19 comparisons) plus a slice read. Loading costs nothing up
/// front and only the pages a lookup touches become resident.
nonisolated final class NextWordModel: @unchecked Sendable {
    struct Entry: Equatable {
        let word: String
        let count: Int
    }

    let vocabulary: [String]
    private let wordIDs: [String: UInt16]
    private let data: Data
    private let contextCount: Int
    private let hashesOffset: Int
    private let totalsOffset: Int
    private let startsOffset: Int
    private let wordsOffset: Int
    private let countsOffset: Int

    static let sentenceStart = "<s>"
    static let name = "<name>"
    static let number = "<num>"

    init?(data: Data) {
        guard data.count > 16, data.prefix(4) == Data("CNW1".utf8) else { return nil }
        self.data = data
        let vocabCount = Int(data.readUInt32(at: 4))
        contextCount = Int(data.readUInt32(at: 8))
        let entryCount = Int(data.readUInt32(at: 12))
        var offset = 16
        var vocabulary: [String] = []
        vocabulary.reserveCapacity(vocabCount)
        var wordIDs: [String: UInt16] = [:]
        wordIDs.reserveCapacity(vocabCount)
        for id in 0..<vocabCount {
            let length = Int(data[data.startIndex + offset])
            let bytes = data[(data.startIndex + offset + 1)..<(data.startIndex + offset + 1 + length)]
            guard let word = String(bytes: bytes, encoding: .utf8) else { return nil }
            vocabulary.append(word)
            wordIDs[word] = UInt16(id)
            offset += 1 + length
        }
        self.vocabulary = vocabulary
        self.wordIDs = wordIDs
        hashesOffset = offset
        totalsOffset = hashesOffset + contextCount * 8
        startsOffset = totalsOffset + contextCount * 4
        wordsOffset = startsOffset + (contextCount + 1) * 4
        countsOffset = wordsOffset + entryCount * 2
        guard countsOffset + entryCount * 2 <= data.count else { return nil }
    }

    /// The model shipped in the app bundle. `prewarm` pages it in on a background queue.
    static func bundled(prewarm: Bool = false) -> NextWordModel? {
        guard let url = Bundle.main.url(forResource: "next_word_model_en", withExtension: "bin"),
              let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let model = NextWordModel(data: data) else { return nil }
        if prewarm {
            DispatchQueue.global(qos: .utility).async { model.prewarm() }
        }
        return model
    }

    /// Asks the kernel to page the mapped file in ahead of use, so the first predictions do not pay
    /// for page faults (a cold lookup was about 4 ms against 0.1 ms warm). Advisory and read-only, so
    /// it is safe on any thread; the mapping's base address is page-aligned as `madvise` requires.
    func prewarm() {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            _ = madvise(UnsafeMutableRawPointer(mutating: base), bytes.count, MADV_WILLNEED)
        }
    }

    func contains(_ word: String) -> Bool {
        wordIDs[word] != nil
    }

    /// The next words recorded after `context` (most likely first) and how often the context was seen,
    /// or nil when the context is unknown (a word in it is not in the vocabulary, or it was too rare).
    func nextWords(after context: [String]) -> (total: Int, entries: [Entry])? {
        var ids: [UInt16] = []
        ids.reserveCapacity(context.count)
        for word in context {
            guard let id = wordIDs[word] else { return nil }
            ids.append(id)
        }
        guard let index = indexOfContext(hash: Self.contextHash(ids)) else { return nil }
        let start = Int(data.readUInt32(at: startsOffset + index * 4))
        let end = Int(data.readUInt32(at: startsOffset + (index + 1) * 4))
        var entries: [Entry] = []
        entries.reserveCapacity(end - start)
        for entry in start..<end {
            let word = vocabulary[Int(data.readUInt16(at: wordsOffset + entry * 2))]
            entries.append(Entry(word: word, count: Int(data.readUInt16(at: countsOffset + entry * 2))))
        }
        return (Int(data.readUInt32(at: totalsOffset + index * 4)), entries)
    }

    private func indexOfContext(hash: UInt64) -> Int? {
        var low = 0
        var high = contextCount - 1
        while low <= high {
            let middle = (low + high) / 2
            let value = data.readUInt64(at: hashesOffset + middle * 8)
            if value == hash { return middle }
            if value < hash { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }

    /// FNV-1a over the little-endian bytes of each word id, then the context length. Must match
    /// `Tools/ngram/export_binary.py`.
    static func contextHash(_ ids: [UInt16]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for id in ids {
            hash ^= UInt64(id & 0xff)
            hash = hash &* prime
            hash ^= UInt64(id >> 8)
            hash = hash &* prime
        }
        hash ^= UInt64(ids.count)
        return hash &* prime
    }
}

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }

    func readUInt32(at offset: Int) -> UInt32 {
        withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    func readUInt64(at offset: Int) -> UInt64 {
        withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }
}
