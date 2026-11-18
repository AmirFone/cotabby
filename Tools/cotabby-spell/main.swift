import AppKit
import Foundation

/// cotabby-spell: runs Cotabby's real spelling engine (the same `TypoGateInputs`, ranker, bigram
/// context, real-word detector, and optional Jev refiner the app uses) on text from the command line.
///
///   cotabby-spell "I don't know wich |"                one decision; `|` marks the caret
///   cotabby-spell --suite Tools/cotabby-spell/cases.txt  regression suite with expected outcomes
///   cotabby-spell --repl                               type lines, see decisions
///   cotabby-spell --predict "I would like |"          next-word list (see Prediction.swift)
///   cotabby-spell --ksr heldout.txt [3000]             prediction accuracy and keystroke savings
///   cotabby-spell --typing texts [n] [--lm model.gguf] [--verbs verb_forms.txt]
///                                                      first suggestion right at every typing moment,
///                                                      and the tense test (see Prediction.swift)
///   cotabby-spell --rank "my dady |"                  every ranked candidate with its score
///   cotabby-spell --bench                              per-keystroke latency over the suite
///   cotabby-spell --training-export training-log.jsonl the training examples for a raw log
///   cotabby-spell --replay export.jsonl [--sentence-model m.gguf] [--adapt] [--show]
///                                                      an export typed again through the engine
///                                                      as it is now (see Replay.swift)
///
/// Options: --jev (uses TYPESAFE_API_KEY and waits for the second pass), --jev-mock (a fake Jev
/// that backs the first option, to exercise the second pass offline), --no-auto, --no-context,
/// --personal typo=word:count, --learn "a sentence the writer wrote" (personal phrases),
/// --wrote "a sentence" (personal vocabulary: names and jargon; needs two uses), --verbose.

@MainActor
struct Harness {
    let dependencies: SpellingEngineDependencies
    let refiner: WordIntentRefiner?
    let settings: TypoGate.Settings
    /// What the engine learns from the writer as they go; the replay teaches these as the app would.
    let vocabulary: PersonalVocabulary
    let phrases: PersonalPhraseModel

    static func make(arguments: Arguments) throws -> Harness {
        let root = arguments.resourceRoot
        let english = try String(contentsOf: root.appendingPathComponent("frequency_dictionary_en_82_765.txt"), encoding: .utf8)
            + "\n" + ((try? String(contentsOf: root.appendingPathComponent("frequency_overrides_en.txt"), encoding: .utf8)) ?? "")
            // NO_SPELLING_SUPPLEMENT=1 leaves the added words out, to measure what they change.
            + "\n" + (ProcessInfo.processInfo.environment["NO_SPELLING_SUPPLEMENT"] != nil ? "" : SymSpellCorrector.spellingLines(
                ofSupplement: (try? String(contentsOf: root.appendingPathComponent("prediction_words_en.txt"), encoding: .utf8)) ?? ""
            ))
        let corrector = SymSpellCorrector(preloadLanguage: nil) { language in
            let url = root.appendingPathComponent("SpellingDictionaries/\(language.resourceName).txt")
            return try? String(contentsOf: url, encoding: .utf8)
        }
        corrector.loadForTesting(contents: english)
        let bigrams = arguments.useContext
            ? BigramContextModel(contents: try String(
                contentsOf: root.appendingPathComponent("frequency_bigramdictionary_en_243_342.txt"),
                encoding: .utf8
            ))
            : nil
        let suite = "cotabby-spell.\(ProcessInfo.processInfo.processIdentifier)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let memory = PersonalCorrectionMemory(userDefaults: defaults)
        let phrases = PersonalPhraseModel(fileURL: nil)
        let nextWordModel = arguments.useContext
            ? (try? Data(contentsOf: root.appendingPathComponent("next_word_model_en.bin"), options: .alwaysMapped))
                .flatMap(NextWordModel.init(data:))
            : nil
        arguments.learn.forEach { phrases.learn(sentence: $0) }
        // --wrote "a sentence": the writer's own words in it (not in the dictionary, accepted by the
        // system checker) are learned, as the app learns them from finished sentences.
        let vocabulary = PersonalVocabulary(fileURL: nil)
        let checker = CurrentWordSpellChecker()
        arguments.wrote.forEach { sentence in
            vocabulary.learn(
                sentence: sentence,
                isDictionaryWord: { corrector.isDictionaryWord($0) },
                isAcceptedSpelling: { !checker.isTypo($0, language: SpellingDictionaryLanguage.english.rawValue) }
            )
        }
        for (typo, word, count) in arguments.personal {
            for _ in 0..<count { memory.recordAccepted(typo: typo, replacement: word) }
        }
        let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"]
        let refiner: WordIntentRefiner?
        if arguments.mockJev {
            // Stands in for Jev: backs the first option at 92% so the second pass is observable.
            refiner = WordIntentRefiner(apiKeyProvider: { "mock" }, fetch: { request, _ in
                let options = JevWordIntentClient.allOptions(for: request)
                var probabilities: [String: Double] = [:]
                for (index, option) in options.enumerated() {
                    probabilities[option] = index == 0 ? 0.92 : 0.08 / Double(max(options.count - 1, 1))
                }
                return JevWordIntentVerdict(probabilities: probabilities, confidence: 0.9)
            })
        } else {
            refiner = arguments.useJev ? WordIntentRefiner(apiKeyProvider: { key }) : nil
        }
        if arguments.useJev, key == nil {
            FileHandle.standardError.write(Data("--jev needs TYPESAFE_API_KEY; running local only\n".utf8))
        }
        // The trained auto-fix judge: --model <file>, else the bundled one; --no-model keeps the score rule.
        let modelURL = arguments.modelPath.map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("autofix_confidence_en.json")
        let autoFixModel = arguments.useModel
            ? (try? Data(contentsOf: modelURL)).flatMap { TreeEnsembleModel(data: $0, featureNames: AutoFixFeatures.names) }
            : nil
        let wrongWordModel = arguments.useModel
            ? (try? Data(contentsOf: root.appendingPathComponent("wrong_word_en.json")))
                .flatMap { TreeEnsembleModel(data: $0, featureNames: WrongWordDetector.featureNames) }
            : nil
        if arguments.modelPath != nil, autoFixModel == nil {
            FileHandle.standardError.write(Data("--model: not a model for the current feature list; using the score rule\n".utf8))
        }
        return Harness(
            dependencies: SpellingEngineDependencies(
                spellChecker: CurrentWordSpellChecker(),
                symSpellCorrector: corrector,
                languageResolver: SpellingLanguageResolver(),
                enabledLanguages: { [.english] },
                memory: memory,
                bigrams: bigrams,
                refiner: refiner,
                personalPairCount: { phrases.pairCount(first: $0, second: $1) },
                sentenceContextScore: nextWordModel.map { model in
                    { NextWordPredictor.contextScore(of: $1, after: $0, model: model) }
                },
                personalWords: { vocabulary.matches(for: $0) },
                autoFixModel: autoFixModel,
                wrongWordModel: wrongWordModel,
                americanSpellings: arguments.americanSpellings
            ),
            refiner: refiner,
            settings: {
                var settings = TypoGate.Settings(
                    suppressCompletionsOnTypo: true,
                    offerTypoCorrections: true,
                    automaticallyFixTypos: arguments.autoFix
                )
                if let score = arguments.autoScore { settings.autoApplyMinimumScore = score }
                if let margin = arguments.autoMargin { settings.autoApplyMinimumMargin = margin }
                settings.autoApplyMinimumConfidence = arguments.confidence ?? autoFixModel?.threshold
                return settings
            }(),
            vocabulary: vocabulary,
            phrases: phrases
        )
    }

    func proofread(_ sentence: String) -> LocalProofreadResult {
        LocalSentenceProofreader.proofread(
            sentence,
            checks: TypoGateInputs.sentenceChecks(dependencies: dependencies, settings: settings)
        )
    }

    struct Outcome {
        let decision: TypoGateDecision
        let milliseconds: Double
        let usedJev: Bool
    }

    func decide(_ input: CaretText) -> Outcome {
        let start = DispatchTime.now().uptimeNanoseconds
        let inputs = TypoGateInputs(dependencies: dependencies, precedingText: input.before, textAfter: input.after)
        let decision = inputs.decide(settings: settings)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        if let refiner, !inputs.usedJevVerdict {
            switch decision {
            case let .offerChoices(word, list), let .offerRankedCorrection(word, list):
                inputs.requestJevVerdict(typo: word, candidates: list, includesTypedWord: false)
            case let .offerCorrection(word, fix):
                inputs.requestJevVerdict(typo: word, candidates: [SpellingCandidate(term: fix, score: 1)], includesTypedWord: false)
            case let .offerRealWordFix(word, list):
                inputs.requestJevVerdict(typo: word, candidates: list, includesTypedWord: true)
            default:
                break
            }
        }
        return Outcome(decision: decision, milliseconds: elapsed, usedJev: inputs.usedJevVerdict)
    }

    /// Local pass, then (with --jev) waits for the verdict and runs the pass the app would re-run.
    func decideWithRefinement(_ input: CaretText) async -> [Outcome] {
        let first = decide(input)
        guard let refiner, refiner.isAvailable else { return [first] }
        var refined = false
        refiner.onRefined = { refined = true }
        for _ in 0..<60 where !refined {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return refined ? [first, decide(input)] : [first]
    }
}

/// Text with the caret marked by `|`. Without a marker the caret is at the end.
struct CaretText {
    let before: String
    let after: String

    init(_ raw: String) {
        if let bar = raw.firstIndex(of: "|") {
            before = String(raw[..<bar])
            after = String(raw[raw.index(after: bar)...])
        } else {
            before = raw
            after = ""
        }
    }

    var display: String { (before + "|" + after).debugDescription }
}

enum Render {
    static func decision(_ decision: TypoGateDecision) -> String {
        switch decision {
        case .proceed: return "proceed"
        case .suppress: return "suppress"
        case let .applyCorrection(word, fix): return "AUTO \(word) → \(fix)"
        case let .offerCorrection(word, fix): return bar(word, [SpellingCandidate(term: fix, score: 1)])
        case let .offerRankedCorrection(word, list), let .offerChoices(word, list): return bar(word, list)
        case let .offerRealWordFix(word, list): return "REALWORD " + bar(word, list)
        }
    }

    /// What the three-slot bar shows: the typed word in quotes, then the two best fixes.
    static func bar(_ word: String, _ list: [SpellingCandidate]) -> String {
        let fixes = list.filter { $0.term != word }.prefix(2)
        let slots = ["“\(word)”"] + fixes.enumerated().map { index, item in
            let label = "\(item.term) \(String(format: "%.2f", item.score))"
            return index == 0 ? "[\(label)]" : label
        }
        return "BAR " + slots.joined(separator: " | ")
    }

    /// Short machine form used by the suite: auto:the, bar:which, realword:there, proceed, suppress.
    static func code(_ decision: TypoGateDecision) -> String {
        switch decision {
        case .proceed: return "proceed"
        case .suppress: return "suppress"
        case let .applyCorrection(_, fix): return "auto:\(fix)"
        case let .offerCorrection(_, fix): return "bar:\(fix)"
        case let .offerRankedCorrection(word, list), let .offerChoices(word, list):
            return "bar:\(list.first { $0.term != word }?.term ?? "")"
        case let .offerRealWordFix(_, list): return "realword:\(list.first?.term ?? "")"
        }
    }
}

struct Arguments {
    var inputs: [String] = []
    var suitePath: String?
    var accuracyPath: String?
    var featuresInput: String?
    var featuresOutput: String?
    var modelPath: String?
    var useModel = true
    var checkModelPath: String?
    var trainingLogPath: String?
    var replayPath: String?
    var sentenceModelPath: String?
    var showsReplayWords = false
    var replayAdapts = false
    var wrongFeaturesInput: String?
    var wrongFeaturesOutput: String?
    var confidence: Double?
    var sentencesPath: String?
    var proofread: [String] = []
    var predict: [String] = []
    var learn: [String] = []
    var wrote: [String] = []
    var rank: [String] = []
    var adaptive = false
    /// `--american`: fixes and suggestions in American spelling, as the app does on a US Mac.
    var american = false
    var americanSpellings: AmericanSpellings? {
        guard american, let contents = try? String(
            contentsOf: resourceRoot.appendingPathComponent("american_spellings_en.txt"), encoding: .utf8
        ) else { return nil }
        return AmericanSpellings(contents: contents)
    }
    var profile: [String] = []
    var cleanPath: String?
    var journalPath: String?
    var writer: (sentences: String, typos: String, limit: Int)?
    var sentenceBench: (swapped: String, clean: String)?
    var autoScore: Double?
    var autoMargin: Double?
    var ksrPath: String?
    var ksrLimit = 3000
    var typingPath: String?
    var typingLimit = 3000
    var languageModelPath: String?
    var verbFormsPath: String?
    var repl = false
    var bench = false
    var useJev = false
    var mockJev = false
    var useContext = true
    var autoFix = true
    var personal: [(String, String, Int)] = []
    var resourceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Cotabby/Resources")

    init(_ raw: [String]) {
        var iterator = raw.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--suite": suitePath = iterator.next()
            case "--accuracy": accuracyPath = iterator.next()
            case "--features":
                featuresInput = iterator.next()
                featuresOutput = iterator.next()
            case "--model": modelPath = iterator.next()
            case "--confidence": confidence = iterator.next().flatMap(Double.init)
            case "--no-model": useModel = false
            case "--check-model": checkModelPath = iterator.next()
            case "--training-export": trainingLogPath = iterator.next()
            case "--replay": replayPath = iterator.next()
            case "--sentence-model": sentenceModelPath = iterator.next()
            case "--show": showsReplayWords = true
            case "--adapt": replayAdapts = true
            case "--wrong-features":
                wrongFeaturesInput = iterator.next()
                wrongFeaturesOutput = iterator.next()
            case "--sentences": sentencesPath = iterator.next()
            case "--proofread": if let text = iterator.next() { proofread.append(text) }
            case "--predict": if let text = iterator.next() { predict.append(text) }
            case "--learn": if let text = iterator.next() { learn.append(text) }
            case "--wrote": if let text = iterator.next() { wrote.append(text) }
            case "--rank": if let text = iterator.next() { rank.append(text) }
            case "--adaptive": adaptive = true
            case "--profile": if let text = iterator.next() { profile.append(text) }
            case "--clean": cleanPath = iterator.next()
            case "--journal": journalPath = iterator.next()
            case "--writer":
                if let sentences = iterator.next(), let typos = iterator.next() {
                    writer = (sentences, typos, iterator.next().flatMap(Int.init) ?? 1000)
                }
            case "--sentence-bench":
                if let swapped = iterator.next(), let clean = iterator.next() { sentenceBench = (swapped, clean) }
            case "--auto-score": autoScore = iterator.next().flatMap(Double.init)
            case "--auto-margin": autoMargin = iterator.next().flatMap(Double.init)
            case "--ksr":
                ksrPath = iterator.next()
                if let limit = iterator.next().flatMap(Int.init) { ksrLimit = limit }
            case "--typing":
                typingPath = iterator.next()
                if let limit = iterator.next().flatMap(Int.init) { typingLimit = limit }
            case "--lm": languageModelPath = iterator.next()
            case "--verbs": verbFormsPath = iterator.next()
            case "--repl": repl = true
            case "--bench": bench = true
            case "--jev": useJev = true
            case "--jev-mock": mockJev = true
            case "--no-context": useContext = false
            case "--american": american = true
            case "--no-auto": autoFix = false
            case "--verbose": break
            case "--resources": if let path = iterator.next() { resourceRoot = URL(fileURLWithPath: path) }
            case "--personal":
                if let spec = iterator.next() { personal.append(Self.parsePersonal(spec)) }
            default: inputs.append(argument)
            }
        }
    }

    private static func parsePersonal(_ spec: String) -> (String, String, Int) {
        let parts = spec.split(separator: "=", maxSplits: 1)
        let rhs = parts.count == 2 ? parts[1].split(separator: ":") : []
        let word = rhs.first.map(String.init) ?? ""
        let count = rhs.count > 1 ? Int(rhs[1]) ?? 1 : 1
        return (parts.first.map(String.init) ?? "", word, count)
    }
}

@MainActor
func runSuite(_ path: String, harness: Harness) async -> Int32 {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("cannot read \(path)")
        return 2
    }
    var passed = 0
    var failures: [String] = []
    for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
        guard let tab = line.firstIndex(of: "\t") else {
            failures.append("malformed (need <expected><TAB><text>): \(line)")
            continue
        }
        let expected = String(line[..<tab]).trimmingCharacters(in: .whitespaces)
        let input = CaretText(String(line[line.index(after: tab)...]).replacingOccurrences(of: "\\n", with: "\n"))
        let outcomes = await harness.decideWithRefinement(input)
        let actual = Render.code(outcomes.last!.decision)
        if matches(expected: expected, actual: actual, decision: outcomes.last!.decision) {
            passed += 1
        } else {
            failures.append("\(input.display.padding(toLength: 34, withPad: " ", startingAt: 0)) expected \(expected), got \(Render.decision(outcomes.last!.decision))")
        }
    }
    for failure in failures { print("FAIL  " + failure) }
    print("\(passed)/\(passed + failures.count) passed")
    return failures.isEmpty ? 0 : 1
}

/// Expectations: exact code (`auto:the`), a kind (`bar`, `auto`, `realword`), alternatives joined by
/// `/` (`bar:which/auto:which`), `bar-has:word` (anywhere in the list), or `!auto` (anything but an
/// automatic edit).
func matches(expected: String, actual: String, decision: TypoGateDecision) -> Bool {
    expected.split(separator: "/").contains { option in
        let option = String(option)
        if option.hasPrefix("!") { return !actual.hasPrefix(String(option.dropFirst())) }
        if option.hasPrefix("bar-has:") {
            let word = String(option.dropFirst("bar-has:".count))
            switch decision {
            case let .offerChoices(_, list), let .offerRankedCorrection(_, list), let .offerRealWordFix(_, list):
                return list.contains { $0.term == word }
            case let .offerCorrection(_, fix): return fix == word
            default: return false
            }
        }
        return option.contains(":") ? actual == option : actual.hasPrefix(option)
    }
}

/// Top-1: the word Cotabby would apply or put in the bar's middle slot. Top-3: anywhere in the bar
/// (the bar shows two fixes, the list behind it up to four).
@MainActor
/// False alarms: each line is correct text ending at a word boundary; anything but "proceed" on
/// the last word is a false alarm (a bar, an auto-fix, or a real-word flag on a correct word).
/// The sentence pass on whole sentences: recall on sentences with one wrong word
/// (`<intended><TAB><sentence>`), and false alarms (any flag or automatic change) on correct ones.
func runSentenceBench(swapped: String, clean: String, harness: Harness) -> Int32 {
    guard let swappedText = try? String(contentsOfFile: swapped, encoding: .utf8),
          let cleanText = try? String(contentsOfFile: clean, encoding: .utf8) else { return 2 }
    var caught = 0, total = 0
    for line in swappedText.split(separator: "\n") {
        let fields = line.split(separator: "\t", maxSplits: 1)
        guard fields.count == 2 else { continue }
        total += 1
        let result = harness.proofread(String(fields[1]))
        let intended = fields[0].lowercased()
        let fixedInPlace = result.autoCorrected.lowercased().split(separator: " ").contains { $0.hasPrefix(intended) }
            && result.autoCorrected != String(fields[1])
        if fixedInPlace || result.flags.contains(where: { $0.options.first?.lowercased() == intended }) { caught += 1 }
    }
    var alarms = 0, sentences = 0
    var examples: [String] = []
    for line in cleanText.split(separator: "\n") {
        sentences += 1
        let result = harness.proofread(String(line))
        guard result.hasAutoFixes || result.hasSuggestions else { continue }
        alarms += 1
        examples.append("\(line)  →  \(result.suggested)")
    }
    for example in examples.prefix(25) { print("ALARM  " + example) }
    print(String(format: "caught %d/%d (%.1f%%)  false alarms on correct sentences %d/%d (%.1f%%)",
                 caught, total, Double(caught) * 100 / Double(max(total, 1)),
                 alarms, sentences, Double(alarms) * 100 / Double(max(sentences, 1))))
    return 0
}

/// Replays the app's correction journal (Settings → Writing → Show Journal) against the engine:
/// what the writer's real mistakes were, and which ones the engine still gets wrong out of the box,
/// so they can be fixed in the engine (not just in that writer's personal memory).
func runJournal(_ path: String, harness: Harness) -> Int32 {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return 2 }
    var kinds: [String: Int] = [:]
    var fixes: [String: (final: String, count: Int)] = [:]
    var undone: [String: Int] = [:]
    for line in contents.split(separator: "\n") {
        guard let data = line.data(using: .utf8),
              let entry = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let kind = entry["kind"], let typed = entry["typed"], let final = entry["final"] else { continue }
        kinds[kind, default: 0] += 1
        switch kind {
        case "autoFixUndone", "sentenceFixUndone", "keptAsTyped": undone[typed.lowercased(), default: 0] += 1
        case "autoFixKept", "picked", "selfCorrected", "sentenceFixKept":
            let key = typed.lowercased()
            fixes[key] = (final.lowercased(), (fixes[key]?.count ?? 0) + 1)
        default: break
        }
    }
    print("events: " + kinds.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    var right = 0
    var wrong: [String] = []
    for (typed, fix) in fixes.sorted(by: { $0.value.count > $1.value.count }) {
        let decision = harness.decide(CaretText("I think \(typed) ")).decision
        let first: String? = switch decision {
        case let .applyCorrection(_, word), let .offerCorrection(_, word): word
        case let .offerChoices(_, list), let .offerRankedCorrection(_, list), let .offerRealWordFix(_, list): list.first?.term
        default: nil
        }
        if first?.lowercased() == fix.final { right += 1 } else {
            wrong.append("\(typed) → \(fix.final) (×\(fix.count)): engine says \(Render.decision(decision))")
        }
    }
    print(String(format: "your fixes the engine already gets first: %d/%d", right, fixes.count))
    for line in wrong.prefix(40) { print("MISSED  " + line) }
    for (typed, count) in undone.sorted(by: { $0.value > $1.value }).prefix(20) {
        print("KEPT    \(typed) (×\(count)): you undid or kept it; the engine should leave it alone")
    }
    return 0
}

func runClean(_ path: String, harness: Harness) -> Int32 {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return 2 }
    var total = 0, alarms = 0, edits = 0
    var examples: [String] = []
    for line in contents.split(separator: "\n") where !line.hasPrefix("#") {
        total += 1
        let decision = harness.decide(CaretText(String(line))).decision
        guard decision != .proceed else { continue }
        alarms += 1
        if case .applyCorrection = decision { edits += 1 }
        examples.append("\(CaretText(String(line)).display)  →  \(Render.decision(decision))")
    }
    for example in examples.prefix(30) { print("ALARM  " + example) }
    print(String(format: "%d correct words  false alarms %d (%.2f%%), of which auto-edits %d", total, alarms,
                 Double(alarms) * 100 / Double(max(total, 1)), edits))
    return 0
}

/// Writes training rows for the wrong-word model (`Tools/autofix/train_wrong_word.py`). Input lines
/// are `<intended><TAB><before><TAB><typed><TAB><after>` (a sentence with one real word swapped) or
/// `=<TAB><TAB><TAB><sentence>` (a correct sentence). Every real word in the sentence gets two CSV
/// rows per alternative, one as the sentence pass sees it (words on both sides) and one as the caret
/// sees it just after the word is typed (nothing to the right): sentence number, word number, label
/// (1 when this alternative is the intended word at the swapped place), whether the word is the
/// swapped one, the view (0 both sides, 1 caret), the two words, then the
/// `WrongWordDetector.featureNames` columns. A second file (`.rule`) records what the hand rules
/// flagged in the same sentence, at sentence end and at the caret, so old and new are compared on
/// identical input.
@MainActor
func runWrongWordFeatures(_ path: String, output: String, harness: Harness) -> Int32 {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8),
          let sources = harness.dependencies.symSpellCorrector.wrongWordSources() else { return 2 }
    var rows = ["sentence,word,label,swapped,view,typed,candidate," + WrongWordDetector.featureNames.joined(separator: ",")]
    var rule = ["sentence,swapped,caught,falseFlags,caretCaught,caretFalseFlags"]
    let isTypo: (String) -> Bool = { word in
        TypoGateInputs(dependencies: harness.dependencies, precedingText: word + " ", textAfter: "").isTypo(word)
    }
    for (number, line) in contents.split(separator: "\n").enumerated() {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4 else { continue }
        let intended = fields[0], sentence = fields[1] + fields[2] + fields[3]
        let isSwapped = intended != "="
        let swappedOffset = isSwapped ? fields[1].count : -1
        let tokens = WordToken.tokens(in: sentence)
        for (index, token) in tokens.enumerated() {
            let textBefore = String(sentence[..<token.range.lowerBound])
            let offset = sentence.distance(from: sentence.startIndex, to: token.range.lowerBound)
            let trimmed = textBefore.trimmingCharacters(in: .whitespaces)
            let looksLikeName = token.text.first?.isUppercase == true && !trimmed.isEmpty && !".!?\"“(".contains(trimmed.last ?? ".")
            guard !looksLikeName, token.text != "I", !isTypo(token.text) else { continue }
            let alternatives = WrongWordDetector.alternatives(for: token.text, sources: sources)
            guard !alternatives.isEmpty else { continue }
            let typedCount = sources.count(token.text.lowercased())
            let views: [(next: String?, afterNext: String?)] = [
                (index + 1 < tokens.count ? tokens[index + 1].text.lowercased() : nil,
                 index + 2 < tokens.count ? tokens[index + 2].text.lowercased() : nil),
                (nil, nil)
            ]
            for (view, neighbors) in views.enumerated() {
                let position = WrongWordDetector.Position(
                    textBefore: textBefore,
                    previous: index > 0 ? tokens[index - 1].text.lowercased() : nil,
                    next: neighbors.next,
                    afterNext: neighbors.afterNext,
                    pairCount: { harness.dependencies.bigrams?.count(first: $0, second: $1) },
                    sentenceScore: { harness.dependencies.sentenceContextScore?($0, $1) ?? 0 }
                )
                let vectors = WrongWordDetector.features(
                    typed: token.text,
                    typedCount: typedCount,
                    alternatives: alternatives,
                    position: position
                )
                for (alternative, vector) in zip(alternatives, vectors) {
                    let label = offset == swappedOffset && alternative.term == intended.lowercased() ? 1 : 0
                    rows.append("\(number),\(index),\(label),\(offset == swappedOffset ? 1 : 0),\(view),"
                        + "\(token.text.lowercased()),\(alternative.term),"
                        + vector.map { String(format: "%.4g", $0) }.joined(separator: ","))
                }
            }
        }
        // The caret-level hand rule: after each word and a space, does the gate offer a wrong-word fix?
        var caretCaught = false
        var caretFalseFlags = 0
        for token in tokens {
            let offset = sentence.distance(from: sentence.startIndex, to: token.range.lowerBound)
            let prefix = String(sentence[..<token.range.upperBound]) + " "
            guard case let .offerRealWordFix(_, candidates) = harness.decide(CaretText(prefix)).decision else { continue }
            if offset == swappedOffset, candidates.first?.term.lowercased() == intended.lowercased() {
                caretCaught = true
            } else {
                caretFalseFlags += 1
            }
        }
        // The hand rule on the same sentence. Flags on misspelled words belong to the typo path.
        let result = harness.proofread(sentence)
        let realWordFlags = result.flags.filter { !isTypo($0.typed) }
        let caught = realWordFlags.contains { $0.options.first?.lowercased() == intended.lowercased() }
            || (isSwapped && result.autoCorrected != sentence
                && WordToken.tokens(in: result.autoCorrected).contains { $0.text.lowercased() == intended.lowercased() }
                && !tokens.contains { $0.text.lowercased() == intended.lowercased() })
        let falseFlags = realWordFlags.filter { $0.options.first?.lowercased() != intended.lowercased() }.count
        rule.append("\(number),\(isSwapped ? 1 : 0),\(caught ? 1 : 0),\(falseFlags),\(caretCaught ? 1 : 0),\(caretFalseFlags)")
    }
    do {
        try rows.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
        try rule.joined(separator: "\n").write(toFile: output + ".rule", atomically: true, encoding: .utf8)
    } catch {
        return 2
    }
    print("\(rule.count - 1) sentences, \(rows.count - 1) rows → \(output)")
    return 0
}

/// Compares the Swift tree evaluator with LightGBM on the sample `train.py` wrote (CHECK=<file>).
@MainActor
func runModelCheck(_ path: String, harness: Harness) -> Int32 {
    struct Sample: Decodable {
        let x: [Double]
        let p: Double
    }
    guard let data = FileManager.default.contents(atPath: path),
          let samples = try? JSONDecoder().decode([Sample].self, from: data), !samples.isEmpty else { return 2 }
    // The sample's width says which of the two models it was written for.
    let isWrongWord = samples[0].x.count == WrongWordDetector.featureNames.count
    guard let model = isWrongWord ? harness.dependencies.wrongWordModel : harness.dependencies.autoFixModel else {
        print("no model loaded (feature list mismatch, or the file is missing)")
        return 1
    }
    let worst = samples.map { abs(model.probability(features: $0.x) - $0.p) }.max() ?? 1
    let start = DispatchTime.now().uptimeNanoseconds
    var sink = 0.0
    for _ in 0..<200 { for sample in samples { sink += model.probability(features: sample.x) } }
    let micros = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000 / Double(200 * samples.count)
    print(String(format: "%d samples  largest difference from LightGBM %.2e  %.2f µs per candidate%@",
                 samples.count, worst, micros, sink.isNaN ? " (NaN)" : ""))
    return worst < 1e-4 ? 0 : 1
}

/// Writes one training row per flagged word for `Tools/autofix/train.py`. Input lines are
/// `<intended><TAB><typo or text ending in the typo>` like `--accuracy`; a line whose intended word
/// is the typed word itself is a correct word, where any fix is wrong. Words the gate does not flag
/// are skipped. Each row: the candidates, the model inputs for each (`AutoFixFeatures`, written as if
/// that candidate led the list), and what the score rule decided, so old and new are compared on
/// the same rows.
@MainActor
func runFeatures(_ path: String, output: String, harness: Harness) -> Int32 {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return 2 }
    var rows: [String] = []
    var total = 0
    for line in contents.split(separator: "\n") where !line.hasPrefix("#") {
        let fields = line.split(separator: "\t")
        guard fields.count == 2 else { continue }
        let intended = String(fields[0]), typo = String(fields[1])
        let precedingText = typo.contains(" ") ? typo : "I think \(typo) "
        guard let current = CurrentWordExtractor.extractTrailingWord(from: precedingText) else { continue }
        let word = current.result.word
        total += 1
        // Rows describe the ranker's own order and the score rule's decision, so no model is loaded.
        var dependencies = harness.dependencies
        dependencies.autoFixModel = nil
        let inputs = TypoGateInputs(dependencies: dependencies, precedingText: precedingText, textAfter: "")
        guard inputs.isTypo(word) else { continue }
        var settings = harness.settings
        settings.autoApplyMinimumConfidence = nil
        let decision = inputs.decide(settings: settings)
        let ranked = inputs.rankedCandidates(forFinishedWord: word)
        let perCandidate = inputs.autoFixFeatures(word)
        var ruleAuto = false
        if case .applyCorrection = decision { ruleAuto = true }
        let row: [String: Any] = [
            "intended": intended,
            "typed": word,
            "context": precedingText,
            "candidates": ranked.map(\.candidate.term),
            "correct": ranked.first?.candidate.term.lowercased() == intended.lowercased()
                && intended.lowercased() != word.lowercased(),
            "clean": intended == "=" || intended.lowercased() == word.lowercased(),
            "ruleAuto": ruleAuto,
            "xs": perCandidate
        ]
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            rows.append(text)
        }
    }
    let header = (try? JSONSerialization.data(withJSONObject: ["features": AutoFixFeatures.names]))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    do {
        try ([header] + rows).joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
    } catch {
        return 2
    }
    print("\(total) lines, \(rows.count) flagged rows → \(output)")
    return 0
}

func runAccuracy(_ path: String, harness: Harness) -> Int32 {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return 2 }
    var total = 0, top1 = 0, top2 = 0, top3 = 0, found = 0, autoFixes = 0, wrongAutoFixes = 0
    var misses: [String] = []
    var wrongAuto: [String] = []
    for line in contents.split(separator: "\n") where !line.hasPrefix("#") {
        let fields = line.split(separator: "\t")
        guard fields.count == 2 else { continue }
        let intended = String(fields[0]), typo = String(fields[1])
        total += 1
        // A second field with spaces is the whole text before the caret (a sentence ending in the
        // typo and a space), so context-aware ranking can be measured; a bare typo gets a neutral one.
        let precedingText = typo.contains(" ") ? typo : "I think \(typo) "
        let decision = harness.decide(CaretText(precedingText)).decision
        let list: [String]
        switch decision {
        case let .applyCorrection(_, fix), let .offerCorrection(_, fix): list = [fix]
        case let .offerChoices(_, items), let .offerRankedCorrection(_, items), let .offerRealWordFix(_, items):
            list = items.map(\.term)
        default: list = []
        }
        let lowered = list.map { $0.lowercased() }
        if case let .applyCorrection(_, fix) = decision {
            autoFixes += 1
            if fix.lowercased() != intended.lowercased() {
                wrongAutoFixes += 1
                wrongAuto.append("\(typo) → \(intended): auto-fixed to \(fix)")
            }
        }
        if !list.isEmpty { found += 1 }
        if lowered.first == intended.lowercased() { top1 += 1 }
        if lowered.prefix(2).contains(intended.lowercased()) { top2 += 1 }
        if lowered.prefix(3).contains(intended.lowercased()) {
            top3 += 1
        } else {
            misses.append("\(typo) → \(intended): got \(Render.decision(decision))")
        }
    }
    if total <= 200 || ProcessInfo.processInfo.environment["SHOW_MISSES"] != nil {
        for miss in misses { print("MISS  " + miss) }
    }
    for wrong in wrongAuto.prefix(40) { print("WRONG-AUTO  " + wrong) }
    func pct(_ n: Int) -> String { String(format: "%.1f%%", Double(n) * 100 / Double(max(total, 1))) }
    let wrongRate = String(format: "%.1f%%", Double(wrongAutoFixes) * 100 / Double(max(autoFixes, 1)))
    print("\(total) words  top-1 \(pct(top1))  top-2 \(pct(top2))  top-3 \(pct(top3))  any suggestion \(pct(found))  " +
          "auto-fixed \(pct(autoFixes)) (\(wrongAutoFixes) wrong, \(wrongRate) of auto-fixes)")
    return 0
}

/// Lines: <expected auto-fixed><TAB><expected with suggestions><TAB><sentence>. `=` means "same as
/// the previous column" (or the input, for the first).
@MainActor
func runSentences(_ path: String, harness: Harness) -> Int32 {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return 2 }
    var passed = 0, failed = 0
    for line in contents.split(separator: "\n") where !line.hasPrefix("#") {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3 else { continue }
        let input = fields[2]
        let expectedAuto = fields[0] == "=" ? input : fields[0]
        let expectedSuggested = fields[1] == "=" ? expectedAuto : fields[1]
        let result = harness.proofread(input)
        if result.autoCorrected == expectedAuto, result.suggested == expectedSuggested {
            passed += 1
        } else {
            failed += 1
            print("FAIL  \(input.debugDescription)\n      auto      expected \(expectedAuto.debugDescription) got \(result.autoCorrected.debugDescription)\n      suggested expected \(expectedSuggested.debugDescription) got \(result.suggested.debugDescription)")
        }
    }
    print("\(passed)/\(passed + failed) sentences passed")
    return failed == 0 ? 0 : 1
}

@MainActor
func runBench(_ path: String, harness: Harness) {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return }
    var timings: [Double] = []
    var slowest: [(Double, String)] = []
    for line in contents.split(separator: "\n") where !line.hasPrefix("#") {
        guard let tab = line.firstIndex(of: "\t") else { continue }
        let text = CaretText(String(line[line.index(after: tab)...])).before
        // Replay the line one keystroke at a time, like typing it.
        var typed = ""
        for character in text {
            typed.append(character)
            let milliseconds = harness.decide(CaretText(typed)).milliseconds
            timings.append(milliseconds)
            slowest.append((milliseconds, typed))
        }
    }
    timings.sort()
    func percentile(_ p: Double) -> Double { timings[min(timings.count - 1, Int(Double(timings.count) * p))] }
    print(String(format: "%d keystrokes  p50 %.2f ms  p95 %.2f ms  p99 %.2f ms  max %.2f ms",
                 timings.count, percentile(0.5), percentile(0.95), percentile(0.99), timings.last ?? 0))
    for (milliseconds, text) in slowest.sorted(by: { $0.0 > $1.0 }).prefix(8) {
        print(String(format: "  %6.2f ms  %@", milliseconds, CaretText(text).display))
    }
}

@MainActor
func show(_ input: CaretText, harness: Harness) async {
    let outcomes = await harness.decideWithRefinement(input)
    for (index, outcome) in outcomes.enumerated() {
        let source = index == 0 ? "local" : "jev \(harness.refiner?.lastLatencyMilliseconds ?? 0)ms"
        print("\(input.display)  →  \(Render.decision(outcome.decision))   (\(source), \(String(format: "%.2f", outcome.milliseconds)) ms)")
    }
}

/// The training examples for a raw training log, one JSON object per line on standard output: what
/// Export in Settings writes, for a log file at any path (a copy from another Mac, or the one an
/// on-screen test run produced).
func runTrainingExport(_ path: String) -> Int32 {
    guard let data = FileManager.default.contents(atPath: path) else {
        print("could not read \(path)")
        return 2
    }
    let lines = data.split(separator: UInt8(ascii: "\n")).compactMap { line in
        (try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]).flatMap(TrainingLogLine.init(json:))
    }
    FileHandle.standardOutput.write(TrainingExampleBuilder.jsonLines(TrainingExampleBuilder.examples(fromLines: lines)))
    return 0
}

@MainActor
func main() async -> Int32 {
    let arguments = Arguments(CommandLine.arguments)
    // Needs no dictionary, so it runs before the engine is loaded.
    if let path = arguments.trainingLogPath { return runTrainingExport(path) }
    let harness: Harness
    do {
        harness = try Harness.make(arguments: arguments)
    } catch {
        print("could not load dictionaries from \(arguments.resourceRoot.path): \(error.localizedDescription)")
        return 2
    }
    for word in arguments.profile {
        func time(_ label: String, _ work: () -> Void) {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<20 { work() }
            print(String(format: "  %-22@ %.2f ms", label, Double(DispatchTime.now().uptimeNanoseconds - start) / 20_000_000))
        }
        print(word)
        let corrector = harness.dependencies.symSpellCorrector
        time("candidates (mid-word)") { _ = corrector.candidates(for: word, includePrefixMatches: true) }
        time("candidates (finished)") { _ = corrector.candidates(for: word, includePrefixMatches: false) }
        time("native guesses") { _ = NSSpellChecker.shared.guesses(forWordRange: NSRange(location: 0, length: word.utf16.count), in: word, language: "en", inSpellDocumentWithTag: 0) }
        time("native isTypo") { _ = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil) }
    }
    for text in arguments.rank {
        let input = CaretText(text)
        let word = String(input.before.trimmingCharacters(in: .whitespaces).split(separator: " ").last ?? "")
        let inputs = TypoGateInputs(dependencies: harness.dependencies, precedingText: input.before, textAfter: input.after)
        let ranked = inputs.candidates(word, isMidWord: !input.before.hasSuffix(" "))
        print("\(input.display)  →  " + ranked.map { "\($0.term) \(String(format: "%.2f", $0.score))" }.joined(separator: " · "))
        if let confidence = inputs.autoFixConfidence(word) {
            print(String(format: "    model: %.3f that “%@” is meant (auto-fix from %.3f)", confidence,
                         ranked.first?.term ?? "", harness.settings.autoApplyMinimumConfidence ?? 1))
        }
    }
    if let writer = arguments.writer {
        guard let predictor = PredictionHarness.make(
            resourceRoot: arguments.resourceRoot, corrector: harness.dependencies.symSpellCorrector
        ) else { return 2 }
        return WriterSimulation(predictor: predictor, decide: { harness.decide(CaretText($0)).decision })
            .run(sentencesPath: writer.sentences, typosPath: writer.typos, limit: writer.limit)
    }
    if !arguments.predict.isEmpty || arguments.ksrPath != nil || arguments.typingPath != nil {
        guard let predictor = PredictionHarness.make(
            resourceRoot: arguments.resourceRoot,
            corrector: harness.dependencies.symSpellCorrector,
            adaptive: arguments.adaptive,
            languageModelPath: arguments.languageModelPath,
            americanSpellings: arguments.americanSpellings
        ) else {
            print("could not load next_word_model_en.bin from \(arguments.resourceRoot.path)")
            return 2
        }
        arguments.predict.forEach { predictor.show(CaretText($0)) }
        if let path = arguments.typingPath {
            return predictor.typingReport(
                path: path, limit: arguments.typingLimit, verbFormsPath: arguments.verbFormsPath,
                decide: { harness.decide(CaretText($0)).decision }
            )
        }
        if let path = arguments.ksrPath {
            return predictor.keystrokeSavings(path: path, limit: arguments.ksrLimit)
        }
        return 0
    }
    for sentence in arguments.proofread {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = harness.proofread(sentence)
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("input      \(sentence.debugDescription)\nauto-fixed \(result.autoCorrected.debugDescription)\nsuggested  \(result.suggested.debugDescription)   (\(String(format: "%.1f", milliseconds)) ms)")
    }
    if let sentences = arguments.sentencesPath {
        return runSentences(sentences, harness: harness)
    }
    if let journal = arguments.journalPath {
        return runJournal(journal, harness: harness)
    }
    if let bench = arguments.sentenceBench {
        return runSentenceBench(swapped: bench.swapped, clean: bench.clean, harness: harness)
    }
    if let clean = arguments.cleanPath {
        return runClean(clean, harness: harness)
    }
    if let input = arguments.wrongFeaturesInput, let output = arguments.wrongFeaturesOutput {
        return runWrongWordFeatures(input, output: output, harness: harness)
    }
    if let check = arguments.checkModelPath {
        return runModelCheck(check, harness: harness)
    }
    if let replay = arguments.replayPath {
        let model = arguments.sentenceModelPath.flatMap { LlamaTokenModel(url: URL(fileURLWithPath: $0)) }
        if arguments.sentenceModelPath != nil, model == nil { print("could not load the sentence model; local rules only") }
        return ExportReplay(
            harness: harness, sentenceModel: model, showsWords: arguments.showsReplayWords, adapts: arguments.replayAdapts
        ).run(path: replay)
    }
    if let input = arguments.featuresInput, let output = arguments.featuresOutput {
        return runFeatures(input, output: output, harness: harness)
    }
    if let accuracy = arguments.accuracyPath {
        return runAccuracy(accuracy, harness: harness)
    }
    if let suite = arguments.suitePath {
        if arguments.bench {
            runBench(suite, harness: harness)
            return 0
        }
        return await runSuite(suite, harness: harness)
    }
    for input in arguments.inputs {
        await show(CaretText(input), harness: harness)
    }
    if arguments.repl {
        print("Type text; `|` marks the caret (default: end). Ctrl-D to quit.")
        while let line = readLine(strippingNewline: true) {
            await show(CaretText(line), harness: harness)
        }
    }
    return 0
}

exit(await main())
