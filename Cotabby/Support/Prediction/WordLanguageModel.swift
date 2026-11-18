import Foundation

/// File overview:
/// The pure half of the word language model: how a language model's "which piece comes next"
/// becomes "how likely is each dictionary word here". `WordLanguageModelService` runs the model;
/// nothing in this file knows which runtime that is, so the tests drive it with made-up scores.
///
/// Why a language model at all: the n-gram table sees the last three words of the current sentence.
/// That is enough for `would like to`, and blind to everything that sets a tense: `Yesterday`, the
/// verbs earlier in the sentence, the sentence before. A language model reads all of it, which is
/// what puts `walked` ahead of `walking` after `Yesterday I`. Measured on held-out text
/// (`Tools/prediction/`), the right form of a verb comes first 85% of the time with it and 68%
/// without.
///
/// Three types, in the order the data flows:
/// - `LanguageModelContext` cuts the text before the caret into what the model reads and the letters
///   of the word being typed. The model is run once per word, not once per key: its answer depends
///   only on the text before the word, so every letter typed afterwards reuses it.
/// - `LanguageModelLexicon` knows, for every dictionary word, which model pieces it starts with,
///   and turns the model's scores for pieces into probabilities for words.
/// - `LanguageModelScores` is one answer: a log-probability per dictionary word for one context.

/// The text before the caret, split for the language model.
nonisolated struct LanguageModelContext: Equatable, Sendable {
    /// What identifies an answer: the text the model read, and whether a space follows it. `the`
    /// followed by a space and `the` followed by a line break predict differently spelled pieces.
    struct Key: Hashable, Sendable {
        let text: String
        let isSpaced: Bool
    }

    let key: Key
    /// The letters of the current word typed so far ("" right after a space).
    let prefix: String

    /// How far back the model reads.
    ///
    /// A text up to `maximumCharacters` long is read whole, so the model follows the subject and the
    /// words the writer has been using, not only the tense of the last sentence. A longer text loses
    /// its beginning in steps of `step` characters, counted from the start of the text: the cut stays
    /// where it is while the writer types the next `step` characters, and the model's memory of what
    /// it has read stays valid for all of them. (Reading "the last N characters" instead would move
    /// the start with every key and make the model re-read everything for every word.)
    ///
    /// Measured on long documents (`Tools/prediction/README.md`): reading up to 1,600 characters
    /// instead of the last four sentences puts the first suggestion right more often, and the
    /// re-read happens once per `step` characters instead of once per sentence.
    struct Reach: Equatable, Sendable {
        var maximumCharacters = 1_600
        var step = 800

        static let standard = Reach()
    }

    /// Nil where no word is being typed or about to be: directly after punctuation, a digit, or a
    /// symbol (`3rd`, `@jo`, `word.`), the same places the n-gram predictor stays quiet. A word
    /// joined to the one before by a dot, slash or hyphen is a word being typed (`users.na`).
    static func make(textBefore: String, reach: Reach = .standard) -> LanguageModelContext? {
        var body = Substring(textBefore)
        var prefixStart = body.endIndex
        while prefixStart > body.startIndex {
            let previous = body.index(before: prefixStart)
            guard body[previous].isLetter || body[previous] == "'" || body[previous] == "’" else { break }
            prefixStart = previous
        }
        let prefix = String(body[prefixStart...])
        body = body[..<prefixStart]
        if let before = body.last, !before.isWhitespace {
            // A word begun against a quote, a bracket or a hyphen, or one of several words joined by
            // a dot or a slash (`users.na`, `read/wr`). With no letter yet, only a slash or a hyphen
            // counts: a bare dot is the end of a sentence. The same rule as the n-gram predictor's.
            let opensWord = prefix.isEmpty ? "/-".contains(before) : "\"(“‘-./".contains(before)
            guard opensWord else { return nil }
            if prefix.isEmpty || "./".contains(before) {
                guard CurrentWordExtractor.endsInJoinedWords(textBefore) else { return nil }
            }
        }
        var end = body.endIndex
        var isSpaced = false
        while end > body.startIndex {
            let previous = body.index(before: end)
            guard body[previous] == " " || body[previous] == "\t" else { break }
            end = previous
            isSpaced = true
        }
        return LanguageModelContext(key: Key(text: window(of: body[..<end], reach: reach), isSpaced: isSpaced), prefix: prefix)
    }

    /// The end of `text` the model reads: all of it, or from the first sentence start after a cut
    /// placed at a multiple of `reach.step` (see `Reach`).
    private static func window(of text: Substring, reach: Reach) -> String {
        // Lengths are counted in UTF-8 bytes: that is free to ask, where counting characters would
        // walk the whole document on every key. For English text the two are nearly the same.
        let bytes = text.utf8
        let excess = bytes.count - reach.maximumCharacters
        guard excess > 0, reach.step > 0 else { return String(text) }
        let cut = (excess + reach.step - 1) / reach.step * reach.step
        var index = bytes.index(bytes.startIndex, offsetBy: cut)
        // A cut inside a multi-byte character moves on to the next whole one.
        while index < bytes.endIndex, bytes[index] & 0b1100_0000 == 0b1000_0000 {
            index = bytes.index(after: index)
        }
        let rest = text[index...]
        // Start at a sentence start when one is near: text that begins mid-sentence reads as a
        // fragment to the model. Failing that, at the next word.
        let nearby = rest.prefix(sentenceSearch)
        var previousEndsSentence = false
        var afterSpace: Substring.Index?
        var position = nearby.startIndex
        while position < nearby.endIndex {
            let character = nearby[position]
            if character.isWhitespace {
                if character.isNewline { previousEndsSentence = true }
            } else {
                if previousEndsSentence { return String(rest[position...]) }
                let previous = position > nearby.startIndex ? nearby[nearby.index(before: position)] : nil
                if afterSpace == nil, previous?.isWhitespace == true { afterSpace = position }
                if ".!?".contains(character) {
                    let next = nearby.index(after: position)
                    previousEndsSentence = next < nearby.endIndex && nearby[next].isWhitespace
                } else {
                    previousEndsSentence = false
                }
            }
            position = nearby.index(after: position)
        }
        return String(rest[(afterSpace ?? rest.startIndex)...])
    }

    /// How far past the cut a sentence start is looked for before settling for a word start.
    private static let sentenceSearch = 300
}

/// Every dictionary word with the model pieces it starts with.
///
/// A language model predicts pieces, not words: common words are one piece (` went`), rarer ones
/// several (` shin` + `s`). One pass of the model gives the probability of each first piece.
///
/// **First estimate, no further pass.** A word's probability is its first piece's probability times
/// the word's share of that piece, where the share is how common the word is among the dictionary
/// words starting with the same piece. For a one-piece word the share is close to 1 and the number
/// is nearly the model's own.
///
/// **Exact for a piece that matters.** Once the letters typed narrow the field to words that share
/// a first piece (`shin`, `shins`, `shiny`), commonness is the wrong tie-break: after `my` the
/// writer means `shins`. One more pass, with that piece added to the text, gives the probability of
/// each second piece and of the word ending there, and `refined` replaces the estimate for every
/// word starting with the piece. `WordLanguageModelCore.refine` decides when that pass is worth it.
///
/// Built once when the model loads (it needs the model's own way of cutting words into pieces) and
/// immutable afterwards, so answers on any thread can share it.
nonisolated final class LanguageModelLexicon: Sendable {
    /// Sorted by UTF-8 bytes, so all words with a given beginning are one contiguous range.
    let words: [String]
    private let indexByWord: [String: Int32]
    /// Each word in four spellings: after a space or not, lowercase or capitalized. A word can come
    /// capitalized mid-text (a name, a sentence start), and the two spellings are different pieces
    /// to the model, so both are read and added.
    private let spacedLower: Spelling
    private let spacedCapital: Spelling
    private let bareLower: Spelling
    private let bareCapital: Spelling

    private struct Spelling: Sendable {
        var firstPiece: [Int32]
        /// -1 for a word that is a single piece.
        var secondPiece: [Int32]
        /// log of the word's share among the words with the same first piece.
        var logShare: [Float]
        /// log of the word's share among the words with the same first two pieces.
        var logPairShare: [Float]
        var wordsByFirstPiece: [Int32: [Int32]]
    }

    /// What the model expects after a first piece, from the pass that refines it.
    struct PieceContinuation {
        /// The model's raw scores for the piece after it (`log P = scores[piece] - normalizer`).
        let scores: UnsafeBufferPointer<Float>
        let normalizer: Float
        /// log of the probability that the word ends there (the next piece starts a new word or is
        /// punctuation).
        let logEnd: Float
    }

    /// log P(word) in both spellings and added together, in the lexicon's word order.
    struct Probabilities: Sendable {
        fileprivate(set) var lower: [Float]
        fileprivate(set) var capital: [Float]
        fileprivate(set) var combined: [Float]
    }

    /// - Parameters:
    ///   - entries: dictionary words with how often each is used.
    ///   - pieces: the ids of the model pieces of a text, empty when the model cannot split it.
    init(entries: [(word: String, count: Double)], pieces: (String) -> [Int32]) {
        let sorted = entries.sorted { $0.word.utf8.lexicographicallyPrecedes($1.word.utf8) }
        words = sorted.map(\.word)
        var indexByWord: [String: Int32] = [:]
        indexByWord.reserveCapacity(sorted.count)
        for (index, entry) in sorted.enumerated() { indexByWord[entry.word] = Int32(index) }
        self.indexByWord = indexByWord

        func spelling(_ write: (String) -> String) -> Spelling {
            let cut = sorted.map { pieces(write($0.word)) }
            let first = cut.map { $0.first ?? -1 }
            let second = cut.map { $0.count > 1 ? $0[1] : -1 }
            var firstTotals: [Int32: Double] = [:]
            var pairTotals: [Int64: Double] = [:]
            var byFirst: [Int32: [Int32]] = [:]
            func pair(_ index: Int) -> Int64 { Int64(first[index]) << 32 | Int64(UInt32(bitPattern: second[index])) }
            for (index, entry) in sorted.enumerated() where first[index] >= 0 {
                firstTotals[first[index], default: 0] += max(entry.count, 1)
                pairTotals[pair(index), default: 0] += max(entry.count, 1)
                byFirst[first[index], default: []].append(Int32(index))
            }
            var share = [Float](repeating: -.infinity, count: sorted.count)
            var pairShare = [Float](repeating: -.infinity, count: sorted.count)
            for (index, entry) in sorted.enumerated() where first[index] >= 0 {
                share[index] = Float(log(max(entry.count, 1) / (firstTotals[first[index]] ?? 1)))
                pairShare[index] = Float(log(max(entry.count, 1) / (pairTotals[pair(index)] ?? 1)))
            }
            return Spelling(firstPiece: first, secondPiece: second, logShare: share, logPairShare: pairShare, wordsByFirstPiece: byFirst)
        }
        spacedLower = spelling { " " + $0 }
        spacedCapital = spelling { " " + Self.capitalized($0) }
        bareLower = spelling { $0 }
        bareCapital = spelling { Self.capitalized($0) }
    }

    static func capitalized(_ word: String) -> String {
        if word == "i" || word.hasPrefix("i'") { return "I" + word.dropFirst() }
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    func index(of word: String) -> Int? {
        indexByWord[word].map(Int.init)
    }

    /// The positions in `words` of every word starting with `prefix`.
    func range(ofPrefix prefix: String) -> Range<Int> {
        guard !prefix.isEmpty else { return 0..<words.count }
        let target = Array(prefix.utf8)
        func firstIndex(where isAtOrPast: ([UInt8]) -> Bool) -> Int {
            var low = 0
            var high = words.count
            while low < high {
                let middle = (low + high) / 2
                if isAtOrPast(Array(words[middle].utf8)) { high = middle } else { low = middle + 1 }
            }
            return low
        }
        let lower = firstIndex { !$0.lexicographicallyPrecedes(target) }
        // Past the range: the first word that neither starts with the prefix nor sorts before it.
        let upper = firstIndex { !$0.lexicographicallyPrecedes(target) && !$0.starts(with: target) }
        return lower..<upper
    }

    /// The first estimate of log P(word) for every word, from the model's raw next-piece scores
    /// (`log P(piece) = scores[piece] - normalizer`).
    func probabilities(scores: UnsafeBufferPointer<Float>, normalizer: Float, isSpaced: Bool) -> Probabilities {
        let (lowerSpelling, capitalSpelling) = spellings(isSpaced: isSpaced)
        func estimate(_ spelling: Spelling) -> [Float] {
            (0..<words.count).map { index in
                let piece = Int(spelling.firstPiece[index])
                guard piece >= 0, piece < scores.count else { return -.infinity }
                return scores[piece] - normalizer + spelling.logShare[index]
            }
        }
        let lower = estimate(lowerSpelling)
        let capital = estimate(capitalSpelling)
        return Probabilities(lower: lower, capital: capital, combined: zip(lower, capital).map(Self.logSum))
    }

    /// `probabilities` with the estimate replaced by the model's own numbers for every word whose
    /// first piece is `piece`, from a pass over the text with that piece added.
    ///
    func refined(_ probabilities: Probabilities, piece: Int32, isSpaced: Bool, after: PieceContinuation) -> Probabilities {
        let (scores, normalizer, logEnd) = (after.scores, after.normalizer, after.logEnd)
        let (lowerSpelling, capitalSpelling) = spellings(isSpaced: isSpaced)
        func refine(_ spelling: Spelling, _ estimates: [Float]) -> [Float] {
            var values = estimates
            for word in spelling.wordsByFirstPiece[piece] ?? [] {
                let index = Int(word)
                // Undo the share to get back the first piece's own log-probability.
                let pieceLogProbability = values[index] - spelling.logShare[index]
                let second = Int(spelling.secondPiece[index])
                if second < 0 {
                    values[index] = pieceLogProbability + logEnd
                } else if second < scores.count {
                    values[index] = pieceLogProbability + scores[second] - normalizer + spelling.logPairShare[index]
                }
            }
            return values
        }
        let lower = refine(lowerSpelling, probabilities.lower)
        let capital = refine(capitalSpelling, probabilities.capital)
        var combined = probabilities.combined
        for word in (lowerSpelling.wordsByFirstPiece[piece] ?? []) + (capitalSpelling.wordsByFirstPiece[piece] ?? []) {
            combined[Int(word)] = Self.logSum(lower[Int(word)], capital[Int(word)])
        }
        return Probabilities(lower: lower, capital: capital, combined: combined)
    }

    /// The first piece of `word` in the spelling that currently counts for more, and whether the
    /// word is longer than that piece. Nil for a word the model cannot spell.
    func leadingPiece(of index: Int, in probabilities: Probabilities, isSpaced: Bool) -> (piece: Int32, hasMore: Bool)? {
        let (lowerSpelling, capitalSpelling) = spellings(isSpaced: isSpaced)
        let spelling = probabilities.capital[index] > probabilities.lower[index] ? capitalSpelling : lowerSpelling
        guard spelling.firstPiece[index] >= 0 else { return nil }
        return (spelling.firstPiece[index], spelling.secondPiece[index] >= 0)
    }

    private func spellings(isSpaced: Bool) -> (lower: Spelling, capital: Spelling) {
        isSpaced ? (spacedLower, spacedCapital) : (bareLower, bareCapital)
    }

    /// log(e^a + e^b) without leaving log space, which keeps tiny probabilities exact.
    private static func logSum(_ first: Float, _ second: Float) -> Float {
        let high = max(first, second)
        return high == -.infinity ? high : high + log1p(exp(min(first, second) - high))
    }
}

/// The language model's answer for one context: how likely each dictionary word is to come next.
nonisolated struct LanguageModelScores: Sendable {
    let key: LanguageModelContext.Key
    let lexicon: LanguageModelLexicon
    let probabilities: LanguageModelLexicon.Probabilities
    /// First pieces whose words already carry the model's exact numbers (`LanguageModelLexicon.refined`).
    let refinedPieces: Set<Int32>
    /// The writer's own words found in the text (`TextVocabulary`): names and terms the dictionary
    /// lacks, each with how likely the model finds it next, and dictionary words to show capitalized.
    let textWords: [TextWord]

    /// A word from the text itself, as the strip should offer it.
    struct TextWord: Sendable, Equatable {
        /// Spelled and capitalized as the writer wrote it.
        let display: String
        let lowercased: String
        /// log P(word next); nil for a dictionary word, which keeps the lexicon's number and only
        /// takes its capital from here.
        var logProbability: Float?
        /// The model pieces of the word as it would be written here, so an exact pass over its first
        /// piece can replace the estimate (`WordLanguageModelCore.refine`).
        var pieces: [Int32] = []
        /// log P of the first piece alone, kept to rebuild the word's number from.
        var firstPieceLogProbability: Float = -.infinity
    }
    /// The likeliest words overall, best first: what `best` returns before any letter is typed,
    /// worked out once on the model's queue instead of on every prediction.
    private let overallBest: [Int]

    static let overallBestCount = 40

    /// log P(word), in the lexicon's word order.
    var logProbabilities: [Float] { probabilities.combined }

    init(
        key: LanguageModelContext.Key,
        lexicon: LanguageModelLexicon,
        probabilities: LanguageModelLexicon.Probabilities,
        refinedPieces: Set<Int32> = [],
        textWords: [TextWord] = []
    ) {
        self.key = key
        self.lexicon = lexicon
        self.probabilities = probabilities
        self.refinedPieces = refinedPieces
        self.textWords = textWords
        overallBest = Self.best(in: 0..<probabilities.combined.count, of: probabilities.combined, limit: Self.overallBestCount)
    }

    func logProbability(of word: String) -> Float? {
        lexicon.index(of: word).map { probabilities.combined[$0] }
    }

    /// The writer's own words (not in the dictionary) starting with `prefix`, with their
    /// log-probabilities.
    func textWords(prefix: String) -> [(word: String, logProbability: Float)] {
        textWords.compactMap { word in
            guard let logProbability = word.logProbability, word.lowercased.hasPrefix(prefix) else { return nil }
            return (word.lowercased, logProbability)
        }
    }

    /// How a word should be written when offered, for the words the text gives a spelling for
    /// (`priyanka` → `Priyanka`); nil for every other word.
    func display(of word: String) -> String? {
        textWords.first { $0.lowercased == word }?.display
    }

    /// The likeliest words starting with `prefix`, best first.
    func best(prefix: String, limit: Int) -> [(word: String, logProbability: Float)] {
        bestIndices(prefix: prefix, limit: limit).map { (lexicon.words[$0], probabilities.combined[$0]) }
    }

    func bestIndices(prefix: String, limit: Int) -> [Int] {
        prefix.isEmpty
            ? Array(overallBest.prefix(limit))
            : Self.best(in: lexicon.range(ofPrefix: prefix), of: probabilities.combined, limit: limit)
    }

    /// The first pieces worth one more pass of the model for these typed letters, most useful first:
    /// pieces shared by several of the likeliest words, or starting a likely word that is longer
    /// than the piece. Those are the words the first estimate orders by commonness alone.
    func piecesWorthRefining(prefix: String, among candidates: Int = 8, limit: Int = 3) -> [Int32] {
        guard !prefix.isEmpty else { return [] }
        struct Use {
            var words = 0
            var hasLongerWord = false
            let bestRank: Int
        }
        var uses: [Int32: Use] = [:]
        for (rank, index) in bestIndices(prefix: prefix, limit: candidates).enumerated() {
            guard let leading = lexicon.leadingPiece(of: index, in: probabilities, isSpaced: key.isSpaced),
                  !refinedPieces.contains(leading.piece) else { continue }
            var use = uses[leading.piece] ?? Use(bestRank: rank)
            use.words += 1
            use.hasLongerWord = use.hasLongerWord || leading.hasMore
            uses[leading.piece] = use
        }
        return uses
            .filter { $0.value.words > 1 || $0.value.hasLongerWord }
            .sorted { $0.value.bestRank < $1.value.bestRank }
            .prefix(limit)
            .map(\.key)
    }

    /// The `limit` highest-scoring positions in `range`, best first, in one pass with a short
    /// sorted list (a full sort of 80,000 scores per prediction would cost more than the rest).
    private static func best(in range: Range<Int>, of scores: [Float], limit: Int) -> [Int] {
        var kept: [Int] = []
        kept.reserveCapacity(limit + 1)
        for index in range where scores[index] > -.infinity {
            if kept.count == limit, let last = kept.last, scores[index] <= scores[last] { continue }
            let position = kept.firstIndex { scores[index] > scores[$0] } ?? kept.count
            kept.insert(index, at: position)
            if kept.count > limit { kept.removeLast() }
        }
        return kept
    }
}
