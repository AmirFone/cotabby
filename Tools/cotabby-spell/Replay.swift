import Foundation

/// File overview:
/// `cotabby-spell --replay <export.jsonl> [--sentence-model <model.gguf>] [--adapt] [--show]`
///
/// Replays a training export (Settings → Writing → Training Data → Export) through the engine as it
/// is now: each sentence is typed again word by word as the writer first typed it, fixes the engine
/// is sure of are made on the spot, then the sentence pass (the local rules, and the sentence model
/// when one is named) reads the finished sentence. What comes out is compared with what the writer
/// ended up with.
///
/// It answers "does the current engine work on what I really type?" with the writer's own slips,
/// which no generated test set contains. Without `--adapt` every sentence meets a fresh install.
/// With it the sentences are replayed in order and the engine is taught after each one what the app
/// would have learned from it: the fixes the writer picked or made, the words they kept, and their
/// own vocabulary. That is the state a writer is really in after a day of use.
///
/// It prints counts; `--show` adds the words (never whole sentences) that were missed or changed.
/// Nothing is written and nothing leaves the Mac. These sentences are for checking, not for tuning
/// against: a few hundred of one writer's sentences are far too few to set a threshold by.
///
/// Two things it cannot know, and how it treats them. An export from before 0.4.0 does not say what
/// stood before a sentence, so whether its first word should have a capital is unknown: words are
/// compared without regard to capitals, and capital-only changes are counted on their own line. And
/// a slip the writer never fixed is in the export as a word they "left as typed"; when the engine
/// fixes it, that is counted under changed words, where `--show` lets the reader tell the two apart.
@MainActor
struct ExportReplay {
    let harness: Harness
    let sentenceModel: LlamaTokenModel?
    let showsWords: Bool
    let adapts: Bool

    /// What happened to one word the writer changed.
    private enum Outcome: String, CaseIterable {
        case fixed = "fixed without asking"
        case offeredFirst = "offered, right word first"
        case offeredLower = "offered, right word lower"
        case wrong = "changed to another word"
        case missed = "left as typed, nothing offered"
    }

    private struct Tally {
        var outcomes: [Outcome: Int] = [:]
        var words: [Outcome: [String]] = [:]
        var total: Int { outcomes.values.reduce(0, +) }

        mutating func add(_ outcome: Outcome, _ description: String) {
            outcomes[outcome, default: 0] += 1
            words[outcome, default: []].append(description)
        }
    }

    /// A sentence after each stage of the replay.
    private struct Replayed {
        var afterTyping = ""
        var afterRules = ""
        var text = ""
        var offers: [Int: [String]] = [:]
    }

    func run(path: String) -> Int32 {
        guard let data = FileManager.default.contents(atPath: path) else {
            print("could not read \(path)")
            return 2
        }
        let rows = data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
        }
        var slips = Tally(), looseSlips = Tally()
        var sentences = 0, changedByWriter = 0, cameOutRight = 0, clean = 0, cleanUntouched = 0
        var keptWords = 0, capitalOnly = 0, unaligned = 0
        var changedKept: [String: [String]] = [:]
        // Words the writer left as typed that got a bar or a place on the review card: asked
        // about for nothing, unless it is a slip they never noticed.
        var askedAboutKept: [String: Int] = [:]

        for row in rows {
            guard let typed = row["typed"] as? String, let final = row["final"] as? String else { continue }
            defer { if adapts { learn(from: row, final: final) } }
            if row["scope"] as? String != "sentence" {
                scoreLooseWord(typed: typed, final: final, into: &looseSlips, changedKept: &changedKept)
                continue
            }
            sentences += 1
            let replayed = replay(typed, after: row["context"] as? String)
            let isSame = replayed.text.lowercased() == final.lowercased()
            if typed == final {
                clean += 1
                cleanUntouched += isSame ? 1 : 0
            } else {
                changedByWriter += 1
                cameOutRight += isSame ? 1 : 0
            }
            let typedWords = typed.split(separator: " "), finalWords = final.split(separator: " ")
            let outWords = replayed.text.split(separator: " ")
            guard typedWords.count == finalWords.count, outWords.count == finalWords.count else {
                unaligned += 1
                continue
            }
            let typingWords = replayed.afterTyping.split(separator: " "), rulesWords = replayed.afterRules.split(separator: " ")
            for index in typedWords.indices {
                let was = String(typedWords[index]), meant = String(finalWords[index]), got = String(outWords[index])
                if was == meant {
                    keptWords += 1
                    if got == meant, replayed.offers[index] != nil { askedAboutKept[Self.core(was), default: 0] += 1 }
                    guard got != meant else { continue }
                    guard got.lowercased() != meant.lowercased() else {
                        capitalOnly += 1
                        continue
                    }
                    let stage = typingWords.count == outWords.count && String(typingWords[index]) != was ? "while typing"
                        : rulesWords.count == outWords.count && String(rulesWords[index]) != was ? "by the sentence rules"
                        : "by the sentence model"
                    changedKept[stage, default: []].append("\(was) → \(got)")
                    continue
                }
                let offers = (replayed.offers[index] ?? []).map(Self.core)
                let outcome: Outcome = Self.core(got) == Self.core(meant) ? .fixed
                    : offers.first == Self.core(meant) ? .offeredFirst
                    : offers.contains(Self.core(meant)) ? .offeredLower
                    : Self.core(got) != Self.core(was) ? .wrong : .missed
                slips.add(outcome, "\(was) → \(meant)" + (outcome == .wrong ? " (got \(got))" : ""))
            }
        }

        let model = sentenceModel == nil ? "no sentence model named: local rules only" : "with the sentence model"
        print("\(sentences) sentences replayed, \(adapts ? "learning from each as the app would" : "each on a fresh install") (\(model))")
        print("  you changed something in \(changedByWriter); they came out as you left them, with no help from you, in \(share(cameOutRight, changedByWriter))")
        print("  you changed nothing in \(clean); left as typed in \(share(cleanUntouched, clean))")
        report("Words you fixed or accepted a fix for, in a sentence", slips)
        report("Fixes with no saved sentence (replayed after a neutral `I think`)", looseSlips)
        let changed = changedKept.values.reduce(0) { $0 + $1.count }
        print("\nWords you left as typed: \(keptWords); changed without asking: \(share(changed, keptWords))")
        print("  (some of these are slips you never fixed, which the engine now fixes; --show lists them)")
        for (stage, words) in changedKept.sorted(by: { $0.key < $1.key }) {
            print("  \(stage): \(words.count)")
            if showsWords { words.prefix(200).forEach { print("    \($0)") } }
        }
        print("  capital only (the text before each sentence is not in this export): \(capitalOnly)")
        let asked = askedAboutKept.values.reduce(0, +)
        print("  left alone but asked about (a bar or the review card): \(share(asked, keptWords)), \(askedAboutKept.count) different words")
        if showsWords {
            askedAboutKept.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(40)
                .forEach { print("    \($0.key) ×\($0.value)") }
        }
        if unaligned > 0 { print("\n\(unaligned) sentences whose word count changed are counted whole only, not word by word") }
        return 0
    }

    private func report(_ title: String, _ tally: Tally) {
        let first = (tally.outcomes[.fixed] ?? 0) + (tally.outcomes[.offeredFirst] ?? 0)
        print("\n\(title): \(tally.total)")
        for outcome in Outcome.allCases {
            print("  \(outcome.rawValue.padding(toLength: 32, withPad: " ", startingAt: 0)) \(share(tally.outcomes[outcome] ?? 0, tally.total))")
            if showsWords, outcome != .fixed {
                (tally.words[outcome] ?? []).prefix(60).forEach { print("    \($0)") }
            }
        }
        print("  right word made or shown first:  \(share(first, tally.total))")
    }

    private func share(_ part: Int, _ whole: Int) -> String {
        whole == 0 ? "none" : String(format: "%d of %d (%.1f%%)", part, whole, Double(part) * 100 / Double(whole))
    }

    /// The sentence typed again from its first word, with every fix the engine makes by itself, and
    /// what it offered for the words it only asked about (by word position).
    ///
    /// - Parameter context: the text that stood before the sentence, when the export has it (0.4.0
    ///   and later). The sentence is then typed after it, so a first word is capitalized only where
    ///   it really started a sentence; without it every sentence is typed into an empty field.
    private func replay(_ typed: String, after context: String? = nil) -> Replayed {
        var result = Replayed()
        let lead = context.map { $0.hasSuffix(" ") || $0.hasSuffix("\n") ? $0 : $0 + " " } ?? ""
        var text = lead
        for (index, word) in typed.split(separator: " ").enumerated() {
            text += word + " "
            let decision = harness.decide(CaretText(text)).decision
            if case let .applyCorrection(slip, fix) = decision, let edit = TypoCorrectionReplacementPlanner.plan(
                precedingText: text, expectedTypo: slip, correctedWord: fix, requiresTrailingSpace: true
            ) {
                text = String(text.dropLast(edit.backspaceCount)) + edit.replacementText
            } else {
                let offered = Self.offers(of: decision)
                if !offered.isEmpty { result.offers[index] = offered }
            }
        }
        result.afterTyping = String(text.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
        // The sentence pass: the local rules first, then the model, as in the app.
        let local = harness.proofread(result.afterTyping)
        note(local.flags, in: local.autoCorrected, into: &result.offers)
        result.afterRules = local.autoCorrected
        result.text = local.autoCorrected
        let checks = TypoGateInputs.sentenceChecks(dependencies: harness.dependencies, settings: harness.settings)
        let memory = harness.dependencies.memory, vocabulary = harness.vocabulary
        let corrector = harness.dependencies.symSpellCorrector
        let technical = harness.technicalTerms
        if let sentenceModel, let output = SentenceModelDecoder.correct(result.text, model: sentenceModel),
           let judged = SentenceModelGate.result(
               typed: result.text, output: output,
               isKnownWord: { !checks.isTypo($0) },
               words: SentenceModelGate.WordChecks(
                   isInDictionary: { corrector.isDictionaryWord($0.lowercased()) || vocabulary.preferredCasing(of: $0) != nil },
                   isWritersOwn: { memory?.isKept($0) == true || technical.contains($0.lowercased()) }
               )
           ) {
            note(judged.flags, in: judged.autoCorrected, into: &result.offers)
            result.text = judged.autoCorrected
        }
        return result
    }

    private static func offers(of decision: TypoGateDecision) -> [String] {
        switch decision {
        case let .offerCorrection(_, fix): return [fix]
        case let .offerChoices(_, list), let .offerRankedCorrection(_, list), let .offerRealWordFix(_, list):
            return list.map(\.term)
        default: return []
        }
    }

    private func note(_ flags: [SentenceFlag], in sentence: String, into offers: inout [Int: [String]]) {
        for flag in flags {
            let index = sentence[..<flag.range.lowerBound].filter { $0 == " " }.count
            offers[index] = (offers[index] ?? []) + flag.options
        }
    }

    /// A fix with no sentence: the word after a neutral start, so it is neither capitalized as a
    /// sentence start nor helped by a context it did not have.
    private func scoreLooseWord(typed: String, final: String, into tally: inout Tally, changedKept: inout [String: [String]]) {
        let decision = harness.decide(CaretText("I think \(typed) ")).decision
        var got = typed
        if case let .applyCorrection(_, fix) = decision { got = fix }
        let offers = Self.offers(of: decision).map(Self.core)
        let meant = Self.core(final)
        if Self.core(typed) == meant {
            if Self.core(got) != meant { changedKept["while typing", default: []].append("\(typed) → \(got)") }
            return
        }
        let outcome: Outcome = Self.core(got) == meant ? .fixed
            : offers.first == meant ? .offeredFirst
            : offers.contains(meant) ? .offeredLower
            : Self.core(got) != Self.core(typed) ? .wrong : .missed
        tally.add(outcome, "\(typed) → \(final)" + (outcome == .wrong ? " (got \(got))" : ""))
    }

    /// What the app would have learned from this example once the writer was done with it: fixes
    /// they picked, made, or let stand count for that fix next time; a fix they turned down marks
    /// the word as meant; and the finished sentence teaches their own words and phrasing.
    private func learn(from row: [String: Any], final: String) {
        let memory = harness.dependencies.memory
        for change in row["accepted"] as? [[String: Any]] ?? [] {
            guard let typed = change["typed"] as? String, let fix = change["fix"] as? String else { continue }
            memory?.recordAccepted(typo: Self.core(typed), replacement: Self.core(fix))
        }
        for change in row["rejected"] as? [[String: Any]] ?? [] {
            guard let typed = change["typed"] as? String else { continue }
            memory?.recordKept(Self.core(typed))
        }
        guard row["scope"] as? String == "sentence" else { return }
        let corrector = harness.dependencies.symSpellCorrector
        let checker = harness.dependencies.spellChecker
        let english = SpellingDictionaryLanguage.english.rawValue
        // As the app does when a line is finished: a flagged word left standing in it is counted,
        // and the third line makes it the writer's own.
        TypoGateInputs.wordsLeftStanding(in: final, dependencies: harness.dependencies, settings: harness.settings)
            .forEach { memory?.recordLeftStanding($0) }
        harness.vocabulary.learn(
            sentence: final,
            isDictionaryWord: { corrector.isDictionaryWord($0) },
            isAcceptedSpelling: { memory?.isKept($0) == true || !checker.isTypo($0, language: english) }
        )
        let vocabulary = harness.vocabulary
        harness.phrases.learn(sentence: final, vouching: PersonalPhraseModel.Vouching(
            isWord: { corrector.isDictionaryWord($0) || vocabulary.preferredCasing(of: $0) != nil || memory?.isKept($0) == true },
            isOwnName: { vocabulary.preferredCasing(of: $0) != nil }
        ))
    }

    /// A word lowercased and without the punctuation around it, for comparing an offer with it.
    private static func core(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }
}
