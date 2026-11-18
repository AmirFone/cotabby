import Foundation

/// File overview:
/// The pure half of the training record (`Services/Spelling/TrainingLog.swift` is the file half).
///
/// While the writer types, the log only appends small events as they happen: a sentence that was
/// finished and left standing, a word that was fixed or kept, a sentence fix that was kept or
/// undone, what the spelling engine decided about a word and with which candidates, and what the
/// word strip showed for each word. Nothing is worked out on the typing path. This file turns that
/// stream into what a model is trained on: one example per sentence with the sentence as first
/// typed, the sentence as it ended up, the fixes the writer accepted and rejected, and a timeline
/// of everything that happened on the way, in order, with the time between the steps.
///
/// Why the timeline: outcomes alone cannot be read backwards. "`thright` became `throughout` by a
/// pick" does not say what was offered first, how sure the engine was, or how many times the writer
/// typed past a wrong suggestion before that; a model that should learn from this writer needs
/// the cases where Cotabby was wrong or silent as much as the ones where it was right.
///
/// Why the examples are built at export time and not as the events arrive: the events for one
/// sentence do not arrive in order. A sentence fix is confirmed only when the writer types on, which
/// can be after the sentence was recorded, and an undo replaces a sentence that was already
/// written down. Joining once, over the whole stream, needs no amending of the file.

/// One line of the training log.
nonisolated enum TrainingLogEvent: Equatable, Sendable {
    /// A finished sentence that was still in the field, as written, a moment later. `day` is a
    /// calendar date (`2026-11-15`); the time of day is deliberately not kept. `context` is the
    /// text just before the sentence and `app` the bundle identifier of the app it was typed in,
    /// each present only when the writer left its own switch on.
    case sentence(text: String, day: String, context: String? = nil, app: String? = nil)
    /// What happened to one word. `how` is a `CorrectionJournal.Kind` raw value; `offered` is the
    /// fix the writer turned down, when there was one.
    case word(how: String, typed: String, final: String, offered: String?)
    /// A fix made to a whole finished sentence, kept (the writer typed on) or undone.
    case sentenceFix(original: String, corrected: String, kept: Bool)
    /// What the spelling engine decided about a word at the moment it decided, before the writer
    /// reacted: the outcome comes later as a `word` event.
    case decision(SpellingDecisionRecord)
    /// What the word strip showed for one word and whether the writer picked from it.
    case strip(StripUse)
    /// What the sentence model would change in a finished sentence, how sure it was of each word,
    /// and what was done about each: the "why" behind a sentence fix that was or was not made.
    case sentencePass(sentence: String, words: [SentencePassWord])
    /// Which build and models produced the events that follow, written once per launch.
    case session(version: String, stripModel: String?, hasSentenceModel: Bool)

    /// The event as the JSON object written to the file.
    var json: [String: Any] {
        switch self {
        case let .sentence(text, day, context, app):
            var object = ["event": "sentence", "text": text, "day": day]
            if let context { object["context"] = context }
            if let app { object["app"] = app }
            return object
        case let .decision(record):
            var object: [String: Any] = [
                "event": "decision", "typed": record.typed, "action": record.action, "before": record.before,
                "candidates": record.candidates.map { ["term": $0.term, "score": $0.score] as [String: Any] }
            ]
            if let confidence = record.confidence { object["confidence"] = confidence }
            return object
        case let .strip(use):
            var object: [String: Any] = [
                "event": "strip", "before": use.before, "word": use.word, "first": use.shownFirst,
                "last": use.shownLast, "letters": use.lettersTyped
            ]
            if let slot = use.pickedSlot { object["picked"] = slot }
            return object
        case let .sentencePass(sentence, words):
            return [
                "event": "sentencePass", "text": sentence,
                "words": words.map { ["typed": $0.typed, "written": $0.written, "p": $0.probability, "action": $0.action] as [String: Any] }
            ]
        case let .session(version, stripModel, hasSentenceModel):
            var object: [String: Any] = ["event": "session", "version": version, "sentenceModel": hasSentenceModel]
            if let stripModel { object["stripModel"] = stripModel }
            return object
        case let .word(how, typed, final, offered):
            var object = ["event": "word", "how": how, "typed": typed, "final": final]
            if let offered { object["offered"] = offered }
            return object
        case let .sentenceFix(original, corrected, kept):
            return ["event": "sentenceFix", "original": original, "corrected": corrected, "kept": kept]
        }
    }

    /// Nil for a line this build does not understand, which the builder then skips: a file written
    /// by a newer build must not make an export fail.
    init?(json: [String: Any]) {
        guard let event = Self.event(from: json) else { return nil }
        self = event
    }

    private static func event(from json: [String: Any]) -> TrainingLogEvent? {
        switch json["event"] as? String {
        case "sentence":
            guard let text = json["text"] as? String, let day = json["day"] as? String else { return nil }
            return .sentence(text: text, day: day, context: json["context"] as? String, app: json["app"] as? String)
        case "decision":
            return decision(from: json).map(TrainingLogEvent.decision)
        case "strip":
            return stripUse(from: json).map(TrainingLogEvent.strip)
        case "sentencePass":
            return sentencePass(from: json)
        case "session":
            guard let version = json["version"] as? String else { return nil }
            return .session(
                version: version, stripModel: json["stripModel"] as? String,
                hasSentenceModel: json["sentenceModel"] as? Bool ?? false
            )
        case "word", "sentenceFix":
            return outcome(from: json)
        default:
            return nil
        }
    }

    private static func sentencePass(from json: [String: Any]) -> TrainingLogEvent? {
        guard let text = json["text"] as? String else { return nil }
        let words = (json["words"] as? [[String: Any]] ?? []).compactMap { entry -> SentencePassWord? in
            guard let typed = entry["typed"] as? String, let written = entry["written"] as? String,
                  let action = entry["action"] as? String else { return nil }
            return SentencePassWord(
                typed: typed, written: written, probability: (entry["p"] as? NSNumber)?.doubleValue ?? 0, action: action
            )
        }
        return .sentencePass(sentence: text, words: words)
    }

    private static func stripUse(from json: [String: Any]) -> StripUse? {
        guard let word = json["word"] as? String else { return nil }
        return StripUse(
            before: json["before"] as? String ?? "", word: word,
            shownFirst: json["first"] as? [String] ?? [], shownLast: json["last"] as? [String] ?? [],
            lettersTyped: json["letters"] as? Int ?? 0, pickedSlot: json["picked"] as? Int
        )
    }

    private static func decision(from json: [String: Any]) -> SpellingDecisionRecord? {
        guard let typed = json["typed"] as? String, let action = json["action"] as? String else { return nil }
        let candidates = (json["candidates"] as? [[String: Any]] ?? []).compactMap { entry -> SpellingDecisionRecord.Candidate? in
            guard let term = entry["term"] as? String else { return nil }
            return .init(term: term, score: (entry["score"] as? NSNumber)?.doubleValue ?? 0)
        }
        return SpellingDecisionRecord(
            typed: typed, action: action, candidates: candidates,
            confidence: (json["confidence"] as? NSNumber)?.doubleValue, before: json["before"] as? String ?? ""
        )
    }

    /// The two events that say what became of a fix: one word's, or a whole sentence's.
    private static func outcome(from json: [String: Any]) -> TrainingLogEvent? {
        if json["event"] as? String == "word" {
            guard let how = json["how"] as? String, let typed = json["typed"] as? String,
                  let final = json["final"] as? String else { return nil }
            return .word(how: how, typed: typed, final: final, offered: json["offered"] as? String)
        }
        guard let original = json["original"] as? String, let corrected = json["corrected"] as? String,
              let kept = json["kept"] as? Bool else { return nil }
        return .sentenceFix(original: original, corrected: corrected, kept: kept)
    }
}

/// What the spelling engine decided about one word, with what it had to go on.
nonisolated struct SpellingDecisionRecord: Equatable, Sendable {
    struct Candidate: Equatable, Sendable {
        let term: String
        /// The engine's score for it (higher is better; not a probability).
        let score: Double
    }

    /// The word as typed.
    let typed: String
    /// `fixed` (changed without asking), `offered` (one fix on the bar), `offeredChoices` (several),
    /// `offeredWrongWord` (a real word that looks wrong here), or `held` (flagged, nothing offered).
    let action: String
    /// The candidates in the engine's order, best first (at most five).
    let candidates: [Candidate]
    /// The trained model's probability that the first candidate is what was meant, when it judged.
    let confidence: Double?
    /// The sentence so far, before the word.
    let before: String

    static let maximumCandidates = 5
}

/// One line of the log with where it stood in the stream: which launch wrote it, its place in that
/// launch's sequence, and the milliseconds since that launch's first line. The time is counted from
/// the launch on purpose; no clock time is kept.
nonisolated struct TrainingLogLine: Equatable, Sendable {
    struct Stamp: Equatable, Sendable {
        let run: String
        let order: Int
        let milliseconds: Int
    }

    let event: TrainingLogEvent
    let stamp: Stamp?

    init(_ event: TrainingLogEvent, stamp: Stamp? = nil) {
        self.event = event
        self.stamp = stamp
    }

    init?(json: [String: Any]) {
        guard let event = TrainingLogEvent(json: json) else { return nil }
        self.event = event
        if let run = json["run"] as? String, let order = json["n"] as? Int, let milliseconds = json["ms"] as? Int {
            stamp = Stamp(run: run, order: order, milliseconds: milliseconds)
        } else {
            stamp = nil
        }
    }

    var json: [String: Any] {
        var object = event.json
        if let stamp {
            object["run"] = stamp.run
            object["n"] = stamp.order
            object["ms"] = stamp.milliseconds
        }
        return object
    }
}

/// One exported training example. The field names are the file format: `typed` is the model's input,
/// `final` its target, and `accepted` / `rejected` say which changes the writer agreed with.
nonisolated struct TrainingExample: Codable, Equatable, Sendable {
    /// One step of what happened while the sentence was written, in order.
    struct Step: Codable, Equatable, Sendable {
        /// `strip` (what the word strip showed for a word), `decision` (what the spelling engine
        /// decided), `outcome` (what became of a word), `sentencePass` (what the sentence model
        /// would change and how sure it was), `sentenceFix` (a fix to the whole sentence).
        let kind: String
        /// Milliseconds since the first step of this example; nil for events from before timing
        /// was recorded or from another launch.
        var ms: Int?
        /// The sentence so far when it happened (`strip`, `decision`), or the whole sentence the
        /// model read (`sentencePass`).
        var before: String?
        /// The word as typed (`decision`, `outcome`) or as finished (`strip`).
        var word: String?
        /// What the word became (`outcome`), or the whole corrected sentence (`sentenceFix`).
        var final: String?
        /// `outcome`: the journal's kind (`autoFixKept`, `autoFixUndone`, `picked`, `keptAsTyped`,
        /// `selfCorrected`). `decision`: the action. `sentenceFix`: `kept` or `undone`.
        var how: String?
        /// `decision`: the candidates, best first. `outcome`: the fix that was turned down.
        var candidates: [String]?
        var scores: [Double]?
        var confidence: Double?
        /// `strip`: the words shown before any letter, and as they last stood.
        var shownFirst: [String]?
        var shownLast: [String]?
        var lettersTyped: Int?
        var pickedSlot: Int?
        /// `strip`: where the finished word stood in the last list shown (0 is first), nil when
        /// it was not listed: the one number that says whether the strip was right.
        var rank: Int?
        /// `sentencePass`: each word the model would change, its probability, and whether it was
        /// `fixed`, `asked` about, or `left`.
        var changes: [SentencePassWord]?
    }

    /// Which build and models wrote the example.
    struct Session: Codable, Equatable, Sendable {
        let version: String
        let stripModel: String?
        let hasSentenceModel: Bool
    }
    struct Change: Codable, Equatable, Sendable {
        /// The word as the writer typed it.
        let typed: String
        /// What it was changed to (accepted) or what was offered and turned down (rejected); nil
        /// when the writer kept their word and the offer was not recorded.
        let fix: String?
        /// Accepted: `autoFix` (changed for the writer, who typed on), `picked` (chosen from the bar
        /// or card), `selfCorrected` (retyped by the writer), `sentenceFix` (changed when the
        /// sentence was finished). Rejected: `autoFix` or `sentenceFix` that was undone, or
        /// `offered` (the writer kept their word from the bar or card).
        let how: String
    }

    /// `sentence`; `word` for a fix that could not be placed in a recorded sentence; `strip` or
    /// `decision` for one of those events that could not be placed either.
    let scope: String
    let day: String?
    let typed: String
    let final: String
    let accepted: [Change]
    let rejected: [Change]
    /// The text just before the sentence, when the writer lets it be saved.
    var context: String?
    /// The app it was typed in (bundle identifier), when the writer lets it be saved.
    var app: String?
    /// Everything recorded about the sentence in the order it happened; nil when there is nothing
    /// beyond what `accepted` and `rejected` already say.
    var steps: [Step]?
    var session: Session?
}

nonisolated enum TrainingExampleBuilder {
    /// The examples for a stream of log events, in the order the sentences were written.
    static func examples(from events: [TrainingLogEvent]) -> [TrainingExample] {
        examples(fromLines: events.map { TrainingLogLine($0) })
    }

    /// The same for lines read from the file, which also carry their place in the stream.
    static func examples(fromLines lines: [TrainingLogLine]) -> [TrainingExample] {
        var assembly = Assembly()
        for (position, line) in lines.enumerated() {
            let place = Place(position: position, stamp: line.stamp)
            switch line.event {
            case let .word(how, typed, final, offered):
                assembly.pendingWords.append(WordEvent(how: how, typed: typed, final: final, offered: offered, place: place))
            case let .sentence(text, day, context, app):
                assembly.addSentence(text, day: day, context: context, app: app, place: place)
            case let .sentenceFix(original, corrected, kept):
                if kept {
                    assembly.noteKeptFix(original: original, corrected: corrected, place: place)
                } else {
                    assembly.noteUndoneFix(original: original, corrected: corrected, place: place)
                }
            case let .decision(record):
                assembly.pendingDetails.append(Detail(decision: record, place: place))
            case let .strip(use):
                assembly.pendingDetails.append(Detail(strip: use, place: place))
            case let .sentencePass(sentence, words):
                assembly.pendingDetails.append(Detail(pass: SentencePass(sentence: sentence, words: words), place: place))
            case let .session(version, stripModel, hasSentenceModel):
                assembly.session = .init(version: version, stripModel: stripModel, hasSentenceModel: hasSentenceModel)
            }
        }
        assembly.placeWaitingDetails()
        let looseWords = assembly.pendingWords.map { assembly.looseDraft(for: $0) }
        return (assembly.drafts + looseWords + assembly.pendingDetails.map(Draft.init(detail:))).map(\.example)
    }

    /// Where a line stood in the stream.
    private struct Place {
        let position: Int
        let stamp: TrainingLogLine.Stamp?
    }

    /// The examples being put together while the events are read in order.
    private struct Assembly {
        var drafts: [Draft] = []
        /// Word events since the last sentence, waiting for the sentence they belong to.
        var pendingWords: [WordEvent] = []
        /// Decisions and strip uses waiting for their sentence. They are written while a sentence
        /// is typed and the sentence itself a moment after it is finished, by which time the first
        /// words of the next one may already be in the stream, so one that fits no sentence yet
        /// waits for the next few.
        var pendingDetails: [Detail] = []
        var session: TrainingExample.Session?
        /// Sentence-fix outcomes that arrived before the sentence they belong to was recorded.
        private var keptFixes: [String: (original: String, place: Place)] = [:]
        private var undoneFixes: [String: (corrected: String, place: Place)] = [:]

        /// A detail that has fitted none of this many sentences is exported on its own.
        private static let sentencesToWait = 3

        mutating func addSentence(_ text: String, day: String, context: String?, app: String?, place: Place) {
            var draft = Draft(final: text, day: day)
            draft.context = context
            draft.app = app
            draft.session = session
            if let kept = keptFixes.removeValue(forKey: text) {
                draft.beforeSentenceFix = kept.original
                draft.fixSteps.append(FixStep(place: kept.place, how: "kept", corrected: text))
            }
            if let undone = undoneFixes.removeValue(forKey: text) {
                draft.undoneSentenceFix = undone.corrected
                draft.fixSteps.append(FixStep(place: undone.place, how: "undone", corrected: undone.corrected))
            }
            drafts.append(draft)
            // A word event belongs to the sentence recorded after it; one that only fits the
            // sentence before (its outcome was settled late) goes there instead.
            for word in pendingWords {
                if TrainingExampleBuilder.attach(word, to: &drafts, at: drafts.count - 1) { continue }
                if drafts.count >= 2, TrainingExampleBuilder.attach(word, to: &drafts, at: drafts.count - 2) { continue }
                drafts.insert(looseDraft(for: word), at: drafts.count - 1)
            }
            pendingWords = []

            var waiting: [Detail] = []
            for var detail in pendingDetails {
                if let index = drafts.indices.suffix(2).reversed().first(where: { drafts[$0].holds(detail) }) {
                    drafts[index].details.append(detail)
                    continue
                }
                detail.sentencesSeen += 1
                if detail.sentencesSeen >= Self.sentencesToWait {
                    drafts.insert(Draft(detail: detail), at: drafts.count - 1)
                } else {
                    waiting.append(detail)
                }
            }
            pendingDetails = waiting
        }

        /// A word whose sentence was not saved (the line was never finished, or was too short or
        /// too long to keep) still has the engine's decision about it and what the strip showed,
        /// which hold the sentence so far. They go with the word, so the example says where the
        /// fix happened and is not a bare pair of words.
        mutating func looseDraft(for word: WordEvent) -> Draft {
            var draft = Draft(word: word)
            let typed = word.typed.lowercased()
            guard let index = pendingDetails.lastIndex(where: {
                $0.place.position < word.place.position && $0.decision?.typed.lowercased() == typed
            }) else { return draft }
            let decision = pendingDetails.remove(at: index)
            let forms = [typed, word.final.lowercased()]
            let strips = pendingDetails.filter { detail in
                detail.strip.map { $0.before == decision.before && forms.contains($0.word.lowercased()) } ?? false
            }
            pendingDetails.removeAll { detail in strips.contains { $0.place.position == detail.place.position } }
            draft.details = strips + [decision]
            return draft
        }

        /// At the end of the stream: a detail written after its sentence (the sentence model
        /// answers a moment after the sentence is recorded) has had no later sentence to be placed
        /// by, so the last sentences are tried once more before it is exported on its own.
        mutating func placeWaitingDetails() {
            pendingDetails = pendingDetails.filter { detail in
                guard let index = drafts.indices.suffix(2).reversed().first(where: { drafts[$0].holds(detail) }) else { return true }
                drafts[index].details.append(detail)
                return false
            }
        }

        mutating func noteKeptFix(original: String, corrected: String, place: Place) {
            if let index = drafts.lastIndex(where: { $0.final == corrected && $0.beforeSentenceFix == nil }) {
                drafts[index].beforeSentenceFix = original
                drafts[index].fixSteps.append(FixStep(place: place, how: "kept", corrected: corrected))
            } else {
                keptFixes[corrected] = (original, place)
            }
        }

        /// The corrected sentence may have been written down before the writer undid it; it is not
        /// what they meant. Its word events go back in line for the sentence as written.
        mutating func noteUndoneFix(original: String, corrected: String, place: Place) {
            if let index = drafts.lastIndex(where: { $0.final == corrected && !$0.isLoose }) {
                pendingWords = drafts[index].words + pendingWords
                pendingDetails = drafts[index].details + pendingDetails
                drafts.remove(at: index)
            }
            if let index = drafts.lastIndex(where: { $0.final == original && !$0.isLoose }) {
                drafts[index].undoneSentenceFix = corrected
                drafts[index].fixSteps.append(FixStep(place: place, how: "undone", corrected: corrected))
            } else {
                undoneFixes[original] = (corrected, place)
            }
        }
    }

    /// One JSON object per line, keys sorted so two exports of the same log are identical.
    static func jsonLines(_ examples: [TrainingExample]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return examples.compactMap { try? encoder.encode($0) }.reduce(into: Data()) { $0 += $1 + Data("\n".utf8) }
    }

    private struct WordEvent {
        let how: String
        let typed: String
        let final: String
        let offered: String?
        let place: Place

        /// The writer ended up with their own word: an undone automatic fix, or a word kept from
        /// the bar or card.
        var isRejection: Bool { typed == final }
    }

    /// The sentence model's pass over one finished sentence.
    private struct SentencePass {
        let sentence: String
        let words: [SentencePassWord]
    }

    /// A decision, a strip use or a sentence pass, waiting for or attached to its sentence.
    private struct Detail {
        var decision: SpellingDecisionRecord?
        var strip: StripUse?
        var pass: SentencePass?
        let place: Place
        var sentencesSeen = 0

        init(decision: SpellingDecisionRecord, place: Place) {
            self.decision = decision
            self.place = place
        }

        init(strip: StripUse, place: Place) {
            self.strip = strip
            self.place = place
        }

        init(pass: SentencePass, place: Place) {
            self.pass = pass
            self.place = place
        }

        var scope: String { pass != nil ? "sentencePass" : strip != nil ? "strip" : "decision" }

        var before: String { decision?.before ?? strip?.before ?? "" }
        var word: String { decision?.typed ?? strip?.word ?? "" }
        /// The word as typed, and what it may have become by the time the sentence was written.
        var forms: [String] { [word] + (decision?.candidates.map(\.term) ?? []) }
    }

    /// A sentence fix as a step: where it stood in the log, `kept` or `undone`, and the fixed text.
    private struct FixStep {
        let place: Place
        let how: String
        let corrected: String
    }

    private struct Draft {
        var final: String
        var day: String?
        var context: String?
        var app: String?
        var session: TrainingExample.Session?
        var words: [WordEvent] = []
        var details: [Detail] = []
        /// Sentence fixes in the order they were settled.
        var fixSteps: [FixStep] = []
        /// The sentence before a sentence fix the writer kept.
        var beforeSentenceFix: String?
        /// What a sentence fix would have made of this sentence, had the writer not undone it.
        var undoneSentenceFix: String?
        /// `word`, `strip`, `decision` or `sentencePass` for an event exported on its own; nil for
        /// a sentence.
        var looseScope: String?

        var isLoose: Bool { looseScope != nil }

        init(final: String, day: String) {
            self.final = final
            self.day = day
        }

        init(word: WordEvent) {
            final = word.final
            words = [word]
            looseScope = "word"
        }

        init(detail: Detail) {
            final = detail.pass?.sentence ?? detail.word
            details = [detail]
            looseScope = detail.scope
        }

        /// True when `detail` was recorded while this sentence was being written: the sentence so
        /// far, as the detail saw it, lines up with the words of this sentence just before the
        /// detail's own word.
        func holds(_ detail: Detail) -> Bool {
            guard !isLoose else { return false }
            if let pass = detail.pass { return holds(pass) }
            let before = TrainingExampleBuilder.words(of: detail.before)
            let forms = Set(detail.forms.flatMap { TrainingExampleBuilder.words(of: $0) })
            for sentence in [final, beforeSentenceFix].compactMap({ $0 }) {
                let tokens = TrainingExampleBuilder.words(of: sentence)
                // The sentence so far is kept whole unless it is very long, so the word normally
                // stands right after it; a cut one is looked for further along.
                let isCut = detail.before.count >= StripUseTracker.maximumBefore - 1
                let places = isCut ? Array(before.count..<max(before.count, tokens.count)) : [before.count]
                for place in places where place < tokens.count {
                    let matches = zip(before, tokens[(place - before.count)..<place]).filter { $0 == $1 }.count
                    let fitsBefore = before.isEmpty || Double(matches) >= 0.6 * Double(before.count)
                    // With nothing before it, only the word itself can place the detail.
                    if fitsBefore, !before.isEmpty || forms.contains(tokens[place]) { return true }
                }
            }
            return false
        }

        /// The sentence the model read is this one as typed: the same number of words, most of
        /// them the same (a kept fix or a pick from the review card changes a few).
        private func holds(_ pass: SentencePass) -> Bool {
            let read = TrainingExampleBuilder.words(of: pass.sentence)
            guard !read.isEmpty else { return false }
            return [final, beforeSentenceFix].compactMap { $0 }.contains { sentence in
                let tokens = TrainingExampleBuilder.words(of: sentence)
                return tokens.count == read.count
                    && Double(zip(read, tokens).filter { $0 == $1 }.count) >= 0.6 * Double(read.count)
            }
        }

        var example: TrainingExample {
            var accepted: [TrainingExample.Change] = []
            var rejected: [TrainingExample.Change] = []
            // Word-level fixes happened first, while the sentence was being typed, so they are
            // undone last: start from the sentence as it stood before any sentence fix.
            var typed = beforeSentenceFix ?? final
            for word in words {
                if word.isRejection {
                    let how = word.how == CorrectionJournal.Kind.autoFixUndone.rawValue ? "autoFix" : "offered"
                    rejected.append(.init(typed: word.typed, fix: word.offered, how: how))
                } else {
                    accepted.append(.init(typed: word.typed, fix: word.final, how: Self.acceptedHow(word.how)))
                    if !isLoose, let range = TrainingExampleBuilder.wholeWordRange(of: word.final, in: typed) {
                        // The word goes back as it was typed, under the capital it stands with.
                        let startsCapital = typed[range].first?.isUppercase == true && word.final.first?.isUppercase != true
                        let asTyped = startsCapital ? word.typed.prefix(1).uppercased() + word.typed.dropFirst() : word.typed
                        typed.replaceSubrange(range, with: asTyped)
                    }
                }
            }
            if looseScope == "word" { typed = words.first?.typed ?? final }
            if let beforeSentenceFix {
                accepted += TrainingExampleBuilder.changedWords(from: beforeSentenceFix, to: final)
                    .map { .init(typed: $0.typed, fix: $0.fixed, how: "sentenceFix") }
            }
            if let undoneSentenceFix {
                rejected += TrainingExampleBuilder.changedWords(from: final, to: undoneSentenceFix)
                    .map { .init(typed: $0.typed, fix: $0.fixed, how: "sentenceFix") }
            }
            var example = TrainingExample(
                scope: looseScope ?? "sentence", day: day, typed: typed, final: final,
                accepted: accepted, rejected: rejected
            )
            example.context = context
            example.app = app
            example.session = session
            example.steps = steps
            return example
        }

        /// Everything recorded for this example in the order it was written to the log, with the
        /// time since the first step. Nil when there are only outcomes without a place in time,
        /// which `accepted` and `rejected` already tell.
        private var steps: [TrainingExample.Step]? {
            guard !details.isEmpty || !fixSteps.isEmpty || words.contains(where: { $0.place.stamp != nil }) else { return nil }
            var placed: [(place: Place, step: TrainingExample.Step)] = []
            for word in words {
                var step = TrainingExample.Step(kind: "outcome")
                step.word = word.typed
                step.final = word.final
                step.how = word.how
                step.candidates = word.offered.map { [$0] }
                placed.append((word.place, step))
            }
            // What a word finally became, to say where the strip had the word that was meant.
            let becameByTyped = Dictionary(words.filter { !$0.isRejection }.map { ($0.typed.lowercased(), $0.final.lowercased()) }) { $1 }
            for detail in details {
                if let decision = detail.decision {
                    var step = TrainingExample.Step(kind: "decision")
                    step.before = decision.before
                    step.word = decision.typed
                    step.how = decision.action
                    step.candidates = decision.candidates.map(\.term)
                    step.scores = decision.candidates.map(\.score)
                    step.confidence = decision.confidence
                    placed.append((detail.place, step))
                } else if let pass = detail.pass {
                    var step = TrainingExample.Step(kind: "sentencePass")
                    step.before = pass.sentence
                    step.changes = pass.words
                    placed.append((detail.place, step))
                } else if let use = detail.strip {
                    var step = TrainingExample.Step(kind: "strip")
                    step.before = use.before
                    step.word = use.word
                    step.shownFirst = use.shownFirst
                    step.shownLast = use.shownLast
                    step.lettersTyped = use.lettersTyped
                    step.pickedSlot = use.pickedSlot
                    let meant = becameByTyped[use.word.lowercased()] ?? use.word.lowercased()
                    step.rank = use.shownLast.firstIndex { $0.lowercased() == meant }
                    placed.append((detail.place, step))
                }
            }
            for fix in fixSteps {
                var step = TrainingExample.Step(kind: "sentenceFix")
                step.how = fix.how
                step.final = fix.corrected
                placed.append((fix.place, step))
            }
            placed.sort { $0.place.position < $1.place.position }
            // Times are counted within one launch; a step from another launch gets none.
            let first = placed.first { $0.place.stamp != nil }?.place.stamp
            return placed.map { entry in
                var step = entry.step
                if let stamp = entry.place.stamp, let first, stamp.run == first.run {
                    step.ms = stamp.milliseconds - first.milliseconds
                }
                return step
            }
        }

        private static func acceptedHow(_ journalKind: String) -> String {
            switch CorrectionJournal.Kind(rawValue: journalKind) {
            case .autoFixKept: return "autoFix"
            case .selfCorrected: return "selfCorrected"
            default: return "picked"
            }
        }
    }

    /// Adds the event to the draft at `index` when its word is in that sentence. An accepted fix is
    /// looked for by what the word became, a rejected one by the word the writer kept.
    private static func attach(_ word: WordEvent, to drafts: inout [Draft], at index: Int) -> Bool {
        let draft = drafts[index]
        guard !draft.isLoose, wholeWordRange(of: word.final, in: draft.beforeSentenceFix ?? draft.final) != nil else {
            return false
        }
        drafts[index].words.append(word)
        return true
    }

    /// The words of `text`, lowercased and without the punctuation around them, for lining up two
    /// versions of a sentence.
    fileprivate static func words(of text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// The first place `word` stands in `text` with no letter or digit against either end, so `the`
    /// is not found inside `other`. `word` may itself be two words (`next door`). Capitals are
    /// not compared: a fix is recorded as the engine made it (`the`) and stands in the sentence
    /// as the writer's capitals left it (`The`).
    private static func wholeWordRange(of word: String, in text: String) -> Range<String.Index>? {
        guard !word.isEmpty else { return nil }
        var searchStart = text.startIndex
        while let range = text.range(of: word, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !isWordCharacter(before), !isWordCharacter(after) { return range }
            searchStart = text.index(after: range.lowerBound)
        }
        return nil
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        character.map { $0.isLetter || $0.isNumber } ?? false
    }

    /// The words that differ between two versions of a sentence, in the casing they were written.
    /// Empty when the versions do not have the same number of words (a word was split or joined):
    /// the sentence pair still carries the change, it is only not itemized.
    private static func changedWords(from original: String, to changed: String) -> [(typed: String, fixed: String)] {
        let before = original.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters) }
        let after = changed.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters) }
        guard before.count == after.count else { return [] }
        return zip(before, after).filter { $0 != $1 && !$0.isEmpty && !$1.isEmpty }.map { (typed: $0, fixed: $1) }
    }
}
