import Foundation

/// File overview:
/// Turns the text before the caret into up to five likely words: the next word after a space, or
/// completions of the word being typed. Picking one types the rest of the word plus a space, and the
/// list immediately predicts the word after that, so a sentence can be built by picking one word at
/// a time instead of spelling each out.
///
/// Scoring is "stupid backoff" over the bundled n-gram table (`NextWordModel`): a word seen after the
/// last three words scores its relative frequency there; one only seen after the last two scores
/// 0.4 times its frequency there; and so on down to single-word frequencies. The writer's own
/// phrases (`PersonalPhraseModel`) are scored the same way with a boost. Pure: all data arrives
/// through `Sources`, so the CLI and tests run exactly this logic.
nonisolated struct NextWordPrediction: Equatable, Sendable {
    /// The part of the current word already typed ("" after a space).
    let prefix: String
    /// Best first, recased for where they will land.
    let words: [String]
}

nonisolated enum NextWordPredictor {
    struct Sources {
        let model: NextWordModel
        /// Dictionary words starting with a prefix, most frequent first (fills a short list).
        let completions: (_ prefix: String, _ limit: Int) -> [String]
        /// The writer's own counts after a context of one or more words, if any.
        let personal: (_ context: [String]) -> (total: Int, counts: [String: Int])?
        /// The writer's own words starting with a non-empty prefix, with their total word count.
        var personalWords: (_ prefix: String) -> (total: Int, counts: [String: Int])? = { _ in nil }
        /// Words whose beginning is a slip or two from the typed letters (`necc` → necessary), most
        /// frequent first, so the word stays in the strip after a misspelling creeps into the prefix.
        var fuzzyCompletions: (_ prefix: String, _ limit: Int) -> [String] = { _, _ in [] }
        /// Words people commonly misspell; picking one also saves the fix that typing it would need.
        var isHardToSpell: (String) -> Bool = { _ in false }
        /// The language model's answer for exactly this text before the caret, when it has one
        /// (`WordLanguageModelService`). Nil while it is still working or not installed, and the
        /// list then comes from the table alone.
        var languageModel: (_ textBefore: String) -> LanguageModelScores? = { _ in nil }
        /// How the language model's answer and the table are combined. The app uses the defaults;
        /// the harness varies them to measure (`Tools/prediction/README.md`).
        var mix = LanguageModelMix()
    }

    /// The numbers that combine the language model with the table.
    struct LanguageModelMix: Equatable, Sendable {
        /// A word's score is the model's log-probability plus this much of the table's log score.
        /// The model reads the whole text and decides; the table adds what it has counted for the
        /// exact last words and the writer's own phrases. Small: on the tuning passages 0.05 was as
        /// good as or better than 0.15 and 0.3 with all three models the app can use.
        var tableWeight = 0.05
        /// Stands in for the table score of a word the table never saw here, so its log is finite.
        var tableFloor = 1e-6
        /// How many of the model's own best words join the table's candidates.
        var modelCandidates = 12
        /// What a word that does not start with the typed letters is multiplied by. The letters
        /// typed are strong evidence: `smalle` is `smaller`, not the far more common `small`. Only
        /// when nothing likely starts with them (`necc`, `wich`) should a near miss come first, and
        /// then it is likelier by far more than this. 0.5 (the table's own penalty) cost four
        /// points of first-suggestion accuracy from four letters on; 0.00001 cost five points of
        /// "still offers the word after a misspelled start".
        var slipPenalty = 0.005
    }

    static let maximumWords = 5
    static let maximumContext = 3
    static let backoff = 0.4
    /// The writer's phrases score like corpus evidence at the same context length; the prior below
    /// is what keeps a handful of uses from dominating. Tuned with `cotabby-spell --ksr --adaptive`:
    /// boost 1.0 / prior 6 gave the best keystroke savings (58.6% vs 56.4% without learning) with no
    /// loss of top-1 accuracy; a stronger boost cost top-1.
    static let personalBoost = 1.0
    /// Pseudo-count added to the writer's context totals: one "to the" in their history must not
    /// read as "the always follows to" and outrank what the corpus knows after "would like to".
    /// Their phrasing takes over as it repeats.
    static let personalPrior = 6.0
    /// Keys a pick costs, for ordering by keys saved (Tab for the first slot).
    static let pickCost = 1.0
    /// Slips in the prefix are only forgiven from this many letters, when the intent is clear enough.
    static let fuzzyMinimumPrefix = 3
    static let fuzzyLimit = 10
    static let fuzzyPenalty = 0.5
    /// Extra value, in keys, of picking a commonly misspelled word: the correction avoided.
    static let hardWordBonusKeys = 3.0
    static func predict(textBefore: String, sources: Sources) -> NextWordPrediction? {
        guard let parsed = parse(textBefore), !isOtherLanguage(textBefore, model: sources.model) else { return nil }
        let prefix = parsed.prefix.lowercased().replacingOccurrences(of: "’", with: "'")
        // Read `dont` and `becos` as the words they certainly are, so the context still matches.
        let contextWords = parsed.context.map { KnownMisspellings.fix(for: $0)?.lowercased() ?? $0 }
        let fuzzyWords = prefix.count >= fuzzyMinimumPrefix ? sources.fuzzyCompletions(prefix, fuzzyLimit) : []
        let fuzzy = Set(fuzzyWords.filter { !$0.hasPrefix(prefix) })
        var scores = backoffScores(context: contextWords, prefix: prefix, fuzzy: fuzzy, sources: sources)
            .filter { !UnofferedWords.contains($0.key) }
        scores.removeValue(forKey: prefix)
        if let languageModel = sources.languageModel(textBefore) {
            let words = wordsRanked(
                by: languageModel, tableScores: scores, prefix: prefix, fuzzyWords: fuzzyWords, mix: sources.mix
            )
            return prediction(words, parsed: parsed, textBefore: textBefore)
        }
        // Without the language model: order by expected keys saved, not raw likelihood. A pick
        // costs about one key, so a likely "a" (saves nothing) should not take the Tab slot from
        // "restaurant". Long, hard words the writer would otherwise have to spell move forward.
        let typedLength = prefix.count
        func value(_ word: String, _ score: Double) -> Double {
            let spellingRisk = sources.isHardToSpell(word) ? hardWordBonusKeys : 0
            return score * max(0.05, Double(word.count - typedLength + 1) - pickCost + spellingRisk)
        }
        // Which five come from likelihood (so the strip keeps covering what comes next); their order
        // comes from value, so the Tab slot goes to the pick worth the most keys.
        var words = scores
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(maximumWords)
            .map { (word: $0.key, value: value($0.key, $0.value)) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.word < $1.word }
            .map(\.word)
        if words.count < maximumWords, !prefix.isEmpty {
            for word in sources.completions(prefix, maximumWords * 2)
            where words.count < maximumWords && matches(word, prefix: prefix) && word != prefix
                && !words.contains(word) && !UnofferedWords.contains(word) {
                words.append(word)
            }
            for word in fuzzyWords
            where words.count < maximumWords && word != prefix && !words.contains(word) && !UnofferedWords.contains(word) {
                words.append(word)
            }
        }
        return prediction(words, parsed: parsed, textBefore: textBefore)
    }

    /// The list as it is shown: recased for where the word will land. Nil for an empty list.
    private static func prediction(_ words: [String], parsed: Parsed, textBefore: String) -> NextWordPrediction? {
        guard !words.isEmpty else { return nil }
        let atSentenceStart = parsed.context.last == NextWordModel.sentenceStart
        let shouting = isShouting(textBefore, typedPrefix: parsed.prefix)
        return NextWordPrediction(
            prefix: parsed.prefix,
            words: words.map {
                recase($0, typedPrefix: parsed.prefix, atSentenceStart: atSentenceStart, shouting: shouting)
            }
        )
    }

    /// The five likeliest words when the language model has an answer, likeliest first.
    ///
    /// Likeliest first, not "most keys saved" first: the model is right often enough that the first
    /// slot should simply be the word, and it is what makes the right verb form come before the
    /// wrong ones (`walked` before `walking` after `Yesterday I`).
    ///
    /// Candidates are everything the table scored for these letters, the model's own best words for
    /// them, and the forgiven misspelled starts. A word the model's dictionary does not have (a name
    /// the writer taught Cotabby) is scored by the table alone.
    private static func wordsRanked(
        by languageModel: LanguageModelScores,
        tableScores: [String: Double],
        prefix: String,
        fuzzyWords: [String],
        mix: LanguageModelMix
    ) -> [String] {
        var scores: [String: Double] = [:]
        scores.reserveCapacity(tableScores.count + mix.modelCandidates)
        let slip = log(mix.slipPenalty)
        // A word more than a letter shorter than what is typed would mean the writer typed letters
        // that belong to no word (`with` for `withou`); that is not a slip worth offering.
        func isOffered(_ word: String) -> Bool {
            word.hasPrefix(prefix) || word.count >= prefix.count - 1
        }
        func likelihood(of word: String, orElse fallback: Double) -> Double {
            let known = languageModel.logProbability(of: word).map(Double.init) ?? -.infinity
            return (known > -.infinity ? known : fallback) + (word.hasPrefix(prefix) ? 0 : slip)
        }
        for (word, table) in tableScores where isOffered(word) {
            // The table already scaled a near miss down; that was tuned for the table alone and is
            // undone here so the slip is charged once.
            let counted = word.hasPrefix(prefix) ? table : table / fuzzyPenalty
            scores[word] = likelihood(of: word, orElse: log(counted)) + mix.tableWeight * log(counted + mix.tableFloor)
        }
        let unseen = mix.tableWeight * log(mix.tableFloor)
        for candidate in languageModel.best(prefix: prefix, limit: mix.modelCandidates)
        where scores[candidate.word] == nil && candidate.word != prefix && !UnofferedWords.contains(candidate.word) {
            scores[candidate.word] = Double(candidate.logProbability) + unseen
        }
        for word in fuzzyWords
        where scores[word] == nil && word != prefix && isOffered(word) && !UnofferedWords.contains(word) {
            scores[word] = likelihood(of: word, orElse: -.infinity) + unseen
        }
        return scores
            .filter { $0.value > -.infinity }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(maximumWords)
            .map(\.key)
    }

    /// Stupid-backoff scores for every word that fits the typed prefix (or is a forgiven slip of it)
    /// after each context length, from the table and the writer's own phrases.
    private static func backoffScores(
        context contextWords: [String],
        prefix: String,
        fuzzy: Set<String>,
        sources: Sources
    ) -> [String: Double] {
        var scores: [String: Double] = [:]
        for length in stride(from: min(maximumContext, contextWords.count), through: 0, by: -1) {
            let context = Array(contextWords.suffix(length))
            let weight = pow(backoff, Double(maximumContext - length))
            if let found = sources.model.nextWords(after: context) {
                for entry in found.entries {
                    let exact = matches(entry.word, prefix: prefix)
                    guard exact || fuzzy.contains(entry.word) else { continue }
                    // A word reached only by forgiving a slip in the prefix counts for less.
                    let score = weight * Double(entry.count) / Double(found.total) * (exact ? 1 : fuzzyPenalty)
                    scores[entry.word] = max(scores[entry.word] ?? 0, score)
                }
            }
            let mine = length > 0 ? sources.personal(context) : prefix.isEmpty ? nil : sources.personalWords(prefix)
            if let mine {
                for (word, count) in mine.counts where matches(word, prefix: prefix) {
                    let score = personalBoost * weight * Double(count) / (Double(mine.total) + personalPrior)
                    scores[word] = max(scores[word] ?? 0, score)
                }
            }
        }
        return scores
    }

    /// True when the writer is typing in another language, where English predictions are noise: at
    /// least two of the last four words are neither in the English table nor capitalized names, or
    /// are written in another script. One foreign name (`Cancún`) in an English sentence does not count.
    static func isOtherLanguage(_ text: String, model: NextWordModel) -> Bool {
        // Only finished words count: the word being typed is usually just unfinished, not foreign.
        let finished = text.last?.isWhitespace == true ? Substring(text) : text.dropLast(text.reversed().prefix { !$0.isWhitespace }.count)
        let recent = finished.split(whereSeparator: { $0.isWhitespace }).suffix(4)
        let foreign = recent.filter { raw in
            let word = raw.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard let first = word.first, word.contains(where: \.isLetter) else { return false }
            // Another script is another language whatever its case; Latin letters with accents are
            // often names in English text, so only lowercase ones count.
            if word.unicodeScalars.contains(where: { $0.properties.isAlphabetic && $0.value > 0x24F }) { return true }
            if word.unicodeScalars.contains(where: { $0.properties.isAlphabetic && !$0.isASCII }) {
                return !first.isUppercase
            }
            let lowered = word.lowercased().replacingOccurrences(of: "’", with: "'")
            return !first.isUppercase && !model.contains(lowered) && KnownMisspellings.fix(for: lowered) == nil
        }
        return foreign.count >= 2
    }

    /// How likely `word` is to come next after `textBefore` (which should end at a word boundary),
    /// by the same backoff as `predict`, from the bundled table only. 0 when the table never saw it
    /// there. The spelling ranker uses this to prefer the fix that fits the sentence.
    static func contextScore(of word: String, after textBefore: String, model: NextWordModel) -> Double {
        let text = textBefore.last.map { $0.isWhitespace } == false ? textBefore + " " : textBefore
        guard let parsed = parse(text) else { return 0 }
        let target = word.lowercased()
        let contextWords = parsed.context.map { KnownMisspellings.fix(for: $0)?.lowercased() ?? $0 }
        var best = 0.0
        for length in stride(from: min(maximumContext, contextWords.count), through: 1, by: -1) {
            guard let found = model.nextWords(after: Array(contextWords.suffix(length))),
                  let entry = found.entries.first(where: { $0.word == target }) else { continue }
            best = max(best, pow(backoff, Double(maximumContext - length)) * Double(entry.count) / Double(found.total))
        }
        return best
    }

    private static func matches(_ word: String, prefix: String) -> Bool {
        !word.hasPrefix("<") && word.hasPrefix(prefix)
    }

    // MARK: - Reading the text

    private struct Parsed {
        let context: [String]
        let prefix: String
    }

    /// The last words of the current sentence (names and numbers as classes) and the partial word.
    private static func parse(_ text: String) -> Parsed? {
        var body = Substring(text)
        var prefix = ""
        if let last = body.last, last.isLetter || last == "'" || last == "’" {
            var start = body.endIndex
            while start > body.startIndex {
                let previous = body.index(before: start)
                let character = body[previous]
                guard character.isLetter || character == "'" || character == "’" else { break }
                start = previous
            }
            prefix = String(body[start...])
            body = body[..<start]
            // Directly after a symbol or digit (`@jo`, `3rd`) the "word" is not prose.
            if let before = body.last, !before.isWhitespace, !"\"(“‘-".contains(before) { return nil }
        } else if let last = body.last, !last.isWhitespace {
            return nil
        }
        let sentenceStart = body.lastIndex { ".!?\n".contains($0) }.map { body.index(after: $0) } ?? body.startIndex
        let context = contextTokens(of: body[sentenceStart...])
        return Parsed(context: Array(context.suffix(maximumContext)), prefix: prefix)
    }

    /// One sentence as the model sees it: `<s>`, then lowercased words with names and numbers as
    /// classes. The personal phrase model learns in exactly this form.
    static func contextTokens(of sentence: some StringProtocol) -> [String] {
        [NextWordModel.sentenceStart] + tokens(in: Substring(sentence)).enumerated().map { position, raw in
            classify(raw, position: position)
        }
    }

    /// Words (letters with inner apostrophes) and digit runs, like the builder's
    /// `[A-Za-z]+(?:['’][A-Za-z]+)*|\d+`.
    static func tokens(in text: Substring) -> [String] {
        var result: [String] = []
        var current = ""
        var pendingApostrophe = false
        func flush() {
            if !current.isEmpty { result.append(current) }
            current = ""
            pendingApostrophe = false
        }
        for character in text {
            if character.isASCII, character.isLetter {
                if let last = current.last, last.isNumber { flush() }
                if pendingApostrophe { current.append("'") }
                pendingApostrophe = false
                current.append(character)
            } else if character.isASCII, character.isNumber {
                if let last = current.last, !last.isNumber { flush() }
                current.append(character)
            } else if character == "'" || character == "’", current.last?.isLetter == true, !pendingApostrophe {
                pendingApostrophe = true
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    /// Same rule the model was built with: a capitalized word mid-sentence (other than I) is a name.
    private static func classify(_ raw: String, position: Int) -> String {
        if raw.allSatisfy(\.isNumber) { return NextWordModel.number }
        if position > 0, raw.first?.isUppercase == true, !isAllCaps(raw), raw != "I", !raw.hasPrefix("I'"), !raw.hasPrefix("I’") {
            return NextWordModel.name
        }
        return raw.lowercased().replacingOccurrences(of: "’", with: "'")
    }

    /// Two or more letters, all capitals: shouting or caps lock, not a name.
    private static func isAllCaps(_ raw: String) -> Bool {
        raw.filter(\.isLetter).count >= 2 && raw == raw.uppercased()
    }

    /// The writer is typing in capitals: the last finished word is all caps and what they have typed
    /// of this one is too.
    private static func isShouting(_ textBefore: String, typedPrefix: String) -> Bool {
        let body = textBefore.dropLast(typedPrefix.count)
        guard let last = body.split(whereSeparator: { !$0.isLetter && $0 != "'" }).last else { return false }
        return isAllCaps(String(last)) && typedPrefix == typedPrefix.uppercased()
    }

    private static func recase(_ word: String, typedPrefix: String, atSentenceStart: Bool, shouting: Bool) -> String {
        if shouting { return word.uppercased() }
        if word == "i" || word.hasPrefix("i'") { return "I" + word.dropFirst() }
        let capitalize = atSentenceStart && typedPrefix.isEmpty || typedPrefix.first?.isUppercase == true
        return capitalize ? word.prefix(1).uppercased() + word.dropFirst() : word
    }
}
