import Foundation

/// File overview:
/// The pure half of the sentence model: a small language model fine-tuned to write a sentence back
/// with its spelling fixed (`Tools/sentence-model/`). Two rules live here, and nothing in this file
/// knows which runtime executes the model.
///
/// - `SentenceModelDecoder` gets the model's answer quickly. A plain run writes the answer one piece
///   per model pass, about 150 ms for a sentence. Almost every word of the answer is the word the
///   writer typed, so the decoder guesses that the answer *is* the sentence as typed, has the model
///   check the whole guess in one pass, and only writes piece by piece where the model disagrees.
///   A correct sentence costs one pass (about 30 ms).
/// - `SentenceModelGate` decides what to do with each word the model changed, from the probability
///   the model itself gave that word: apply it on the spot, offer it for review, or drop it.
///
/// Why they are split from the runtime: both are deterministic rules over tokens and numbers, so the
/// unit tests drive them with a scripted model and never load 600 MB of weights.

/// The model's first choice for the next piece of text, and the log-probability it gave that choice.
nonisolated struct SentenceModelPrediction: Equatable, Sendable {
    let token: Int32
    let logProbability: Float
}

/// What the decoder needs from a language model: text to pieces, pieces to bytes, and a memory of
/// the pieces seen so far that can grow and be rolled back.
///
/// `LlamaTokenModel` is the real one; tests use a scripted stand-in.
protocol SentenceTokenModel: AnyObject {
    /// `text` as model pieces. `parsingSpecial` lets control markers such as `<|im_start|>` become
    /// their single pieces; it is false for anything the writer typed.
    func tokens(for text: String, parsingSpecial: Bool) -> [Int32]
    /// The UTF-8 bytes of one piece. Bytes, not a string: one character can be split across pieces.
    func bytes(for token: Int32) -> [UInt8]
    /// True for the pieces that end an answer.
    func isEnd(_ token: Int32) -> Bool
    /// Adds pieces to the memory and returns, for each piece from index `first` on, the model's first
    /// choice for the piece after it. Nil when the model could not run. `first` exists because the
    /// prediction step is a real share of a pass and the pieces of the prompt never need one.
    func append(_ tokens: [Int32], predictionsFrom first: Int) -> [SentenceModelPrediction]?
    /// Drops the last `count` pieces from the memory.
    func forget(last count: Int)
    /// Empties the memory.
    func reset()
}

/// The model's corrected sentence, word by word, with how sure it was of each word (0...1: the
/// lowest probability it gave any piece of that word).
nonisolated struct SentenceModelOutput: Equatable, Sendable {
    struct Word: Equatable, Sendable {
        let text: String
        let probability: Double
    }

    let words: [Word]
    /// Model passes used; one for a sentence it left alone.
    let passes: Int
}

nonisolated enum SentenceModelDecoder {
    /// The exact frame the fine-tune was trained on: the typed sentence as the user turn, and an
    /// assistant turn that opens with an empty thinking block. Handing the block over here saves
    /// the model writing it one piece at a time.
    static func prompt(for sentence: String) -> String {
        "<|im_start|>user\n\(sentence)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    /// Extra pieces the answer may run past the typed sentence before decoding gives up.
    private static let slack = 16

    /// Words as the model and the gate count them: runs between spaces, tabs, and line breaks.
    static func words(in text: String) -> [Substring] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
    }

    /// The model's corrected version of `sentence`, or nil when the model could not run.
    ///
    /// A guess is only ever accepted where it equals the model's own first choice, so the result is
    /// exactly what writing the answer piece by piece would produce.
    static func correct(_ sentence: String, model: any SentenceTokenModel) -> SentenceModelOutput? {
        let frame = model.tokens(for: prompt(for: sentence), parsingSpecial: true)
        let typedWords = words(in: sentence)
        var guess = model.tokens(for: sentence, parsingSpecial: false)
        guard !frame.isEmpty, !guess.isEmpty else { return nil }

        var written = WrittenAnswer()
        var passes = 1
        model.reset()
        // The last piece of the frame predicts the first piece of the answer, hence `count - 1`.
        guard let firstRows = model.append(frame + guess, predictionsFrom: frame.count - 1),
              firstRows.count == guess.count + 1 else { return nil }
        var next = accept(guess[...], rows: firstRows, into: &written, model: model)
        let budget = guess.count + slack

        while !model.isEnd(next.token), written.tokenCount < budget {
            written.add(next, bytes: model.bytes(for: next.token))
            passes += 1
            guard let row = model.append([next.token], predictionsFrom: 0)?.first else { return nil }
            next = row
            // The model is about to start a new word: guess that the rest is as typed and check it
            // in one pass. If the very next word is wrong too, the guess fails at once and the loop
            // writes that word piece by piece as well.
            guard !model.isEnd(next.token), isWhitespace(model.bytes(for: next.token).first) else { continue }
            let rest = typedWords.dropFirst(written.wordCount)
            guard !rest.isEmpty else { continue }
            guess = model.tokens(for: " " + rest.joined(separator: " "), parsingSpecial: false)
            guard guess.first == next.token else { continue }
            written.add(next, bytes: model.bytes(for: next.token))
            passes += 1
            guard let rows = model.append(guess, predictionsFrom: 0), rows.count == guess.count else { return nil }
            next = accept(guess.dropFirst(), rows: rows, into: &written, model: model)
        }
        return SentenceModelOutput(words: written.words(), passes: passes)
    }

    /// Takes guessed pieces for as long as each is the model's first choice, and drops the rest of
    /// the guess from the model's memory. `rows[0]` is the prediction for the first guessed piece, so
    /// `rows` holds one more entry than `guess`. Returns the prediction for the piece after the last
    /// one taken.
    private static func accept(
        _ guess: ArraySlice<Int32>,
        rows: [SentenceModelPrediction],
        into written: inout WrittenAnswer,
        model: any SentenceTokenModel
    ) -> SentenceModelPrediction {
        var taken = 0
        for token in guess {
            guard rows[taken].token == token else { break }
            written.add(rows[taken], bytes: model.bytes(for: token))
            taken += 1
        }
        if taken < guess.count {
            model.forget(last: guess.count - taken)
        }
        return rows[taken]
    }

    private static func isWhitespace(_ byte: UInt8?) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x09
    }

    /// The answer so far as bytes, with the lowest log-probability seen in each word.
    private struct WrittenAnswer {
        private var bytes: [UInt8] = []
        private var lowest: [Float] = []
        private var isInsideWord = false
        private(set) var tokenCount = 0

        var wordCount: Int { lowest.count }

        mutating func add(_ prediction: SentenceModelPrediction, bytes pieceBytes: [UInt8]) {
            tokenCount += 1
            for byte in pieceBytes {
                if SentenceModelDecoder.isWhitespace(byte) {
                    isInsideWord = false
                } else {
                    if !isInsideWord {
                        lowest.append(0)
                        isInsideWord = true
                    }
                    lowest[lowest.count - 1] = min(lowest[lowest.count - 1], prediction.logProbability)
                }
            }
            bytes += pieceBytes
        }

        func words() -> [SentenceModelOutput.Word] {
            let texts = SentenceModelDecoder.words(in: String(bytes: bytes, encoding: .utf8) ?? "")
            // A word count that disagrees means the bytes were not valid text; the gate treats an
            // answer with the wrong number of words as no answer.
            guard texts.count == lowest.count else { return [] }
            return zip(texts, lowest).map { SentenceModelOutput.Word(text: String($0), probability: Double(exp($1))) }
        }
    }
}

/// One word the sentence model would change, how sure it was, and what was done about it: `fixed`
/// (typed in place), `asked` (left for the review card) or `left` (not sure enough to mention).
nonisolated struct SentencePassWord: Codable, Equatable, Sendable {
    let typed: String
    let written: String
    let probability: Double
    let action: String
}

nonisolated enum SentenceModelGate {
    /// How sure the model must be of a changed word. Measured on 1,040 held-out sentences
    /// (`Tools/sentence-model/gate_report.py`): at 0.9 it fixes about 80% of misspellings and changes
    /// 0.2 correct words per 1,000; the few correct words it still changed were real words, so
    /// replacing a word the dictionary knows needs more.
    struct Bars: Equatable, Sendable {
        var applyMisspelling = 0.9
        var applyKnownWord = 0.95
        var suggest = 0.6
    }

    /// What the gate asks about single words beyond "is this a known word".
    struct WordChecks {
        /// The word is one the app's own dictionary (or the writer's vocabulary) has. Stricter
        /// than `isKnownWord`, which also takes the system checker's word for it.
        var isInDictionary: (String) -> Bool
        /// The writer kept this word when a fix was offered, or has written it often enough for it
        /// to be in their vocabulary.
        var isWritersOwn: (String) -> Bool = { _ in false }
    }

    /// Turns the model's answer into the same shape the local proofreader returns, so the sentence
    /// controller applies and reviews both the same way. Nil when the model changed nothing worth
    /// acting on, or when its answer has a different number of words than the sentence (it reworded
    /// instead of correcting, and no word can be matched to its fix).
    ///
    /// A change is used only when the word's punctuation is untouched (`work.` → `walk.` is a word
    /// change; `work.` → `work!` is not spelling). Letters-only comparison keeps the gate out of
    /// punctuation and spacing, which the local pass owns.
    ///
    /// Two limits come from what the model cannot know. It may only type in place a word that
    /// `words.isInDictionary` has: turning a term the dictionary lacks into another it lacks
    /// (`kubectl` into `kubelet`) is a guess about a term, not a spelling fix, and is asked about at
    /// most. And a word `words.isWritersOwn` names (one the writer chose to keep, or has made their
    /// own by writing it again and again) is never changed and never asked about: they have
    /// already answered.
    static func result(
        typed sentence: String,
        output: SentenceModelOutput,
        bars: Bars = Bars(),
        isKnownWord: (String) -> Bool,
        words: WordChecks? = nil
    ) -> LocalProofreadResult? {
        let typedWords = SentenceModelDecoder.words(in: sentence)
        guard typedWords.count == output.words.count else { return nil }

        var corrected = ""
        var cursor = sentence.startIndex
        var flagSpans: [FlagSpan] = []
        var changed = false
        for (typed, written) in zip(typedWords, output.words) {
            guard let change = change(typed: typed, written: written, bars: bars, isKnownWord: isKnownWord, words: words),
                  change.action != .left else { continue }
            let typedCore = change.typedCore

            corrected += sentence[cursor..<typedCore.startIndex]
            if change.action == .fixed {
                corrected += change.writtenCore
            } else {
                flagSpans.append(FlagSpan(start: corrected.count, typed: String(typedCore), option: String(change.writtenCore)))
                corrected += typedCore
            }
            cursor = typedCore.endIndex
            changed = true
        }
        guard changed else { return nil }
        corrected += sentence[cursor...]

        let flags = flagSpans.map { span -> SentenceFlag in
            let start = corrected.index(corrected.startIndex, offsetBy: span.start)
            let end = corrected.index(start, offsetBy: span.typed.count)
            return SentenceFlag(range: start..<end, typed: span.typed, options: [span.option])
        }
        return LocalProofreadResult(original: sentence, autoCorrected: corrected, flags: flags)
    }

    /// Every word the model would change, with how sure it was and what the gate did about it:
    /// the same judgment `result` acts on, kept for the training record. It includes the words the
    /// model was not sure enough of to mention, which is what a bar set too high or too low shows
    /// up in. Empty when the answer cannot be lined up with the sentence.
    static func judgments(
        typed sentence: String,
        output: SentenceModelOutput,
        bars: Bars = Bars(),
        isKnownWord: (String) -> Bool,
        words: WordChecks? = nil
    ) -> [SentencePassWord] {
        let typedWords = SentenceModelDecoder.words(in: sentence)
        guard typedWords.count == output.words.count else { return [] }
        return zip(typedWords, output.words).compactMap { typed, written in
            change(typed: typed, written: written, bars: bars, isKnownWord: isKnownWord, words: words).map {
                SentencePassWord(
                    typed: String($0.typedCore), written: String($0.writtenCore),
                    probability: written.probability, action: $0.action.rawValue
                )
            }
        }
    }

    /// What the model's probability for a changed word allows.
    private enum ChangeAction: String {
        /// Sure enough to type in place.
        case fixed
        /// Sure enough to ask about on the review card.
        case asked
        /// Not sure enough to mention.
        case left
    }

    /// One word the model wrote differently.
    private struct Change {
        let typedCore: Substring
        let writtenCore: Substring
        let action: ChangeAction
    }

    /// Nil when the word is unchanged, or changed in its punctuation and not its letters.
    private static func change(
        typed: Substring, written: SentenceModelOutput.Word, bars: Bars,
        isKnownWord: (String) -> Bool, words: WordChecks?
    ) -> Change? {
        guard typed != written.text else { return nil }
        let typedCore = core(of: typed)
        let writtenCore = core(of: written.text[...])
        guard !typedCore.isEmpty, !writtenCore.isEmpty, typedCore != writtenCore,
              typed[..<typedCore.startIndex] == written.text[..<writtenCore.startIndex],
              typed[typedCore.endIndex...] == written.text[writtenCore.endIndex...] else { return nil }
        if words?.isWritersOwn(String(typedCore)) == true {
            return Change(typedCore: typedCore, writtenCore: writtenCore, action: .left)
        }
        let applyBar = isKnownWord(String(typedCore)) ? bars.applyKnownWord : bars.applyMisspelling
        // Without the stricter check, a known word is the best there is to ask for.
        let isTypeable = words.map { $0.isInDictionary(String(writtenCore)) } ?? isKnownWord(String(writtenCore))
        let isSureEnough = written.probability >= applyBar && isTypeable
        let action: ChangeAction = isSureEnough ? .fixed : written.probability >= bars.suggest ? .asked : .left
        return Change(typedCore: typedCore, writtenCore: writtenCore, action: action)
    }

    /// A word left for review: where it starts in the corrected sentence (in characters; string
    /// indices are only valid once the sentence is complete), what was typed, and the model's word.
    private struct FlagSpan {
        let start: Int
        let typed: String
        let option: String
    }

    /// The word without the punctuation around it.
    private static func core(of word: Substring) -> Substring {
        var core = word
        while let first = core.first, !first.isLetter, !first.isNumber { core = core.dropFirst() }
        while let last = core.last, !last.isLetter, !last.isNumber { core = core.dropLast() }
        return core
    }
}
