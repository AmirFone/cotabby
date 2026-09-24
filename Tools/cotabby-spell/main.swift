import Foundation

/// cotabby-spell: runs Cotabby's real spelling engine (the same `TypoGateInputs`, ranker, bigram
/// context, real-word detector, and optional Jev refiner the app uses) on text from the command line.
///
///   cotabby-spell "I don't know wich |"                one decision; `|` marks the caret
///   cotabby-spell --suite Tools/cotabby-spell/cases.txt  regression suite with expected outcomes
///   cotabby-spell --repl                               type lines, see decisions
///   cotabby-spell --bench                              per-keystroke latency over the suite
///
/// Options: --jev (uses TYPESAFE_API_KEY and waits for the second pass), --jev-mock (a fake Jev
/// that backs the first option, to exercise the second pass offline), --no-auto, --no-context,
/// --personal typo=word:count, --verbose.

@MainActor
struct Harness {
    let dependencies: SpellingEngineDependencies
    let refiner: WordIntentRefiner?
    let settings: TypoGate.Settings

    static func make(arguments: Arguments) throws -> Harness {
        let root = arguments.resourceRoot
        let english = try String(contentsOf: root.appendingPathComponent("frequency_dictionary_en_82_765.txt"), encoding: .utf8)
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
        return Harness(
            dependencies: SpellingEngineDependencies(
                spellChecker: CurrentWordSpellChecker(),
                symSpellCorrector: corrector,
                languageResolver: SpellingLanguageResolver(),
                enabledLanguages: { [.english] },
                memory: memory,
                bigrams: bigrams,
                refiner: refiner
            ),
            refiner: refiner,
            settings: TypoGate.Settings(
                suppressCompletionsOnTypo: true,
                offerTypoCorrections: true,
                automaticallyFixTypos: arguments.autoFix
            )
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
    var sentencesPath: String?
    var proofread: [String] = []
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
            case "--sentences": sentencesPath = iterator.next()
            case "--proofread": if let text = iterator.next() { proofread.append(text) }
            case "--repl": repl = true
            case "--bench": bench = true
            case "--jev": useJev = true
            case "--jev-mock": mockJev = true
            case "--no-context": useContext = false
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
func runAccuracy(_ path: String, harness: Harness) -> Int32 {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return 2 }
    var total = 0, top1 = 0, top3 = 0, found = 0
    var misses: [String] = []
    for line in contents.split(separator: "\n") where !line.hasPrefix("#") {
        let fields = line.split(separator: "\t")
        guard fields.count == 2 else { continue }
        let intended = String(fields[0]), typo = String(fields[1])
        total += 1
        let decision = harness.decide(CaretText("I think \(typo) ")).decision
        let list: [String]
        switch decision {
        case let .applyCorrection(_, fix), let .offerCorrection(_, fix): list = [fix]
        case let .offerChoices(_, items), let .offerRankedCorrection(_, items), let .offerRealWordFix(_, items):
            list = items.map(\.term)
        default: list = []
        }
        let lowered = list.map { $0.lowercased() }
        if !list.isEmpty { found += 1 }
        if lowered.first == intended.lowercased() { top1 += 1 }
        if lowered.prefix(3).contains(intended.lowercased()) {
            top3 += 1
        } else {
            misses.append("\(typo) → \(intended): got \(Render.decision(decision))")
        }
    }
    for miss in misses { print("MISS  " + miss) }
    func pct(_ n: Int) -> String { String(format: "%.0f%%", Double(n) * 100 / Double(max(total, 1))) }
    print("\(total) words  top-1 \(pct(top1))  top-3 \(pct(top3))  any suggestion \(pct(found))")
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
    for line in contents.split(separator: "\n") where !line.hasPrefix("#") {
        guard let tab = line.firstIndex(of: "\t") else { continue }
        let text = CaretText(String(line[line.index(after: tab)...])).before
        // Replay the line one keystroke at a time, like typing it.
        var typed = ""
        for character in text {
            typed.append(character)
            timings.append(harness.decide(CaretText(typed)).milliseconds)
        }
    }
    timings.sort()
    func percentile(_ p: Double) -> Double { timings[min(timings.count - 1, Int(Double(timings.count) * p))] }
    print(String(format: "%d keystrokes  p50 %.2f ms  p95 %.2f ms  p99 %.2f ms  max %.2f ms",
                 timings.count, percentile(0.5), percentile(0.95), percentile(0.99), timings.last ?? 0))
}

@MainActor
func show(_ input: CaretText, harness: Harness) async {
    let outcomes = await harness.decideWithRefinement(input)
    for (index, outcome) in outcomes.enumerated() {
        let source = index == 0 ? "local" : "jev \(harness.refiner?.lastLatencyMilliseconds ?? 0)ms"
        print("\(input.display)  →  \(Render.decision(outcome.decision))   (\(source), \(String(format: "%.2f", outcome.milliseconds)) ms)")
    }
}

@MainActor
func main() async -> Int32 {
    let arguments = Arguments(CommandLine.arguments)
    let harness: Harness
    do {
        harness = try Harness.make(arguments: arguments)
    } catch {
        print("could not load dictionaries from \(arguments.resourceRoot.path): \(error.localizedDescription)")
        return 2
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
