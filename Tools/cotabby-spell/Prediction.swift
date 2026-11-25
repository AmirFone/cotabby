import Foundation

/// Next-word prediction modes for cotabby-spell, running the app's `NextWordPredictor` on the
/// bundled model:
///
///   cotabby-spell --predict "I would like to |"     the list the app would show
///   cotabby-spell --ksr heldout.txt [3000]          top-1 / top-5 and keystroke savings
///   cotabby-spell --typing texts.txt|passages.jsonl [n] [--lm model.gguf] [--verbs verb_forms.txt]
///         how often the first suggestion is the word, by letters typed, and the tense test. The
///         text is typed as written, punctuation and earlier sentences included, so the language
///         model (`--lm`) reads what it would read in the app.
///
/// Keystroke savings simulates a writer who types letter by letter and picks the word with one key
/// as soon as it is listed. Same method as `Tools/ngram/evaluate.py`, so the numbers are comparable.
@MainActor
struct PredictionHarness {
    let sources: NextWordPredictor.Sources
    /// With `--adaptive`, every simulated sentence is learned after it is typed, like the app does.
    let phrases: PersonalPhraseModel?
    let hardWords: Set<String>
    /// The word language model, run in step with the simulated typing (`--lm`); nil without it.
    let languageModel: SynchronousLanguageModel?
    /// Writes every typing moment down for `Tools/prediction/lab` (TYPING_MOMENTS); nil otherwise.
    var recorder: MomentRecorder?
    /// Which words of a typed text `--typing --adaptive` learns (ADAPT_LEARN).
    let learning: SimulatedLearning

    static func make(
        resourceRoot: URL,
        corrector: SymSpellCorrector,
        adaptive: Bool = false,
        languageModelPath: String? = nil,
        americanSpellings: AmericanSpellings? = nil
    ) -> PredictionHarness? {
        let url = resourceRoot.appendingPathComponent("next_word_model_en.bin")
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let model = NextWordModel(data: data) else { return nil }
        let phrases = adaptive ? PersonalPhraseModel(fileURL: nil) : nil
        var languageModel: SynchronousLanguageModel?
        if let languageModelPath {
            // NO_SUPPLEMENT=1 leaves out prediction_words_en.txt, to measure what it adds.
            let lists = ["frequency_dictionary_en_82_765.txt"] + (noSupplement ? [] : ["prediction_words_en.txt"])
                + (noTechnical ? [] : ["\(TechnicalVocabulary.stripListName).txt"])
            guard let core = WordLanguageModelCore(
                modelURL: URL(fileURLWithPath: languageModelPath),
                wordListURLs: lists.map(resourceRoot.appendingPathComponent),
                // NO_BRANCH=1 reads the exact pass one piece at a time, to measure what one pass saves.
                readsPiecesInOnePass: ProcessInfo.processInfo.environment["NO_BRANCH"] == nil
            ) else {
                print("could not load the language model at \(languageModelPath)")
                return nil
            }
            languageModel = SynchronousLanguageModel(core: core)
        }
        let technicalURL = resourceRoot.appendingPathComponent("\(TechnicalVocabulary.stripListName).txt")
        let supplement = Set(WordLanguageModelCore.entries(
            in: (noSupplement ? [] : [resourceRoot.appendingPathComponent("prediction_words_en.txt")]) + (noTechnical ? [] : [technicalURL])
        ).map(\.word))
        let capitals = noTechnical ? [:] : TechnicalVocabulary.capitals(
            inStripList: (try? String(contentsOf: technicalURL, encoding: .utf8)) ?? ""
        )
        let hardWords = Set(((try? String(contentsOf: resourceRoot.appendingPathComponent("commonly_misspelled_en.txt"), encoding: .utf8)) ?? "")
            .split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init))
        func sources(learning phrases: PersonalPhraseModel?) -> NextWordPredictor.Sources {
            NextWordPredictor.Sources(
                model: model,
                completions: { corrector.completions(of: $0, limit: $1) },
                personal: { phrases?.nextWords(after: $0) },
                personalWords: { phrases?.words(startingWith: $0) },
                fuzzyCompletions: { prefix, limit in
                    guard ProcessInfo.processInfo.environment["NO_FUZZY"] == nil else { return [] }
                    return corrector.fuzzyCompletions(of: prefix, limit: limit)
                },
                nearMisses: { prefix, limit in
                    let environment = ProcessInfo.processInfo.environment
                    guard environment["NO_FUZZY"] == nil, environment["NO_NEAR_MISSES"] == nil else { return [] }
                    return corrector.nearMissCompletions(of: prefix, limit: limit)
                },
                isHardToSpell: { ProcessInfo.processInfo.environment["NO_HARD"] == nil && hardWords.contains($0) },
                languageModel: { languageModel?.scores(forTextBefore: $0) },
                isKnownWord: { supplement.contains($0) },
                usualCapitals: { capitals[$0] },
                americanSpellings: americanSpellings,
                personalTotal: { phrases?.totalWords ?? 0 },
                personalSpread: { phrases?.spread(of: $0) ?? 0 },
                generalCount: { corrector.count(of: $0) },
                mix: mixFromEnvironment()
            )
        }
        let recorder = MomentRecorder.fromEnvironment(
            unlearned: sources(learning: nil), phrases: phrases,
            frequencies: resourceRoot.appendingPathComponent("frequency_dictionary_en_82_765.txt")
        )
        return PredictionHarness(
            sources: sources(learning: phrases), phrases: phrases, hardWords: hardWords, languageModel: languageModel,
            recorder: recorder,
            learning: SimulatedLearning(isDictionaryWord: { corrector.isDictionaryWord($0) }, isListedWord: { supplement.contains($0) })
        )
    }

    private static let noSupplement = ProcessInfo.processInfo.environment["NO_SUPPLEMENT"] != nil
    /// NO_TECHNICAL=1 leaves out the software-engineering terms, to measure what they change.
    private static let noTechnical = ProcessInfo.processInfo.environment["NO_TECHNICAL"] != nil

    /// MIX_TABLE_WEIGHT, MIX_SLIP_PENALTY, MIX_CANDIDATES, MIX_HABITS…: try other numbers without rebuilding.
    private static func mixFromEnvironment() -> NextWordPredictor.LanguageModelMix {
        let environment = ProcessInfo.processInfo.environment
        var mix = NextWordPredictor.LanguageModelMix()
        if let value = environment["MIX_TABLE_WEIGHT"].flatMap(Double.init) { mix.tableWeight = value }
        if let value = environment["MIX_SLIP_PENALTY"].flatMap(Double.init) { mix.slipPenalty = value }
        if let value = environment["MIX_CANDIDATES"].flatMap(Int.init) { mix.modelCandidates = value }
        // MIX_HABITS=0: the order without what the writer's history adds, to measure what it adds.
        if environment["MIX_HABITS"] == "0" { mix.habits = .off }
        if let value = environment["MIX_RATE_WEIGHT"].flatMap(Double.init) { mix.habits.rateWeight = value }
        if let value = environment["MIX_PHRASE_WEIGHT"].flatMap(Double.init) { mix.habits.phraseWeight = value }
        if let value = environment["MIX_LONG_PHRASE_WEIGHT"].flatMap(Double.init) { mix.habits.longPhraseWeight = value }
        return mix
    }

    func show(_ input: CaretText) {
        let start = DispatchTime.now().uptimeNanoseconds
        let prediction = NextWordPredictor.predict(textBefore: input.before, sources: sources)
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let words = prediction.map { $0.words.joined(separator: " · ") } ?? "(nothing)"
        print("\(input.display)  →  \(words)   [\(String(format: "%.2f", milliseconds)) ms]")
    }

    func keystrokeSavings(path: String, limit: Int) -> Int32 {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("cannot read \(path)")
            return 2
        }
        var generator = SeededGenerator(seed: 7)
        var sentences = contents.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        sentences.shuffle(using: &generator)
        sentences = Array(sentences.prefix(limit))
        var tally = Tally()
        let start = DispatchTime.now().uptimeNanoseconds
        var firstHalf = Tally()
        for (index, sentence) in sentences.enumerated() {
            simulate(sentence, into: &tally)
            phrases?.learn(sentence: sentence)
            if index + 1 == sentences.count / 2 { firstHalf = tally }
        }
        if phrases != nil {
            let secondKeys = tally.keys - firstHalf.keys
            let secondCharacters = tally.characters - firstHalf.characters
            print(String(
                format: "adaptive: first half savings %.1f%%, second half %.1f%%",
                100 * (1 - Double(firstHalf.keys) / Double(max(firstHalf.characters, 1))),
                100 * (1 - Double(secondKeys) / Double(max(secondCharacters, 1)))
            ))
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        print(String(format: "hard-to-spell words: %d, keys saved on them %.1f%%", tally.hardWords,
                     100 * (1 - tally.hardKeys / Double(max(tally.hardCharacters, 1)))))
        print(String(
            format: "sentences=%d next-word top1=%.1f%% top5=%.1f%% keystroke savings=%.1f%% (%.3f ms per prediction)",
            sentences.count,
            100 * Double(tally.top1) / Double(max(tally.predictions, 1)),
            100 * Double(tally.top5) / Double(max(tally.predictions, 1)),
            100 * (1 - tally.keys / Double(max(tally.characters, 1))),
            1000 * seconds / Double(max(tally.calls, 1))
        ))
        func row(_ hits: [Int]) -> String {
            zip(hits, tally.momentsByLetters).map { String(format: "%5.1f%%", 100 * Double($0) / Double(max($1, 1))) }
                .joined(separator: " ")
        }
        let moments = tally.momentsByLetters.reduce(0, +)
        print("letters typed:           " + (0...Self.lettersTracked).map { String(format: "%6d", $0) }.joined())
        print("first suggestion right:  " + row(tally.firstRightByLetters)
              + String(format: "   all moments %.1f%%", 100 * Double(tally.firstRightByLetters.reduce(0, +)) / Double(max(moments, 1))))
        print("in the list:             " + row(tally.listedByLetters)
              + String(format: "   all moments %.1f%%", 100 * Double(tally.listedByLetters.reduce(0, +)) / Double(max(moments, 1))))
        return 0
    }

    private struct Tally {
        var top1 = 0
        var top5 = 0
        var predictions = 0
        var keys = 0.0
        var picks = 0
        var hardWords = 0
        var hardPicked = 0
        var hardKeys = 0.0
        var hardCharacters = 0
        var characters = 0
        var calls = 0
        /// First suggestion right / moments seen, by how many letters of the word were typed
        /// (index 0 = before any letter). Counted at every letter, whether or not a writer would
        /// already have picked the word, so it answers "how often is the first word the right one".
        var firstRightByLetters = [Int](repeating: 0, count: PredictionHarness.lettersTracked + 1)
        var listedByLetters = [Int](repeating: 0, count: PredictionHarness.lettersTracked + 1)
        var momentsByLetters = [Int](repeating: 0, count: PredictionHarness.lettersTracked + 1)
    }

    static let lettersTracked = 6

    private func simulate(_ sentence: String, into tally: inout Tally) {
        let words = NextWordPredictor.tokens(in: Substring(sentence))
        let raws = NextWordPredictor.contextTokens(of: sentence).dropFirst()
        var written = ""
        for (word, token) in zip(words, raws) {
            let target = word.lowercased()
            tally.characters += target.count + 1
            let keysBefore = tally.keys
            if hardWords.contains(target) { tally.hardWords += 1 }
            if !token.hasPrefix("<") {
                let listed = predict(written, &tally)
                tally.predictions += 1
                if listed.first == target { tally.top1 += 1 }
                if listed.contains(target) { tally.top5 += 1 }
                for letters in 0...min(word.count - 1, Self.lettersTracked) {
                    let shown = letters == 0 ? listed : predict(written + word.prefix(letters), &tally)
                    tally.momentsByLetters[letters] += 1
                    if shown.first == target { tally.firstRightByLetters[letters] += 1 }
                    if shown.contains(target) { tally.listedByLetters[letters] += 1 }
                }
            }
            var typed = ""
            var picked = false
            for character in word {
                let listed = predict(written + typed, &tally)
                // A rational writer picks only when it costs fewer keys than finishing the word and
                // its space by hand; the cost of slot i depends on the UI being modelled.
                if let slot = listed.firstIndex(of: target),
                   Self.pickCost(slot: slot) < Double(word.count - typed.count + 1) {
                    tally.keys += Self.pickCost(slot: slot)
                    tally.picks += 1
                    if hardWords.contains(target) { tally.hardPicked += 1 }
                    picked = true
                    break
                }
                typed.append(character)
                tally.keys += 1
            }
            if !picked { tally.keys += 1 }
            if hardWords.contains(target) {
                tally.hardKeys += tally.keys - keysBefore
                tally.hardCharacters += target.count + 1
            }
            written += word + " "
        }
    }

    /// Keys to take the word in slot `slot` (0-based). `UI_COST` picks the model:
    /// `tab` (default, the shipped UI: Tab per slot then Return), `one` (any slot costs one key),
    /// `chord` (Option+digit, counted as 1.5 keys; Tab+Return when cheaper).
    static let costModel = ProcessInfo.processInfo.environment["UI_COST"] ?? "tab"

    static func pickCost(slot: Int) -> Double {
        switch costModel {
        case "one": return 1
        case "chord": return min(Double(slot + 2), 1.5)
        // Word 1 pre-selected: one key takes it, each arrow press moves one slot.
        case "arrows": return Double(slot + 1)
        // One key takes word 1; Option+digit takes any other.
        case "top-chord": return slot == 0 ? 1 : 1.5
        // Only word 1 is ever taken, with one key (how much the rest of the strip is worth).
        case "top-only": return slot == 0 ? 1 : 99
        default: return Double(slot + 2)
        }
    }

    private func predict(_ text: String, _ tally: inout Tally) -> [String] {
        tally.calls += 1
        return NextWordPredictor.predict(textBefore: text, sources: sources)?.words.map { $0.lowercased() } ?? []
    }
}

/// What a simulated writer's finished sentences teach the strip, in one of three ways, to put a
/// number on the rule the app uses (ADAPT_LEARN):
///   all       every lowercase word, the most there is to learn (the default, an upper bound)
///   word      what the app learns: each word the dictionary or a bundled list has, and a word
///             neither has from its second text on (standing in for the writer's vocabulary,
///             which in the app also needs the system spelling checker to accept the word)
///   sentence  what the app learned before: only sentences made entirely of dictionary words
@MainActor
final class SimulatedLearning {
    private let mode = ProcessInfo.processInfo.environment["ADAPT_LEARN"] ?? "all"
    private let isDictionaryWord: (String) -> Bool
    private let isListedWord: (String) -> Bool
    /// Texts each unlisted word has appeared in so far.
    private var unlistedUses: [String: Int] = [:]
    private var textsLearned = 0

    init(isDictionaryWord: @escaping (String) -> Bool, isListedWord: @escaping (String) -> Bool) {
        self.isDictionaryWord = isDictionaryWord
        self.isListedWord = isListedWord
    }

    /// Learns the sentences of one typed text. Each text is its own sitting, an hour after the one
    /// before: the test writers' texts are spread over three weeks, not typed in one go.
    func learn(_ sentences: [String], into phrases: PersonalPhraseModel) {
        textsLearned += 1
        let now = Date(timeIntervalSince1970: Double(textsLearned) * 3_600)
        switch mode {
        case "sentence":
            phrases.learn(text: sentences.filter { sentence in
                let tokens = NextWordPredictor.contextTokens(of: sentence).dropFirst()
                return tokens.count >= 2 && tokens.allSatisfy { $0.hasPrefix("<") || isDictionaryWord($0) }
            }, at: now)
        case "word":
            for word in Set(sentences.flatMap { NextWordPredictor.tokens(in: Substring($0)) }.map { $0.lowercased() })
            where !isDictionaryWord(word) && !isListedWord(word) {
                unlistedUses[word, default: 0] += 1
            }
            let uses = unlistedUses
            phrases.learn(text: sentences, vouching: PersonalPhraseModel.Vouching(
                isWord: { [isDictionaryWord, isListedWord] in isDictionaryWord($0) || isListedWord($0) || uses[$0, default: 0] >= 2 },
                isOwnName: { [isListedWord] in isListedWord($0) || uses[$0, default: 0] >= 2 }
            ), at: now)
        default:
            phrases.learn(text: sentences, at: now)
        }
    }
}

/// The app asks the language model in the background and redraws when the answer arrives; the
/// harness simply waits for it, which scores what the writer sees once the answer is there.
@MainActor
final class SynchronousLanguageModel {
    private let core: WordLanguageModelCore
    private var latest: LanguageModelScores?
    private(set) var passMilliseconds: [Double] = []

    init(core: WordLanguageModelCore) {
        self.core = core
    }

    /// LM_REACH_CHARS and LM_REACH_STEP: how far back the model reads, to measure other reaches.
    private static let reach: LanguageModelContext.Reach = {
        let environment = ProcessInfo.processInfo.environment
        var reach = LanguageModelContext.Reach.standard
        if let value = environment["LM_REACH_CHARS"].flatMap(Int.init) { reach.maximumCharacters = value }
        if let value = environment["LM_REACH_STEP"].flatMap(Int.init) { reach.step = value }
        return reach
    }()

    func scores(forTextBefore text: String) -> LanguageModelScores? {
        guard let context = LanguageModelContext.make(textBefore: text, reach: Self.reach) else { return nil }
        if latest?.key != context.key {
            let started = DispatchTime.now().uptimeNanoseconds
            latest = core.scores(for: context.key)
            passMilliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        // NO_REFINE=1 scores the first estimate alone, to measure what the exact pass adds.
        // The app asks again after each refinement until nothing is left to refine; so does this.
        var rounds = 0
        while let current = latest, !Self.skipsRefinement, rounds < Self.maximumRounds {
            let started = DispatchTime.now().uptimeNanoseconds
            guard let refined = core.refine(current, forPrefix: context.prefix.lowercased()) else { break }
            latest = refined
            rounds += 1
            refineMilliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        roundsPerMoment[rounds, default: 0] += 1
        return latest
    }

    /// How many exact rounds each typing moment took, to check that they settle (REFINE_ROUNDS sets
    /// the cap; the app has none and stops when nothing is left to refine).
    private(set) var roundsPerMoment: [Int: Int] = [:]
    private static let maximumRounds = ProcessInfo.processInfo.environment["REFINE_ROUNDS"].flatMap(Int.init) ?? 4

    private(set) var refineMilliseconds: [Double] = []
    private static let skipsRefinement = ProcessInfo.processInfo.environment["NO_REFINE"] != nil
}

extension PredictionHarness {
    /// One text to type, with the label its results are also grouped under (a passage's tense).
    private struct TypedText {
        let text: String
        let group: String?
        /// Words of the text with a misspelling a writer might type instead (`typed` in the
        /// passages file): the text before the word, the misspelling, and the word.
        var slips: [(before: String, wrong: String, right: String)] = []
    }

    private struct TypingTally {
        var firstRight = [Int](repeating: 0, count: PredictionHarness.lettersTracked + 1)
        var listed = [Int](repeating: 0, count: PredictionHarness.lettersTracked + 1)
        var moments = [Int](repeating: 0, count: PredictionHarness.lettersTracked + 1)
        /// Keys pressed by a writer who takes the first suggestion (one key) as soon as it is right.
        var keys = 0
        var characters = 0
        var words = 0
        /// Tense test: verb moments, right form listed before the other forms, right form first of
        /// all, and no form of the verb listed at all.
        var verbMoments = 0
        var verbFormFirst = 0
        var verbTop = 0
        var verbUnlisted = 0
        var predictions = 0
        /// Typing a misspelling: moments after the slip (the letters no longer start the word), and
        /// how often the word meant was first, or listed.
        var slipMoments = 0
        var slipFirst = 0
        var slipListed = 0
        /// Names (capitalized inside a sentence) the text has already used, typed again: moments
        /// with one or more letters typed, how often the name was first, and first with its capital.
        var nameMoments = 0
        var nameFirst = 0
        var nameFirstAsWritten = 0
    }

    /// `--typing`: types every text as written and reports how often the first suggestion is the
    /// word at each number of letters typed, and how often the right form of a verb is offered
    /// before its other forms once the letters they share are typed.
    func typingReport(
        path: String, limit: Int, verbFormsPath: String?, decide: ((String) -> TypoGateDecision)? = nil
    ) -> Int32 {
        guard let texts = Self.loadTexts(path: path, limit: limit) else {
            print("cannot read \(path)")
            return 2
        }
        let families = verbFormsPath.map(Self.loadVerbFamilies) ?? [:]
        var total = TypingTally()
        var spelling = SpellingTally()
        var groups: [String: TypingTally] = [:]
        let started = DispatchTime.now().uptimeNanoseconds
        // LM_HISTORY=<characters>: each text is typed below the end of the texts before it, as if
        // the model were also shown what the writer wrote last, to measure what that is worth.
        let historyLength = ProcessInfo.processInfo.environment["LM_HISTORY"].flatMap(Int.init) ?? 0
        // LM_HISTORY_FROM=<texts>: the texts shown are another writer's, the control that tells
        // "the model knows this writer" from "the model has read something".
        let strangers = ProcessInfo.processInfo.environment["LM_HISTORY_FROM"]
            .flatMap { Self.loadTexts(path: $0, limit: limit) }?.map(\.text)
        var earlier: [String] = []
        for (position, item) in texts.enumerated() {
            var tally = TypingTally()
            let shown = strangers.map { Array($0.prefix(position)) } ?? earlier
            let history = Self.history(of: shown, characters: historyLength)
            simulateTyping(history + item.text, from: history.count, families: families, into: &tally)
            for slip in item.slips { typeMisspelling(slip.wrong, meaning: slip.right, after: history + slip.before, into: &tally) }
            earlier.append(item.text)
            if let decide {
                for slip in item.slips { finishMisspelling(slip, decide: decide, into: &spelling) }
            }
            // With `--adaptive` the text is learned after it is typed, like the app does.
            if let phrases {
                learning.learn(item.text.split(whereSeparator: { ".!?\n".contains($0) }).map(String.init), into: phrases)
            }
            recorder?.finished(text: item.text)
            Self.add(tally, to: &total)
            if let group = item.group { Self.add(tally, to: &groups[group, default: TypingTally()]) }
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000

        print("\(texts.count) texts, \(total.words) words" + (languageModel == nil ? ", table only" : ", with the language model"))
        print("letters typed:            " + (0...Self.lettersTracked).map { String(format: "%6d", $0) }.joined(separator: " "))
        func row(_ hits: [Int], _ tally: TypingTally) -> String {
            zip(hits, tally.moments).map { String(format: "%5.1f%%", 100 * Double($0) / Double(max($1, 1))) }.joined(separator: " ")
                + String(format: "   all moments %.1f%%", 100 * Double(hits.reduce(0, +)) / Double(max(tally.moments.reduce(0, +), 1)))
        }
        print("first suggestion right:   " + row(total.firstRight, total))
        print("in the list of five:      " + row(total.listed, total))
        print(String(format: "keys saved taking only the first suggestion: %.1f%%",
                     100 * (1 - Double(total.keys) / Double(max(total.characters, 1)))))
        if total.verbMoments > 0 {
            print(Self.tenseLine("tense test", total))
        }
        if total.nameMoments > 0 {
            print(String(format: "a name the text already used, typed again: first %.1f%%, first and capitalized as written %.1f%% (%d moments, not in the rows above)",
                         100 * Double(total.nameFirst) / Double(total.nameMoments),
                         100 * Double(total.nameFirstAsWritten) / Double(total.nameMoments), total.nameMoments))
        }
        if total.slipMoments > 0 {
            print(String(format: "typing a misspelling, after the slip: word meant is first %.1f%%, listed %.1f%% (%d moments)",
                         100 * Double(total.slipFirst) / Double(total.slipMoments),
                         100 * Double(total.slipListed) / Double(total.slipMoments), total.slipMoments))
        }
        for name in groups.keys.sorted() {
            guard let tally = groups[name] else { continue }
            print(String(format: "  %-8@ first right, all moments %.1f%%", name as NSString,
                         100 * Double(tally.firstRight.reduce(0, +)) / Double(max(tally.moments.reduce(0, +), 1)))
                  + (tally.verbMoments > 0 ? "   " + Self.tenseLine("tense", tally) : ""))
        }
        if spelling.words > 0 {
            func share(_ count: Int) -> String { String(format: "%.1f%%", 100 * Double(count) / Double(spelling.words)) }
            print("finished misspellings (\(spelling.words)): fixed unasked \(share(spelling.fixedRight)) right, "
                  + "\(share(spelling.fixedWrong)) wrong; offered with the word first \(share(spelling.offeredFirst)), "
                  + "offered lower \(share(spelling.offeredLower)); not caught \(share(spelling.missed))")
            if languageModel != nil {
                print("  if the language model ordered what is offered: the word first \(share(spelling.offeredFirstByModel))")
            }
        }
        if let passes = languageModel?.passMilliseconds.sorted(), !passes.isEmpty {
            print(String(format: "language model: %d passes, median %.1f ms, 90%% within %.1f ms, slowest %.1f ms",
                         passes.count, passes[passes.count / 2], passes[passes.count * 9 / 10], passes[passes.count - 1]))
        }
        if let refinements = languageModel?.refineMilliseconds.sorted(), !refinements.isEmpty {
            print(String(format: "exact passes: %d (%.2f per word), median %.1f ms, 90%% within %.1f ms",
                         refinements.count, Double(refinements.count) / Double(max(total.words, 1)),
                         refinements[refinements.count / 2], refinements[refinements.count * 9 / 10]))
        }
        if let rounds = languageModel?.roundsPerMoment, ProcessInfo.processInfo.environment["REFINE_ROUNDS"] != nil {
            print("exact rounds per typing moment: " + rounds.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
        }
        print(String(format: "%.2f ms per prediction overall", 1000 * seconds / Double(max(total.predictions, 1))))
        // The raw counts on one line, so runs over parts of a file (made at the same time) can be
        // added up exactly instead of averaging percentages.
        let counts: [String: Any] = [
            "firstRight": total.firstRight, "listed": total.listed, "moments": total.moments,
            "keys": total.keys, "characters": total.characters, "words": total.words,
            "verbMoments": total.verbMoments, "verbFormFirst": total.verbFormFirst, "verbTop": total.verbTop,
            "slipMoments": total.slipMoments, "slipFirst": total.slipFirst, "slipListed": total.slipListed,
            "nameMoments": total.nameMoments, "nameFirst": total.nameFirst, "nameFirstAsWritten": total.nameFirstAsWritten,
            "misspellings": spelling.words, "fixedRight": spelling.fixedRight, "fixedWrong": spelling.fixedWrong,
            "offeredFirst": spelling.offeredFirst, "offeredLower": spelling.offeredLower, "notCaught": spelling.missed
        ]
        if let data = try? JSONSerialization.data(withJSONObject: counts, options: [.sortedKeys]) {
            print("counts " + String(decoding: data, as: UTF8.self))
        }
        return 0
    }

    private static func tenseLine(_ label: String, _ tally: TypingTally) -> String {
        String(format: "%@: right verb form before the others %.1f%%, first of all %.1f%%, no form listed %.1f%% (%d verb moments)",
               label,
               100 * Double(tally.verbFormFirst) / Double(max(tally.verbMoments, 1)),
               100 * Double(tally.verbTop) / Double(max(tally.verbMoments, 1)),
               100 * Double(tally.verbUnlisted) / Double(max(tally.verbMoments, 1)),
               tally.verbMoments)
    }

    private static func add(_ tally: TypingTally, to total: inout TypingTally) {
        for index in 0...lettersTracked {
            total.firstRight[index] += tally.firstRight[index]
            total.listed[index] += tally.listed[index]
            total.moments[index] += tally.moments[index]
        }
        total.keys += tally.keys
        total.characters += tally.characters
        total.words += tally.words
        total.verbMoments += tally.verbMoments
        total.verbFormFirst += tally.verbFormFirst
        total.verbTop += tally.verbTop
        total.verbUnlisted += tally.verbUnlisted
        total.predictions += tally.predictions
        total.slipMoments += tally.slipMoments
        total.slipFirst += tally.slipFirst
        total.slipListed += tally.slipListed
        total.nameMoments += tally.nameMoments
        total.nameFirst += tally.nameFirst
        total.nameFirstAsWritten += tally.nameFirstAsWritten
    }

    /// The latest whole texts that fit in `characters`, oldest first, each on its own line.
    private static func history(of texts: [String], characters: Int) -> String {
        var kept: [String] = []
        var length = 0
        for text in texts.reversed() {
            guard length + text.count + 1 <= characters else { break }
            kept.append(text)
            length += text.count + 1
        }
        return kept.reversed().map { $0 + "\n" }.joined()
    }

    private func simulateTyping(_ text: String, from start: Int = 0, families: [String: [String]], into tally: inout TypingTally) {
        var index = text.index(text.startIndex, offsetBy: start)
        var startsSentence = true
        var namesSeen = Set<String>()
        while index < text.endIndex {
            let character = text[index]
            guard character.isASCII, character.isLetter || character.isNumber else {
                if ".!?\n".contains(character) { startsSentence = true }
                index = text.index(after: index)
                continue
            }
            // One word: letters with inner apostrophes, or a run of digits (the predictor's own rule).
            var end = index
            let isNumber = character.isNumber
            while end < text.endIndex {
                let next = text[end]
                if next.isASCII, isNumber ? next.isNumber : next.isLetter {
                    end = text.index(after: end)
                } else if !isNumber, next == "'", text.index(after: end) < text.endIndex,
                          text[text.index(after: end)].isASCII, text[text.index(after: end)].isLetter {
                    end = text.index(after: end)
                } else {
                    break
                }
            }
            let raw = String(text[index..<end])
            let isName = !startsSentence && raw.first?.isUppercase == true && raw != "I" && !raw.hasPrefix("I'")
            if !isNumber, !isName {
                type(raw, after: String(text[..<index]), families: startsSentence ? [:] : families, into: &tally)
            } else if isName, !raw.contains("'"), !namesSeen.insert(raw).inserted {
                typeNameAgain(raw, after: String(text[..<index]), into: &tally)
            }
            startsSentence = false
            index = end
        }
    }

    private func type(_ raw: String, after before: String, families: [String: [String]], into tally: inout TypingTally) {
        let target = raw.lowercased()
        tally.words += 1
        tally.characters += raw.count + 1
        var keys = raw.count + 1
        for letters in 0...min(raw.count - 1, Self.lettersTracked) {
            let shown = shownWords(before + raw.prefix(letters), &tally)
            recorder?.record(textBefore: before + raw.prefix(letters), letters: letters, target: target, shown: shown, sources: sources)
            tally.moments[letters] += 1
            if shown.first == target {
                tally.firstRight[letters] += 1
                keys = min(keys, letters + 1)
            } else if let misses = Self.missesFile {
                // TYPING_MISSES=<file>: every moment the first suggestion was wrong, for reading.
                let line = "\(letters)\t\(before.suffix(60).replacingOccurrences(of: "\n", with: " "))[\(raw.prefix(letters))]\t\(target)\t\(shown.joined(separator: " "))\n"
                misses.write(Data(line.utf8))
            }
            if shown.contains(target) { tally.listed[letters] += 1 }
        }
        tally.keys += keys

        guard let forms = families[target] else { return }
        let shared = forms.dropFirst().reduce(forms[0]) { String($0.commonPrefix(with: $1)) }
        let choices = Set(forms.filter { $0 != shared })
        guard choices.contains(target), choices.count >= 2 else { return }
        let shown = shownWords(before + raw.prefix(shared.count), &tally)
        tally.verbMoments += 1
        if shown.first == target { tally.verbTop += 1 }
        if let firstForm = shown.first(where: choices.contains) {
            if firstForm == target { tally.verbFormFirst += 1 }
        } else {
            tally.verbUnlisted += 1
        }
    }

    /// A name the text has used before, typed again: scored apart from the words, because a name
    /// the text never showed cannot be guessed and one it did show can.
    private func typeNameAgain(_ raw: String, after before: String, into tally: inout TypingTally) {
        guard raw.count >= 3 else { return }
        for letters in 1...min(raw.count - 1, Self.lettersTracked) {
            tally.predictions += 1
            let shown = NextWordPredictor.predict(textBefore: before + raw.prefix(letters), sources: sources)?.words ?? []
            tally.nameMoments += 1
            if shown.first?.lowercased() == raw.lowercased() { tally.nameFirst += 1 }
            if shown.first == raw { tally.nameFirstAsWritten += 1 }
        }
    }

    /// Types a misspelling letter by letter, stopping before its last letter (a finished word
    /// belongs to the spelling bar), and scores the moments where the slip has already happened.
    private func typeMisspelling(_ wrong: String, meaning right: String, after before: String, into tally: inout TypingTally) {
        let target = right.lowercased()
        guard wrong.count >= 4 else { return }
        for letters in 3..<wrong.count where !target.hasPrefix(wrong.prefix(letters).lowercased()) {
            let shown = shownWords(before + wrong.prefix(letters), &tally)
            tally.slipMoments += 1
            if shown.first == target { tally.slipFirst += 1 }
            if shown.contains(target) { tally.slipListed += 1 }
        }
    }

    /// What the spelling engine did with finished misspellings.
    private struct SpellingTally {
        var words = 0
        var fixedRight = 0
        var fixedWrong = 0
        var offeredFirst = 0
        var offeredLower = 0
        var missed = 0
        /// Offers where the candidate the language model finds likeliest here is the word.
        var offeredFirstByModel = 0
    }

    /// The whole misspelling and its space typed: what does the spelling engine do, and would the
    /// language model's order of the offered fixes be better than the engine's own?
    private func finishMisspelling(
        _ slip: (before: String, wrong: String, right: String),
        decide: (String) -> TypoGateDecision,
        into tally: inout SpellingTally
    ) {
        let target = slip.right.lowercased()
        tally.words += 1
        let candidates: [String]
        switch decide(slip.before + slip.wrong + " ") {
        case let .applyCorrection(_, corrected):
            if corrected.lowercased() == target { tally.fixedRight += 1 } else { tally.fixedWrong += 1 }
            return
        case let .offerCorrection(_, corrected):
            candidates = [corrected]
        case let .offerRankedCorrection(_, list), let .offerChoices(_, list), let .offerRealWordFix(_, list):
            candidates = list.map(\.term)
        case .proceed, .suppress:
            tally.missed += 1
            return
        }
        let terms = candidates.map { $0.lowercased() }
        if terms.first == target { tally.offeredFirst += 1 } else if terms.contains(target) { tally.offeredLower += 1 } else { tally.missed += 1 }
        if let scores = languageModel?.scores(forTextBefore: slip.before) {
            let likeliest = terms.max { (scores.logProbability(of: $0) ?? -.infinity) < (scores.logProbability(of: $1) ?? -.infinity) }
            if likeliest == target { tally.offeredFirstByModel += 1 }
        }
    }

    private static let missesFile: FileHandle? = ProcessInfo.processInfo.environment["TYPING_MISSES"].flatMap { path in
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }

    private func shownWords(_ text: String, _ tally: inout TypingTally) -> [String] {
        tally.predictions += 1
        return NextWordPredictor.predict(textBefore: text, sources: sources)?.words.map { $0.lowercased() } ?? []
    }

    /// One text per line (`.txt`, sampled like `--ksr`), or JSON Lines with a `text` and optionally
    /// a `tense` (`Tools/prediction/passages-*.jsonl`, all used in order).
    private static func loadTexts(path: String, limit: Int) -> [TypedText]? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = contents.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        if path.hasSuffix(".jsonl") {
            return lines.prefix(limit).compactMap { line in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let text = object["text"] as? String else { return nil }
                var item = TypedText(text: text, group: object["tense"] as? String)
                if let typed = object["typed"] as? String { item.slips = slips(in: text, typedAs: typed) }
                return item
            }
        }
        var generator = SeededGenerator(seed: 7)
        var sampled = lines
        sampled.shuffle(using: &generator)
        return sampled.prefix(limit).map { TypedText(text: $0, group: nil) }
    }

    /// The words that differ between a text and its misspelled copy (same words, same order).
    private static func slips(in text: String, typedAs typed: String) -> [(before: String, wrong: String, right: String)] {
        let right = text.split(separator: " ", omittingEmptySubsequences: false)
        let wrong = typed.split(separator: " ", omittingEmptySubsequences: false)
        guard right.count == wrong.count else { return [] }
        var result: [(before: String, wrong: String, right: String)] = []
        for (correct, misspelled) in zip(right, wrong) where correct != misspelled {
            let leading = correct.prefix { !$0.isLetter }
            let core = correct.dropFirst(leading.count).prefix { $0.isLetter || $0 == "'" }
            let wrongCore = misspelled.dropFirst(leading.count).prefix { $0.isLetter || $0 == "'" }
            guard !core.isEmpty, !wrongCore.isEmpty, core.first?.isLowercase == true else { continue }
            result.append((String(text[..<core.startIndex]), String(wrongCore), String(core)))
        }
        return result
    }

    /// Every form of a verb mapped to all its forms, from `Tools/prediction/verb_forms.txt` (one
    /// verb per line). A form shared by two verbs (`found`) goes with the first line that has it,
    /// and the file lists inflected readings first.
    private static func loadVerbFamilies(path: String) -> [String: [String]] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var families: [String: [String]] = [:]
        for line in contents.split(separator: "\n") where !line.hasPrefix("#") {
            let forms = line.split(separator: " ").map(String.init)
            for form in forms where families[form] == nil { families[form] = forms }
        }
        return families
    }
}

/// SplitMix64, so `--ksr` samples the same sentences on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// End-to-end score for the whole typing UI with a writer who misspells: `cotabby-spell --writer
/// <sentences> <typo-pairs> [n]`. Each word with recorded misspellings is typed misspelled 30% of the
/// time; the writer takes a strip pick when it is cheaper than typing on (Tab for word 1, Option+n
/// as 1.5 keys otherwise), and after the Space lets auto-fix work or takes the fix from the spelling
/// bar (Tab for the best fix, Option+n otherwise). Reports keys per character of intended text and
/// the errors left in the text, split into wrong auto-fixes and misspellings nothing fixed.
@MainActor
struct WriterSimulation {
    let predictor: PredictionHarness
    let decide: (String) -> TypoGateDecision

    func run(sentencesPath: String, typosPath: String, limit: Int) -> Int32 {
        guard let sentencesText = try? String(contentsOfFile: sentencesPath, encoding: .utf8),
              let typosText = try? String(contentsOfFile: typosPath, encoding: .utf8) else { return 2 }
        var typos: [String: [String]] = [:]
        for line in typosText.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            if fields.count == 2 { typos[String(fields[0]), default: []].append(String(fields[1])) }
        }
        var generator = SeededGenerator(seed: 11)
        var sentences = sentencesText.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        sentences.shuffle(using: &generator)
        var score = Score()
        for sentence in sentences.prefix(limit) {
            simulate(sentence, typos: typos, generator: &generator, into: &score)
        }
        let words = Double(max(score.words, 1))
        print(String(
            format: "words %d  misspelled %d  keys/char %.3f (savings %.1f%%)  errors left per 100 words: %.2f "
                + "(wrong auto-fix %.2f, unfixed %.2f)  strip picks %d  bar picks %d  auto-fixes %d",
            score.words, score.misspelled, score.keys / Double(max(score.characters, 1)),
            100 * (1 - score.keys / Double(max(score.characters, 1))),
            100 * Double(score.wrongAuto + score.unfixed) / words, 100 * Double(score.wrongAuto) / words,
            100 * Double(score.unfixed) / words, score.stripPicks, score.barPicks, score.autoFixes
        ))
        print("unfixed: \(score.notCaught) not flagged at all, \(score.barMissed) flagged but the right word was not in the bar")
        return 0
    }

    private struct Score {
        var words = 0, misspelled = 0, characters = 0, stripPicks = 0, barPicks = 0, autoFixes = 0
        var wrongAuto = 0, unfixed = 0, notCaught = 0, barMissed = 0
        var keys = 0.0
    }

    private func simulate(_ sentence: String, typos: [String: [String]], generator: inout SeededGenerator, into score: inout Score) {
        var written = ""
        for word in sentence.split(separator: " ").map(String.init) {
            let intended = word.trimmingCharacters(in: .punctuationCharacters)
            guard !intended.isEmpty, intended.allSatisfy(\.isLetter) else {
                written += word + " "
                continue
            }
            score.words += 1
            score.characters += intended.count + 1
            let lowered = intended.lowercased()
            var spelling = intended
            if let options = typos[lowered], Double.random(in: 0..<1, using: &generator) < 0.3 {
                spelling = options.randomElement(using: &generator) ?? intended
                if intended.first?.isUppercase == true { spelling = spelling.prefix(1).uppercased() + spelling.dropFirst() }
                score.misspelled += 1
            }
            written += type(intended: intended, spelling: spelling, after: written, into: &score) + " "
        }
    }

    /// Types one word; returns what ends up in the text.
    private func type(intended: String, spelling: String, after written: String, into score: inout Score) -> String {
        let target = intended.lowercased()
        var typed = ""
        for character in spelling {
            if let slot = strip(written + typed).firstIndex(of: target) {
                let cost = slot == 0 ? 1.0 : 1.5
                if cost < Double(spelling.count - typed.count + 1) {
                    score.keys += cost
                    score.stripPicks += 1
                    return intended
                }
            }
            typed.append(character)
            score.keys += 1
        }
        score.keys += 1
        guard spelling.lowercased() != target else { return spelling }
        switch decide(written + spelling + " ") {
        case let .applyCorrection(_, fix):
            score.autoFixes += 1
            if fix.lowercased() == target { return intended }
            score.wrongAuto += 1
            return fix
        case let .offerChoices(_, list), let .offerRankedCorrection(_, list), let .offerRealWordFix(_, list):
            return pickFromBar(list.map { $0.term.lowercased() }, target: target, intended: intended, spelling: spelling, into: &score)
        case let .offerCorrection(_, fix):
            return pickFromBar([fix.lowercased()], target: target, intended: intended, spelling: spelling, into: &score)
        default:
            score.unfixed += 1
            score.notCaught += 1
            return spelling
        }
    }

    /// The bar shows the two best fixes: Tab takes the first, Option+n the second.
    private func pickFromBar(_ fixes: [String], target: String, intended: String, spelling: String, into score: inout Score) -> String {
        let shown = Int(ProcessInfo.processInfo.environment["BAR_FIXES"] ?? "2") ?? 2
        guard let slot = fixes.prefix(shown).firstIndex(of: target) else {
            score.unfixed += 1
            score.barMissed += 1
            return spelling
        }
        score.keys += slot == 0 ? 1 : 1.5
        score.barPicks += 1
        return intended
    }

    private func strip(_ text: String) -> [String] {
        NextWordPredictor.predict(textBefore: text, sources: predictor.sources)?.words.map { $0.lowercased() } ?? []
    }
}
