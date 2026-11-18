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
        /// English words the n-gram table has no entry for (`prediction_words_en.txt`: `neighbor`,
        /// `dataset`). Without this, two of them in a row read as another language and the strip
        /// went quiet.
        var isKnownWord: (String) -> Bool = { _ in false }
        /// How a word is usually written when not in lowercase (`github` → `GitHub`, `json` →
        /// `JSON`), for words the lists hold in lowercase. The writer's own spelling of a word in
        /// the text still comes first.
        var usualCapitals: (String) -> String? = { _ in nil }
        /// Set where the writer spells the American way: `travelling` is offered as `traveling`,
        /// once. Nil offers whatever the lists hold.
        var americanSpellings: AmericanSpellings?
        /// How many words the writer has typed in everything learned from them so far.
        var personalTotal: () -> Int = { 0 }
        /// On how many separate occasions the writer has used a word (`PersonalPhraseModel.sitting`).
        /// A word typed fifty times in one of them has a spread of one: a burst, not yet a habit.
        var personalSpread: (String) -> Int = { _ in 0 }
        /// A word's count in the frequency dictionary (0: not in it), for comparing how often this
        /// writer uses a word with how often English does.
        var generalCount: (String) -> Int = { _ in 0 }
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
        /// What the writer's habits add to a word's score (`withWritersHabits`). Every number was
        /// chosen on five invented writers and checked on fifteen others, on general documents and
        /// on a day of one real writer's sentences (`Tools/prediction/README.md`).
        var habits = Habits()
    }

    /// How much the writer's own history may move a word (see `withWritersHabits`).
    struct Habits: Equatable, Sendable {
        /// Weight of the writer's rate of a word against its rate in general English. 0 turns the
        /// whole of it off, and the order is the model's.
        var rateWeight = 0.8
        /// Pseudo-count on both sides of that ratio: one use of a rare word is a hint, not a habit.
        var ratePrior = 2.0
        /// The least and the most the log-ratio may be. A common word the writer has not needed yet
        /// loses a little; no word gains without limit however often it was typed.
        var rateFloor = -0.5
        var rateCeiling = 4.0
        /// Uses of a word counted per occasion it was used on (a text in the test sets, half an
        /// hour of writing in the app), beyond what general English expects: a pasted page or one
        /// long afternoon on one subject does not become a lasting habit.
        var usesCountedPerText = 3.0
        /// Weight of ln(1 + times the writer typed this word after the last word), and after the
        /// last two or three, which is surer evidence and weighs more.
        var phraseWeight = 0.75
        var longPhraseWeight = 2.0
        /// How often the writer must have written the words before for one sighting after them to
        /// count half: after `the`, which they write all day, one `the report` says little.
        var commonContext = 50.0
        /// What the phrase evidence is multiplied by before any letter is typed, when every word of
        /// the language is still possible and a few sightings prove least.
        var phraseTrustBeforeLetters = 0.5

        static let off = Habits(rateWeight: 0, phraseWeight: 0, longPhraseWeight: 0)
    }

    /// The sum of the counts in the bundled frequency dictionary, which turns a word's count into
    /// how often it comes up in general English.
    static let generalWordTotal = 541_808_760_578.0

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
        guard let inputs = inputs(textBefore: textBefore, sources: sources) else { return nil }
        let parsed = inputs.parsed, prefix = inputs.prefix, fuzzyWords = inputs.fuzzyWords, scores = inputs.tableScores
        if let languageModel = sources.languageModel(textBefore) {
            let candidates = candidateScores(
                by: languageModel, tableScores: scores, prefix: prefix, fuzzyWords: fuzzyWords, mix: sources.mix
            )
            let ranked = wordsRanked(withWritersHabits(candidates, prefix: prefix, context: inputs.context, sources: sources))
            let words = inPreferredSpelling(ranked, prefix: prefix, sources: sources)
            return prediction(words, parsed: parsed, textBefore: textBefore) {
                languageModel.display(of: $0) ?? sources.usualCapitals($0)
            }
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
        return prediction(
            inPreferredSpelling(words, prefix: prefix, sources: sources), parsed: parsed, textBefore: textBefore,
            display: sources.usualCapitals
        )
    }

    /// What both orderings start from: the letters typed, the words before them, and the table's
    /// score for every word that fits.
    private struct Inputs {
        let parsed: Parsed
        let prefix: String
        let context: [String]
        let fuzzyWords: [String]
        let tableScores: [String: Double]
    }

    private static func inputs(textBefore: String, sources: Sources) -> Inputs? {
        guard let parsed = parse(textBefore),
              !isOtherLanguage(textBefore, model: sources.model, isKnownWord: sources.isKnownWord) else { return nil }
        let prefix = parsed.prefix.lowercased().replacingOccurrences(of: "’", with: "'")
        // Read `dont` and `becos` as the words they certainly are, so the context still matches.
        let contextWords = parsed.context.map { KnownMisspellings.fix(for: $0)?.lowercased() ?? $0 }
        let fuzzyWords = prefix.count >= fuzzyMinimumPrefix ? sources.fuzzyCompletions(prefix, fuzzyLimit) : []
        let fuzzy = Set(fuzzyWords.filter { !$0.hasPrefix(prefix) })
        var scores = backoffScores(context: contextWords, prefix: prefix, fuzzy: fuzzy, sources: sources)
            .filter { !UnofferedWords.contains($0.key) }
        scores.removeValue(forKey: prefix)
        return Inputs(parsed: parsed, prefix: prefix, context: contextWords, fuzzyWords: fuzzyWords, tableScores: scores)
    }

    /// Every word the language model's ordering considers for this text, with its score before the
    /// writer's own word counts are mixed in. For `cotabby-spell` (`TYPING_MOMENTS`), which writes
    /// these down once so other ways of ordering them can be measured without running the model
    /// again. Nil when there is nothing to predict or the model has no answer.
    struct Candidates {
        let prefix: String
        /// The words before the caret as the tables key them, oldest first.
        let context: [String]
        let scores: [String: Double]
    }

    static func candidates(textBefore: String, sources: Sources) -> Candidates? {
        guard let inputs = inputs(textBefore: textBefore, sources: sources),
              let languageModel = sources.languageModel(textBefore) else { return nil }
        let scores = candidateScores(
            by: languageModel, tableScores: inputs.tableScores, prefix: inputs.prefix, fuzzyWords: inputs.fuzzyWords,
            mix: sources.mix
        )
        return Candidates(prefix: inputs.prefix, context: inputs.context, scores: scores)
    }

    /// The first five of `words` in the spelling the writer uses (see `AmericanSpellings`): a
    /// British spelling becomes the American one, a word then listed twice is listed once, and the
    /// letters typed are never offered back as the whole suggestion.
    private static func inPreferredSpelling(_ words: [String], prefix: String, sources: Sources) -> [String] {
        guard let spellings = sources.americanSpellings else { return Array(words.prefix(maximumWords)) }
        return Array(spellings.preferring(words).filter { $0 != prefix }.prefix(maximumWords))
    }

    /// The list as it is shown: recased for where the word will land. Nil for an empty list.
    ///
    /// - Parameter display: the writer's own spelling of a word found in the text (`Priyanka`,
    ///   `ETL`), which wins over the lowercase the lists hold.
    private static func prediction(
        _ words: [String], parsed: Parsed, textBefore: String, display: (String) -> String? = { _ in nil }
    ) -> NextWordPrediction? {
        guard !words.isEmpty else { return nil }
        let atSentenceStart = parsed.context.last == NextWordModel.sentenceStart
        let shouting = isShouting(textBefore, typedPrefix: parsed.prefix)
        return NextWordPrediction(
            prefix: parsed.prefix,
            words: words.map {
                recase(display($0) ?? $0, typedPrefix: parsed.prefix, atSentenceStart: atSentenceStart, shouting: shouting)
            }
        )
    }

    /// The five likeliest words when the language model has an answer, likeliest first.
    ///
    /// Likeliest first, not "most keys saved" first: the model is right often enough that the first
    /// slot should simply be the word, and it is what makes the right verb form come before the
    /// wrong ones (`walked` before `walking` after `Yesterday I`).
    private static func wordsRanked(_ scores: [String: Double]) -> [String] {
        scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            // A few more than are shown: two spellings of one word may fold into one slot.
            .prefix(maximumWords + 3)
            .map(\.key)
    }

    /// The score of every candidate: the model's log-probability plus a little of the table's.
    ///
    /// Candidates are everything the table scored for these letters, the model's own best words for
    /// them, and the forgiven misspelled starts. A word the model's dictionary does not have (a name
    /// the writer taught Cotabby) is scored by the table alone.
    private static func candidateScores(
        by languageModel: LanguageModelScores,
        tableScores: [String: Double],
        prefix: String,
        fuzzyWords: [String],
        mix: LanguageModelMix
    ) -> [String: Double] {
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
        // The writer's own words from this text (a name, a term): no table has counted them, and
        // the model that just read them knows how likely each is to come again.
        for candidate in languageModel.textWords(prefix: prefix)
        where candidate.word != prefix && !UnofferedWords.contains(candidate.word) {
            scores[candidate.word] = max(scores[candidate.word] ?? -.infinity, Double(candidate.logProbability) + unseen)
        }
        return scores.filter { $0.value > -.infinity }
    }

    /// The candidates' scores with what this writer's own history says about each word added.
    ///
    /// Why: the model knows the language and the text in front of it, not the writer. Someone who
    /// writes `replay`, `partition` and `backfill` all day got `really`, `people` and `because` after
    /// the first letter, because those are likelier in general. The writer's counts used to reach
    /// the order only through the table's twentieth of a weight, which can move a word by a factor
    /// of two at most, where the model's candidates differ by factors of twenty.
    ///
    /// Two kinds of evidence are added to the model's log-probability, both in the same unit, so a
    /// habit can settle a close call and never overturn a model that is sure:
    ///
    /// - **Their rate of the word against English's**, once a letter is typed:
    ///   `ln((uses + prior) / (expected + prior))`, where `expected` is how often general English
    ///   would have used the word in as many words as the writer has typed. A word they use far
    ///   more than English does (the terms of their trade) gains; `the`, which everyone uses,
    ///   gains nothing, however often they typed it. Counting raw uses instead (the first attempt)
    ///   mostly boosted the common words the model already had right.
    /// - **What they wrote after the same words**: `ln(1 + sightings)` for the last word, and with
    ///   more weight for the last two and three. A sighting counts for less after words they write
    ///   constantly, and a word counts at most once per text it appeared in.
    ///
    /// Why added to the score and not mixed as shares of probability: the counts see one to three
    /// words, the model the whole text. As a share, four sightings could outvote a model that was
    /// nearly certain, which cost general text a full point of first-suggestion accuracy; as a few
    /// tenths of a nat to about two, they decide only where the model was undecided.
    ///
    /// With nothing learned the scores come back unchanged.
    static func withWritersHabits(
        _ scores: [String: Double], prefix: String, context: [String], sources: Sources
    ) -> [String: Double] {
        let habits = sources.mix.habits
        let typedWords = Double(sources.personalTotal())
        guard typedWords > 0, habits.rateWeight > 0 || habits.phraseWeight > 0 || habits.longPhraseWeight > 0 else { return scores }
        let own = prefix.isEmpty || habits.rateWeight <= 0 ? nil : sources.personalWords(prefix)?.counts
        let after = (1...maximumContext).map { length in
            context.count >= length ? sources.personal(Array(context.suffix(length))) : nil
        }
        let phraseTrust = prefix.isEmpty ? habits.phraseTrustBeforeLetters : 1
        var result = scores
        for word in scores.keys {
            var gain = 0.0
            // Asked for only where a count needs it: most candidates were never typed by the writer.
            var knownSpread: Double?
            func spread() -> Double {
                if let knownSpread { return knownSpread }
                let value = Double(sources.personalSpread(word))
                knownSpread = value
                return value
            }
            if !prefix.isEmpty, habits.rateWeight > 0 {
                let expected = typedWords * Double(max(sources.generalCount(word), 1)) / generalWordTotal
                var uses = Double(own?[word] ?? 0)
                if uses > 0 { uses = min(uses, expected + habits.usesCountedPerText * spread()) }
                let ratio = log((uses + habits.ratePrior) / (expected + habits.ratePrior))
                gain += habits.rateWeight * min(habits.rateCeiling, max(habits.rateFloor, ratio))
            }
            for (index, found) in after.enumerated() {
                guard let found, let count = found.counts[word], count > 0 else { continue }
                let sightings = min(Double(count), spread())
                let weight = index == 0 ? habits.phraseWeight : habits.longPhraseWeight
                gain += phraseTrust * weight * log1p(sightings * habits.commonContext / (habits.commonContext + Double(found.total)))
            }
            if gain != 0 { result[word] = (result[word] ?? 0) + gain }
        }
        return result
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
    static func isOtherLanguage(
        _ text: String, model: NextWordModel, isKnownWord: (String) -> Bool = { _ in false }
    ) -> Bool {
        // Only finished words count: the word being typed is usually just unfinished, not foreign.
        let finished = text.last?.isWhitespace == true ? Substring(text) : text.dropLast(text.reversed().prefix { !$0.isWhitespace }.count)
        let recent = lastWords(of: finished, count: 4)
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
            return !first.isUppercase && !model.contains(lowered) && !isKnownWord(lowered)
                && KnownMisspellings.fix(for: lowered) == nil
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
        var joinsAfterDot = false
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
            // Directly after a symbol or digit (`@jo`, `3rd`) the "word" is not prose. After a dot
            // or a slash it is, when the token is plain words joined by it (`users.na`, `read/wr`).
            if let before = body.last, !before.isWhitespace, !"\"(“‘-".contains(before) {
                guard CurrentWordExtractor.endsInJoinedWords(text) else { return nil }
                joinsAfterDot = before == "."
            }
        } else if let last = body.last, !last.isWhitespace {
            // Right after a slash or a hyphen the next word is suggested as after a space. After a
            // dot it is not: that dot is nearly always the end of a sentence, a space away from
            // the next word.
            guard last == "/" || last == "-", CurrentWordExtractor.endsInJoinedWords(text) else { return nil }
        }
        if joinsAfterDot, let dot = body.indices.last {
            // The dot inside `users.na` is not the end of a sentence: the words before it are still
            // the context, and the next word does not start with a capital.
            body = body[..<dot] + " "
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
        let isWordCharacter: (Character) -> Bool = { $0.isLetter || $0 == "'" }
        // The word before the one being typed, found from the end: this runs on every key, and
        // splitting the whole text for its last piece cost more the longer the document got.
        let trimmed = body.reversed().drop { !isWordCharacter($0) }
        let last = String(trimmed.prefix(while: isWordCharacter).reversed())
        guard !last.isEmpty else { return false }
        return isAllCaps(last) && typedPrefix == typedPrefix.uppercased()
    }

    /// The last `count` whitespace-separated words of `text`, in order, read from the end so the
    /// cost does not depend on how long the text is.
    static func lastWords(of text: Substring, count: Int) -> [Substring] {
        var words: [Substring] = []
        var end = text.endIndex
        while words.count < count {
            while end > text.startIndex, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
            guard end > text.startIndex else { break }
            var start = end
            while start > text.startIndex, !text[text.index(before: start)].isWhitespace { start = text.index(before: start) }
            words.append(text[start..<end])
            end = start
        }
        return words.reversed()
    }

    private static func recase(_ word: String, typedPrefix: String, atSentenceStart: Bool, shouting: Bool) -> String {
        if shouting { return word.uppercased() }
        if word == "i" || word.hasPrefix("i'") { return "I" + word.dropFirst() }
        let capitalize = atSentenceStart && typedPrefix.isEmpty || typedPrefix.first?.isUppercase == true
        return capitalize ? word.prefix(1).uppercased() + word.dropFirst() : word
    }
}
