import XCTest
@testable import Cotabby

/// Turning the training log's event stream into exported examples.
final class TrainingExampleBuilderTests: XCTestCase {
    private let day = "2026-11-15"

    func test_untouchedSentence_isItsOwnTarget() {
        // #given a sentence nothing was offered for
        let events: [TrainingLogEvent] = [.sentence(text: "The meeting starts at noon.", day: day)]

        // #when examples are built
        let examples = TrainingExampleBuilder.examples(from: events)

        // #then typed and final are the same sentence, with no changes listed
        XCTAssertEqual(examples, [
            TrainingExample(
                scope: "sentence", day: day, typed: "The meeting starts at noon.",
                final: "The meeting starts at noon.", accepted: [], rejected: []
            )
        ])
    }

    func test_keptAutomaticFix_isPutBackIntoWhatWasTyped() {
        // #given a word fixed while typing, then the finished sentence
        let events: [TrainingLogEvent] = [
            .word(how: "autoFixKept", typed: "teh", final: "the", offered: nil),
            .sentence(text: "I saw the cat.", day: day)
        ]

        // #when examples are built
        let example = TrainingExampleBuilder.examples(from: events).first

        // #then the typed sentence has the misspelling back and the fix counts as accepted
        XCTAssertEqual(example?.typed, "I saw teh cat.")
        XCTAssertEqual(example?.final, "I saw the cat.")
        XCTAssertEqual(example?.accepted, [.init(typed: "teh", fix: "the", how: "autoFix")])
    }

    func test_fixedWord_isNotLookedForInsideOtherWords() {
        let events: [TrainingLogEvent] = [
            .word(how: "autoFixKept", typed: "teh", final: "the", offered: nil),
            .sentence(text: "Another one for the others.", day: day)
        ]

        XCTAssertEqual(TrainingExampleBuilder.examples(from: events).first?.typed, "Another one for teh others.")
    }

    func test_undoneAutomaticFix_isRejectedWithWhatWasOffered() {
        // #given a fix the writer undid
        let events: [TrainingLogEvent] = [
            .word(how: "autoFixUndone", typed: "Okafor", final: "Okafor", offered: "Aquifer"),
            .sentence(text: "We met Okafor today.", day: day)
        ]

        // #when examples are built
        let example = TrainingExampleBuilder.examples(from: events).first

        // #then the sentence is unchanged and the offer is listed as rejected
        XCTAssertEqual(example?.typed, "We met Okafor today.")
        XCTAssertEqual(example?.rejected, [.init(typed: "Okafor", fix: "Aquifer", how: "autoFix")])
        XCTAssertEqual(example?.accepted, [])
    }

    func test_wordKeptFromTheBar_isRejectedAsOffered() {
        let events: [TrainingLogEvent] = [
            .word(how: "keptAsTyped", typed: "Kubernetes", final: "Kubernetes", offered: nil),
            .sentence(text: "We run Kubernetes here.", day: day)
        ]

        XCTAssertEqual(
            TrainingExampleBuilder.examples(from: events).first?.rejected,
            [.init(typed: "Kubernetes", fix: nil, how: "offered")]
        )
    }

    func test_pickedAndSelfCorrectedWords_areAccepted() {
        let events: [TrainingLogEvent] = [
            .word(how: "picked", typed: "recipt", final: "receipt", offered: nil),
            .word(how: "selfCorrected", typed: "tommorow", final: "tomorrow", offered: nil),
            .sentence(text: "Send the receipt tomorrow please.", day: day)
        ]

        let example = TrainingExampleBuilder.examples(from: events).first

        XCTAssertEqual(example?.typed, "Send the recipt tommorow please.")
        XCTAssertEqual(example?.accepted.map(\.how), ["picked", "selfCorrected"])
    }

    func test_keptSentenceFix_confirmedAfterTheSentenceWasRecorded() {
        // #given a sentence fixed at its end, recorded, and only then confirmed by typing on
        let events: [TrainingLogEvent] = [
            .sentence(text: "I drive a Toyota Corolla to work.", day: day),
            .sentenceFix(original: "I drive a Tyoda Corola to work.", corrected: "I drive a Toyota Corolla to work.", kept: true)
        ]

        // #when examples are built
        let example = TrainingExampleBuilder.examples(from: events).first

        // #then typed is the sentence before the fix, with each changed word in its own casing
        XCTAssertEqual(example?.typed, "I drive a Tyoda Corola to work.")
        XCTAssertEqual(example?.final, "I drive a Toyota Corolla to work.")
        XCTAssertEqual(example?.accepted, [
            .init(typed: "Tyoda", fix: "Toyota", how: "sentenceFix"),
            .init(typed: "Corola", fix: "Corolla", how: "sentenceFix")
        ])
    }

    func test_keptSentenceFix_confirmedBeforeTheSentenceWasRecorded() {
        let events: [TrainingLogEvent] = [
            .sentenceFix(original: "She went too the shop.", corrected: "She went to the shop.", kept: true),
            .sentence(text: "She went to the shop.", day: day)
        ]

        XCTAssertEqual(TrainingExampleBuilder.examples(from: events).first?.typed, "She went too the shop.")
    }

    func test_wordFixAndSentenceFix_areBothUndoneInTyped() {
        // #given a word fixed while typing and another fixed when the sentence was finished
        let events: [TrainingLogEvent] = [
            .word(how: "autoFixKept", typed: "teh", final: "the", offered: nil),
            .sentence(text: "I parked the Toyota outside.", day: day),
            .sentenceFix(original: "I parked the Tyoda outside.", corrected: "I parked the Toyota outside.", kept: true)
        ]

        // #when examples are built
        let example = TrainingExampleBuilder.examples(from: events).first

        // #then typed has both misspellings
        XCTAssertEqual(example?.typed, "I parked teh Tyoda outside.")
        XCTAssertEqual(example?.accepted.map(\.how), ["autoFix", "sentenceFix"])
    }

    func test_undoneSentenceFix_dropsTheCorrectedSentenceAndRejectsTheChange() {
        // #given a sentence fix that was recorded, then undone, after which the original stands
        let events: [TrainingLogEvent] = [
            .sentence(text: "Ask Lundqvist about it.", day: day),
            .sentenceFix(original: "Ask Lindqvist about it.", corrected: "Ask Lundqvist about it.", kept: false),
            .sentence(text: "Ask Lindqvist about it.", day: day)
        ]

        // #when examples are built
        let examples = TrainingExampleBuilder.examples(from: events)

        // #then only the writer's sentence remains, with the fix listed as rejected
        XCTAssertEqual(examples.map(\.final), ["Ask Lindqvist about it."])
        XCTAssertEqual(examples.first?.typed, "Ask Lindqvist about it.")
        XCTAssertEqual(examples.first?.rejected, [.init(typed: "Lindqvist", fix: "Lundqvist", how: "sentenceFix")])
    }

    func test_wordEventSettledLate_goesToTheSentenceItFits() {
        // #given a fix whose outcome was only settled after the next sentence began
        let events: [TrainingLogEvent] = [
            .sentence(text: "I saw the cat.", day: day),
            .word(how: "autoFixKept", typed: "teh", final: "the", offered: nil),
            .sentence(text: "It ran off quickly.", day: day)
        ]

        // #when examples are built
        let examples = TrainingExampleBuilder.examples(from: events)

        // #then it lands on the sentence that holds the word
        XCTAssertEqual(examples.map(\.typed), ["I saw teh cat.", "It ran off quickly."])
    }

    func test_wordEventWithNoSentence_isAWordExample() {
        // #given a fix in text that never became a recorded sentence (a search box, a short reply)
        let events: [TrainingLogEvent] = [.word(how: "picked", typed: "recieve", final: "receive", offered: nil)]

        // #when examples are built
        let examples = TrainingExampleBuilder.examples(from: events)

        // #then it is still exported, as a word pair
        XCTAssertEqual(examples, [
            TrainingExample(
                scope: "word", day: nil, typed: "recieve", final: "receive",
                accepted: [.init(typed: "recieve", fix: "receive", how: "picked")], rejected: []
            )
        ])
    }

    func test_jsonLines_areOneSortedObjectPerLine() throws {
        // #given two examples
        let examples = TrainingExampleBuilder.examples(from: [
            .word(how: "autoFixKept", typed: "teh", final: "the", offered: nil),
            .sentence(text: "I saw the cat.", day: day),
            .sentence(text: "It ran off quickly.", day: day)
        ])

        // #when they are written out
        let lines = String(decoding: TrainingExampleBuilder.jsonLines(examples), as: UTF8.self)
            .split(separator: "\n").map(String.init)

        // #then each line is one JSON object that reads back as the example
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(try JSONDecoder().decode(TrainingExample.self, from: Data(lines[0].utf8)), examples[0])
        XCTAssertTrue(lines[0].hasPrefix(#"{"accepted":[{"fix":"the","how":"autoFix","typed":"teh"}],"day":"2026-11-15","final":"I saw the cat.""#))
    }

    func test_logEvent_survivesItsJSONForm() {
        let events: [TrainingLogEvent] = [
            .sentence(text: "I saw the cat.", day: day),
            .word(how: "autoFixUndone", typed: "Okafor", final: "Okafor", offered: "Aquifer"),
            .word(how: "picked", typed: "recipt", final: "receipt", offered: nil),
            .sentenceFix(original: "a", corrected: "b", kept: false)
        ]

        XCTAssertEqual(events.compactMap { TrainingLogEvent(json: $0.json) }, events)
    }

    func test_unknownLogLine_isSkipped() {
        XCTAssertNil(TrainingLogEvent(json: ["event": "somethingNewer", "text": "x"]))
    }

    // MARK: - The timeline

    private func line(
        _ event: TrainingLogEvent, _ order: Int, ms: Int, run: String = "a", day: String? = nil, app: String? = nil
    ) -> TrainingLogLine {
        TrainingLogLine(event, stamp: .init(run: run, order: order, milliseconds: ms, day: day, app: app))
    }

    func test_decisionsStripUsesAndOutcomes_becomeOneOrderedTimeline() throws {
        // #given a sentence in which the strip was wrong for one word, the engine fixed another,
        // and the writer kept the fix
        let decision = SpellingDecisionRecord(
            typed: "teh", action: "fixed",
            candidates: [.init(term: "the", score: 1.4), .init(term: "ten", score: 0.6)], confidence: 0.97, before: "I saw"
        )
        let lines = [
            line(.session(version: "0.4.0", stripModel: "gemma.gguf", hasSentenceModel: true), 1, ms: 0),
            line(.strip(StripUse(before: "I", word: "saw", shownFirst: ["am", "have"], shownLast: ["said", "saw"], lettersTyped: 1, pickedSlot: nil)), 2, ms: 400),
            line(.decision(decision), 3, ms: 900),
            line(.word(how: "autoFixKept", typed: "teh", final: "the", offered: nil), 4, ms: 1_500),
            line(.strip(StripUse(before: "I saw the", word: "cat", shownFirst: ["cat"], shownLast: ["cat"], lettersTyped: 0, pickedSlot: 0)), 5, ms: 1_900),
            line(.sentence(text: "I saw the cat today.", day: day, context: "We went out.", app: "com.example.notes"), 6, ms: 3_000),
        ]

        // #when the examples are built
        let example = try XCTUnwrap(TrainingExampleBuilder.examples(fromLines: lines).first)
        let steps = try XCTUnwrap(example.steps)

        // #then the sentence carries everything, in order, timed from its first step
        XCTAssertEqual(example.typed, "I saw teh cat today.")
        XCTAssertEqual(example.context, "We went out.")
        XCTAssertEqual(example.app, "com.example.notes")
        XCTAssertEqual(example.session, .init(version: "0.4.0", stripModel: "gemma.gguf", hasSentenceModel: true))
        XCTAssertEqual(steps.map(\.kind), ["strip", "decision", "outcome", "strip"])
        XCTAssertEqual(steps.map(\.ms), [0, 500, 1_100, 1_500])
        // The strip had the word second when it was typed out, and first when it was picked.
        XCTAssertEqual(steps[0].rank, 1)
        XCTAssertNil(steps[0].pickedSlot)
        XCTAssertEqual(steps[3].rank, 0)
        XCTAssertEqual(steps[3].pickedSlot, 0)
        XCTAssertEqual(steps[1].candidates, ["the", "ten"])
        XCTAssertEqual(steps[1].confidence, 0.97)
        XCTAssertEqual(steps[2].how, "autoFixKept")
    }

    func test_stripUseForAWordThatWasFixed_isRankedAgainstTheWordMeant() throws {
        // #given a word typed wrongly with the right word shown second, then fixed
        let lines = [
            line(.strip(StripUse(before: "I will", word: "recieve", shownFirst: [], shownLast: ["recent", "receive"], lettersTyped: 3, pickedSlot: nil)), 1, ms: 0),
            line(.word(how: "autoFixKept", typed: "recieve", final: "receive", offered: nil), 2, ms: 200),
            line(.sentence(text: "I will receive it tomorrow.", day: day), 3, ms: 900),
        ]

        let steps = try XCTUnwrap(TrainingExampleBuilder.examples(fromLines: lines).first?.steps)

        // #then the strip is credited with having had the word that was meant
        XCTAssertEqual(steps.first { $0.kind == "strip" }?.rank, 1)
    }

    func test_detailsOfTheNextSentence_writtenBeforeThisOneSettled_waitForTheirOwn() throws {
        // #given the first word of a second sentence recorded before the first sentence was
        let lines = [
            line(.strip(StripUse(before: "I saw the", word: "cat", shownFirst: ["cat"], shownLast: ["cat"], lettersTyped: 1, pickedSlot: nil)), 1, ms: 0),
            line(.strip(StripUse(before: "", word: "It", shownFirst: ["It", "The"], shownLast: ["It"], lettersTyped: 1, pickedSlot: nil)), 2, ms: 600),
            line(.sentence(text: "I saw the cat.", day: day), 3, ms: 900),
            line(.strip(StripUse(before: "It", word: "ran", shownFirst: ["was"], shownLast: ["ran"], lettersTyped: 2, pickedSlot: nil)), 4, ms: 1_300),
            line(.sentence(text: "It ran off quickly.", day: day), 5, ms: 2_500),
        ]

        let examples = TrainingExampleBuilder.examples(fromLines: lines)

        // #then each sentence has its own words' steps
        XCTAssertEqual(examples.map(\.final), ["I saw the cat.", "It ran off quickly."])
        XCTAssertEqual(examples[0].steps?.map(\.word), ["cat"])
        XCTAssertEqual(examples[1].steps?.map(\.word), ["It", "ran"])
    }

    func test_detailThatFitsNoSentence_isExportedOnItsOwn() {
        // #given a strip use from text that never became a saved sentence, then three other sentences
        var lines = [line(.strip(StripUse(before: "pizza order for", word: "tonight", shownFirst: ["the"], shownLast: ["today"], lettersTyped: 2, pickedSlot: nil)), 1, ms: 0)]
        for (index, text) in ["I saw the cat.", "It ran off quickly.", "We laughed a lot."].enumerated() {
            lines.append(line(.sentence(text: text, day: day), index + 2, ms: 1_000 * (index + 1)))
        }

        let examples = TrainingExampleBuilder.examples(fromLines: lines)

        // #then it is its own row, and the sentences are untouched
        XCTAssertEqual(examples.filter { $0.scope == "strip" }.map(\.final), ["tonight"])
        XCTAssertEqual(examples.filter { $0.scope == "sentence" }.count, 3)
        XCTAssertTrue(examples.filter { $0.scope == "sentence" }.allSatisfy { $0.steps == nil })
    }

    func test_stepsFromAnotherLaunch_getNoTime() throws {
        let lines = [
            line(.word(how: "autoFixKept", typed: "teh", final: "the", offered: nil), 9, ms: 50_000, run: "earlier"),
            line(.strip(StripUse(before: "I saw the", word: "cat", shownFirst: ["cat"], shownLast: ["cat"], lettersTyped: 1, pickedSlot: nil)), 1, ms: 10),
            line(.sentence(text: "I saw the cat.", day: day), 2, ms: 500),
        ]

        let steps = try XCTUnwrap(TrainingExampleBuilder.examples(fromLines: lines).first?.steps)

        XCTAssertEqual(steps.map(\.ms), [0, nil])
    }

    func test_sentencePass_isAStepOfTheSentenceItRead_evenWrittenAfterIt() throws {
        // #given a sentence whose fix was kept, and the model's pass over it written after the
        // sentence line, with nothing after it in the file
        let pass: [SentencePassWord] = [
            .init(typed: "Tyoda", written: "Toyota", probability: 0.97, action: "fixed"),
            .init(typed: "wrok", written: "work", probability: 0.4, action: "left"),
        ]
        let lines = [
            line(.sentence(text: "I drive a Toyota to wrok.", day: day), 1, ms: 0),
            line(.sentencePass(sentence: "I drive a Tyoda to wrok.", words: pass), 2, ms: 120),
            line(.sentenceFix(original: "I drive a Tyoda to wrok.", corrected: "I drive a Toyota to wrok.", kept: true), 3, ms: 900),
        ]

        let examples = TrainingExampleBuilder.examples(fromLines: lines)
        let steps = try XCTUnwrap(examples.first?.steps)

        // #then the one example says what the model saw, how sure it was, and what it left alone
        XCTAssertEqual(examples.count, 1)
        XCTAssertEqual(steps.map(\.kind), ["sentencePass", "sentenceFix"])
        XCTAssertEqual(steps[0].before, "I drive a Tyoda to wrok.")
        XCTAssertEqual(steps[0].changes, pass)
        XCTAssertEqual(steps[0].ms, 0)
        XCTAssertEqual(steps[1].ms, 780)
    }

    func test_sentencePassForASentenceThatWasNotSaved_isExportedOnItsOwn() {
        let pass = [SentencePassWord(typed: "teh", written: "the", probability: 0.8, action: "asked")]
        let lines = [
            line(.sentencePass(sentence: "I saw teh cat.", words: pass), 1, ms: 0),
            line(.sentence(text: "Something else was written here.", day: day), 2, ms: 500),
        ]

        let examples = TrainingExampleBuilder.examples(fromLines: lines)

        XCTAssertEqual(examples.map(\.scope), ["sentence", "sentencePass"])
        XCTAssertEqual(examples.last?.final, "I saw teh cat.")
        XCTAssertEqual(examples.last?.steps?.first?.changes, pass)
    }

    func test_fixAtTheStartOfASentence_findsItsSentenceDespiteTheCapital() throws {
        // #given a fix recorded in lowercase, in a sentence where the word stands capitalized
        let events: [TrainingLogEvent] = [
            .word(how: "autoFixKept", typed: "teh", final: "the", offered: nil),
            .sentence(text: "The cat sat down.", day: day),
        ]

        let examples = TrainingExampleBuilder.examples(from: events)

        // #then it is one example, and the typed sentence has the slip under the same capital
        XCTAssertEqual(examples.count, 1)
        XCTAssertEqual(examples.first?.typed, "Teh cat sat down.")
        XCTAssertEqual(examples.first?.accepted.map(\.fix), ["the"])
    }

    func test_fixWhoseSentenceWasNeverSaved_keepsTheSentenceSoFarFromItsDecision() throws {
        // #given a fix in a line that was never finished, then an unrelated saved sentence
        let decision = SpellingDecisionRecord(
            typed: "recieve", action: "fixed", candidates: [.init(term: "receive", score: 1.5)], confidence: 0.96, before: "did you"
        )
        let lines = [
            line(.strip(StripUse(before: "did you", word: "recieve", shownFirst: ["have"], shownLast: ["read", "really"], lettersTyped: 2, pickedSlot: nil)), 1, ms: 0),
            line(.decision(decision), 2, ms: 300),
            line(.word(how: "autoFixKept", typed: "recieve", final: "receive", offered: nil), 3, ms: 700),
            line(.sentence(text: "Something else was written here.", day: day), 4, ms: 9_000),
        ]

        let examples = TrainingExampleBuilder.examples(fromLines: lines)
        let loose = try XCTUnwrap(examples.first { $0.scope == "word" })

        // #then the fix is one example that says where it happened and what was on screen
        XCTAssertEqual(examples.map(\.scope), ["word", "sentence"])
        XCTAssertEqual(loose.steps?.map(\.kind), ["strip", "decision", "outcome"])
        XCTAssertEqual(loose.steps?[1].before, "did you")
        XCTAssertEqual(loose.steps?[1].confidence, 0.96)
        XCTAssertNil(loose.steps?[0].rank)
    }

    func test_newLogLines_surviveTheirJSONForm() throws {
        let decision = SpellingDecisionRecord(
            typed: "teh", action: "offeredChoices", candidates: [.init(term: "the", score: 1.25)], confidence: nil, before: "I saw"
        )
        let lines = [
            line(.decision(decision), 1, ms: 0),
            line(.strip(StripUse(before: "I", word: "saw", shownFirst: ["am"], shownLast: ["saw"], lettersTyped: 2, pickedSlot: 3)), 2, ms: 7),
            line(.session(version: "0.4.0", stripModel: nil, hasSentenceModel: false), 3, ms: 9),
            line(.sentence(text: "I saw it.", day: day, context: "Before.", app: "com.example"), 4, ms: 11, day: day, app: "com.example"),
            line(.sentencePass(sentence: "I saw teh cat.", words: [.init(typed: "teh", written: "the", probability: 0.75, action: "asked")]), 5, ms: 12),
            line(.strip(StripUse(
                before: "I", word: "saw", shownFirst: ["am"], shownLast: ["saw"], lettersTyped: 2, pickedSlot: nil,
                draws: [.init(typed: "", shown: ["am"]), .init(typed: "sa", shown: ["saw", "said"])]
            )), 6, ms: 13, day: day, app: "com.example"),
        ]

        for original in lines {
            let data = try JSONSerialization.data(withJSONObject: original.json)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(TrainingLogLine(json: object), original)
        }
    }

    // MARK: - 0.4.4: every strip of a word, replaced fixes, and events with no saved sentence

    func test_stripStep_saysWhenTheWordWasFirstListed_notOnlyWhetherTheLastStripHadIt() throws {
        // #given a word the strip had from its second letter, typed out to the end, where the last
        // strip (drawn for the whole word) no longer lists it
        let use = StripUse(
            before: "I saw the", word: "resident", shownFirst: ["cat"], shownLast: ["residents", "residential"],
            lettersTyped: 8, pickedSlot: nil,
            draws: [
                .init(typed: "", shown: ["cat"]), .init(typed: "r", shown: ["red", "road"]),
                .init(typed: "re", shown: ["report", "resident"]), .init(typed: "resident", shown: ["residents", "residential"]),
            ]
        )
        let lines = [line(.strip(use), 1, ms: 0), line(.sentence(text: "I saw the resident today.", day: day), 2, ms: 900)]

        // #when the example is built
        let step = try XCTUnwrap(TrainingExampleBuilder.examples(fromLines: lines).first?.steps?.first)

        // #then the last strip did not have it, and the record still says the strip did, at two
        // letters, in the second slot
        XCTAssertNil(step.rank)
        XCTAssertEqual(step.listedAt, 2)
        XCTAssertEqual(step.listedSlot, 1)
        XCTAssertEqual(step.draws?.count, 4)
    }

    func test_stripStep_carriesTheWordsSlowestMoments_throughTheLogAndIntoTheExport() throws {
        // #given a word typed while a key waited 120 ms, a strip took 40 ms and a read 95 ms
        var use = StripUse(
            before: "I saw the", word: "report", shownFirst: ["cat"], shownLast: ["report"], lettersTyped: 2, pickedSlot: 0
        )
        use.timing = .init(key: 120, strip: 40, read: 95, model: 60, missed: 2)
        let written = line(.strip(use), 1, ms: 0)

        // #when the line goes through the log file and the example is built from it
        let data = try JSONSerialization.data(withJSONObject: written.json)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let read = try XCTUnwrap(TrainingLogLine(json: object))
        let lines = [read, line(.sentence(text: "I saw the report today.", day: day), 2, ms: 900)]
        let step = try XCTUnwrap(TrainingExampleBuilder.examples(fromLines: lines).first?.steps?.first)

        // #then the timing is in the step, in milliseconds
        XCTAssertEqual(step.lag, StripUse.Timing(key: 120, strip: 40, read: 95, model: 60, missed: 2))
    }

    func test_fixTheWriterReplacedWithAThirdWord_isARejectedFixAndAnAcceptedOne() throws {
        // #given `thay` fixed to `they`, which the writer changed to `that`
        let lines = [
            line(.word(how: "autoFixReplaced", typed: "thay", final: "that", offered: "they"), 1, ms: 0),
            line(.sentence(text: "I think that works.", day: day), 2, ms: 900),
        ]

        // #when the example is built
        let example = try XCTUnwrap(TrainingExampleBuilder.examples(fromLines: lines).first)

        // #then the sentence is as first typed, the wrong fix is rejected, and the word meant is accepted
        XCTAssertEqual(example.typed, "I think thay works.")
        XCTAssertEqual(example.rejected, [.init(typed: "thay", fix: "they", how: "autoFix")])
        XCTAssertEqual(example.accepted, [.init(typed: "thay", fix: "that", how: "selfCorrected")])
    }

    func test_eventWhoseSentenceWasNeverSaved_stillSaysWhenWhereAndWhichBuild() throws {
        // #given a decision in a line that was never saved, stamped like every line since 0.4.4
        let decision = SpellingDecisionRecord(
            typed: "recieve", action: "offered", candidates: [.init(term: "receive", score: 1.2)], confidence: 0.6, before: "did you"
        )
        let lines = [
            line(.session(version: "0.4.4", stripModel: nil, hasSentenceModel: true), 1, ms: 0),
            line(.decision(decision), 2, ms: 4_200, day: day, app: "com.example.chat"),
        ]

        // #when the examples are built
        let example = try XCTUnwrap(TrainingExampleBuilder.examples(fromLines: lines).first)

        // #then the lone event carries its day, app, build, launch and time in the launch
        XCTAssertEqual(example.scope, "decision")
        XCTAssertEqual(example.day, day)
        XCTAssertEqual(example.app, "com.example.chat")
        XCTAssertEqual(example.session?.version, "0.4.4")
        XCTAssertEqual(example.run, "a")
        XCTAssertEqual(example.at, 4_200)
    }

    func test_passOverTheLineAsFarAsItHadGot_isAStepOfTheSentenceItBecame() throws {
        // #given the sentence model's look at the first six words of a line, and the whole line saved later
        let lines = [
            line(.sentencePass(
                sentence: "can you send teh report over",
                words: [.init(typed: "teh", written: "the", probability: 0.97, action: "fixed")]
            ), 1, ms: 0),
            line(.sentence(text: "can you send the report over when you get a chance", day: day), 2, ms: 5_000),
        ]

        // #when the examples are built
        let examples = TrainingExampleBuilder.examples(fromLines: lines)

        // #then there is one example, and the pass is a step of it
        XCTAssertEqual(examples.count, 1)
        XCTAssertEqual(examples.first?.steps?.map(\.kind), ["sentencePass"])
    }
}
