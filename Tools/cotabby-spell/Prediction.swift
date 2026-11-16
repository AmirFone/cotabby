import Foundation

/// Next-word prediction modes for cotabby-spell, running the app's `NextWordPredictor` on the
/// bundled model:
///
///   cotabby-spell --predict "I would like to |"     the list the app would show
///   cotabby-spell --ksr heldout.txt [3000]          top-1 / top-5 and keystroke savings
///
/// Keystroke savings simulates a writer who types letter by letter and picks the word with one key
/// as soon as it is listed. Same method as `Tools/ngram/evaluate.py`, so the numbers are comparable.
@MainActor
struct PredictionHarness {
    let sources: NextWordPredictor.Sources
    /// With `--adaptive`, every simulated sentence is learned after it is typed, like the app does.
    let phrases: PersonalPhraseModel?
    let hardWords: Set<String>

    static func make(resourceRoot: URL, corrector: SymSpellCorrector, adaptive: Bool = false) -> PredictionHarness? {
        let url = resourceRoot.appendingPathComponent("next_word_model_en.bin")
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let model = NextWordModel(data: data) else { return nil }
        let phrases = adaptive ? PersonalPhraseModel(fileURL: nil) : nil
        let hardWords = Set(((try? String(contentsOf: resourceRoot.appendingPathComponent("commonly_misspelled_en.txt"), encoding: .utf8)) ?? "")
            .split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init))
        return PredictionHarness(sources: NextWordPredictor.Sources(
            model: model,
            completions: { corrector.completions(of: $0, limit: $1) },
            personal: { phrases?.nextWords(after: $0) },
            personalWords: { phrases?.words(startingWith: $0) },
            fuzzyCompletions: { prefix, limit in
                guard ProcessInfo.processInfo.environment["NO_FUZZY"] == nil else { return [] }
                return corrector.fuzzyCompletions(of: prefix, limit: limit)
            },
            isHardToSpell: { ProcessInfo.processInfo.environment["NO_HARD"] == nil && hardWords.contains($0) }
        ), phrases: phrases, hardWords: hardWords)
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
    }

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
