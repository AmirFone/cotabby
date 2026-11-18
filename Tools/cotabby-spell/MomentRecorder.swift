import Foundation

/// Writes down, for every moment of a simulated typing run, the words the strip chose between and
/// everything known about each of them (`TYPING_MOMENTS=<file>` with `--typing --lm … --adaptive`).
///
/// Why: the language model is the slow part of a run (minutes per test set), and what is being
/// tuned is not the model but how its answer is combined with what the writer has typed before.
/// With the moments on disk, `Tools/prediction/lab/lab.py` tries another way of ordering the same
/// candidates in seconds, so dozens of ideas can be compared on many writers, and the ones worth
/// building are known before any Swift is written.
///
/// One JSON object per line:
///   i   which text of the run this is (0, 1, 2 …); learning happens after each text
///   L   letters of the word typed so far
///   t   the word the writer goes on to type
///   p   the letters typed, as the predictor reads them
///   k   the word before (as the tables key it), "" at the start
///   n   how many words the writer has typed in earlier texts
///   T   how often the writer has written the last one, two and three words before, in earlier texts
///   h   the strip's five words as the app would show them now
///   c   the candidates, each [word, s, s0, lm, own, c1, c2, c3, nt, last, f]:
///         s    the app's score before the writer's word counts are mixed in (null: not a candidate)
///         s0   the same with nothing learned (null: only what was learned makes it a candidate)
///         lm   the language model's log-probability of the word here (null: not in its dictionary)
///         own  times the writer typed the word in earlier texts
///         c1…  times they typed it after the last one, two and three words
///         nt   in how many earlier texts it appeared; last: how many texts ago (-1: never)
///         f    its count in the frequency dictionary (0: not in it)
/// The word typed is always among the candidates, also when the app did not consider it, so that
/// "it was never a candidate" can be told from "it was ranked too low".
@MainActor
final class MomentRecorder {
    private let file: FileHandle
    private let unlearned: NextWordPredictor.Sources
    private let phrases: PersonalPhraseModel?
    private let frequencies: [String: Int]
    private var textIndex = 0
    /// Per word: the texts it appeared in so far, and the last of them.
    private var spread: [String: (texts: Int, last: Int)] = [:]
    private var wordsTyped = 0

    static let candidatesKept = 25
    static let ownWordsKept = 40

    static func fromEnvironment(
        unlearned: NextWordPredictor.Sources, phrases: PersonalPhraseModel?, frequencies: URL
    ) -> MomentRecorder? {
        guard let path = ProcessInfo.processInfo.environment["TYPING_MOMENTS"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let file = FileHandle(forWritingAtPath: path) else { return nil }
        var counts: [String: Int] = [:]
        for line in ((try? String(contentsOf: frequencies, encoding: .utf8)) ?? "").split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, let count = Int(parts[1]) { counts[String(parts[0])] = count }
        }
        return MomentRecorder(file: file, unlearned: unlearned, phrases: phrases, frequencies: counts)
    }

    private init(file: FileHandle, unlearned: NextWordPredictor.Sources, phrases: PersonalPhraseModel?, frequencies: [String: Int]) {
        self.file = file
        self.unlearned = unlearned
        self.phrases = phrases
        self.frequencies = frequencies
    }

    func record(textBefore: String, letters: Int, target: String, shown: [String], sources: NextWordPredictor.Sources) {
        guard let learned = NextWordPredictor.candidates(textBefore: textBefore, sources: sources) else { return }
        let plain = NextWordPredictor.candidates(textBefore: textBefore, sources: unlearned)?.scores ?? [:]
        let model = sources.languageModel(textBefore)
        let context = learned.context
        let after = (1...NextWordPredictor.maximumContext).map { length in
            context.count >= length ? phrases?.nextWords(after: Array(context.suffix(length))) : nil
        }
        let own = learned.prefix.isEmpty ? nil : phrases?.words(startingWith: learned.prefix)

        var words = Set(learned.scores.sorted { $0.value > $1.value }.prefix(Self.candidatesKept).map(\.key))
        words.formUnion(plain.sorted { $0.value > $1.value }.prefix(Self.candidatesKept).map(\.key))
        var mine: [String: Int] = own?.counts ?? [:]
        for found in after {
            for (word, count) in found?.counts ?? [:] where word.hasPrefix(learned.prefix) && !word.hasPrefix("<") {
                // Weighted above any single-word count so the words that followed these words are kept.
                mine[word, default: 0] += count * 1_000
            }
        }
        words.formUnion(mine.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(Self.ownWordsKept).map(\.key))
        words.remove(learned.prefix)
        words.insert(target)

        func number(_ value: Double?) -> Any { value.map { ($0 * 1_000).rounded() / 1_000 } ?? NSNull() }
        let rows: [[Any]] = words.sorted().map { word in
            let seen = spread[word]
            return [
                word, number(learned.scores[word]), number(plain[word]),
                number(model?.logProbability(of: word).map(Double.init).flatMap { $0 > -.infinity ? $0 : nil }),
                own?.counts[word] ?? 0,
                after[0]?.counts[word] ?? 0, after[1]?.counts[word] ?? 0, after[2]?.counts[word] ?? 0,
                seen?.texts ?? 0, seen.map { textIndex - $0.last } ?? -1, frequencies[word] ?? 0
            ]
        }
        let moment: [String: Any] = [
            "i": textIndex, "L": letters, "t": target, "p": learned.prefix, "k": context.last ?? "",
            "n": wordsTyped,
            "T": after.map { $0?.total ?? 0 }, "h": shown, "c": rows
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: moment, options: [.sortedKeys]) else { return }
        file.write(data)
        file.write(Data("\n".utf8))
    }

    /// The text just typed is now part of what the writer has written before.
    func finished(text: String) {
        let words = NextWordPredictor.tokens(in: Substring(text)).map { $0.lowercased() }
        for word in Set(words) {
            spread[word] = ((spread[word]?.texts ?? 0) + 1, textIndex)
        }
        wordsTyped += words.count
        textIndex += 1
    }
}
