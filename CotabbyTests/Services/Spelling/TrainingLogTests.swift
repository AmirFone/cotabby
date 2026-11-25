import XCTest
@testable import Cotabby

/// The training record's file: off unless switched on, exportable, deletable.
@MainActor
final class TrainingLogTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("training-log.jsonl") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cotabby-training-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeLog(isEnabled: @escaping () -> Bool = { true }) -> TrainingLog {
        TrainingLog(fileURL: fileURL, isEnabled: isEnabled, today: { Date(timeIntervalSince1970: 1_794_700_800) })
    }

    func test_writtenOnAQueue_linesAreInTheFileInOrderOnceWaitedFor() throws {
        // #given a log that writes its file on a queue, as the running app does
        let log = TrainingLog(
            fileURL: fileURL, isEnabled: { true }, today: { Date(timeIntervalSince1970: 1_794_700_800) },
            disk: DispatchQueue(label: "training-log-test")
        )

        // #when lines are recorded and whatever reads the file waits for them
        log.noteSentence("I saw the cat today.")
        log.noteSentence("We went home after that.")
        log.waitForDisk()

        // #then both are there, first one first
        let lines = try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("cat"))
    }

    func test_writtenOnAQueue_theCountAndDeleteSeeEveryLineRecorded() {
        let log = TrainingLog(
            fileURL: fileURL, isEnabled: { true }, today: { Date(timeIntervalSince1970: 1_794_700_800) },
            disk: DispatchQueue(label: "training-log-test")
        )

        // #when a line is recorded and counted at once, then everything is deleted at once
        log.noteSentence("I saw the cat today.")
        let counted = log.sentenceCount()
        log.noteSentence("We went home after that.")
        log.clear()

        // #then the count saw the line, and no line written late brings the file back
        XCTAssertEqual(counted, 1)
        log.waitForDisk()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func test_switchedOff_nothingIsWritten() {
        // #given a log the writer has not switched on
        let log = makeLog(isEnabled: { false })

        // #when every kind of event arrives
        log.noteSentence("I saw the cat today.")
        log.noteWord(.autoFixKept, typed: "teh", final: "the", offered: nil)
        log.noteSentenceFix(original: "a b c", corrected: "a b d", kept: true)

        // #then no file exists
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(log.sentenceCount(), 0)
    }

    func test_defaultSwitch_isOff() {
        // #given a Mac where the setting was never touched
        let suiteName = "cotabby.test.training.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // #then the key reads as off
        XCTAssertFalse(defaults.bool(forKey: TrainingLog.enabledDefaultsKey))
    }

    func test_switchedOn_sentencesAreCountedAndExported() throws {
        // #given a log that is on, with one fixed word and two sentences
        let log = makeLog()
        log.noteWord(.autoFixKept, typed: "teh", final: "the", offered: nil)
        log.noteSentence("I saw the cat today.")
        log.noteSentence("It ran off quickly.")

        // #when it is exported
        let destination = directory.appendingPathComponent("export.jsonl")
        let count = try log.export(to: destination)

        // #then the export holds one example per sentence, with the typed form rebuilt
        XCTAssertEqual(log.sentenceCount(), 2)
        XCTAssertEqual(count, 2)
        let lines = try String(contentsOf: destination, encoding: .utf8).split(separator: "\n")
        let first = try JSONDecoder().decode(TrainingExample.self, from: Data(lines[0].utf8))
        XCTAssertEqual(first.typed, "I saw teh cat today.")
        XCTAssertEqual(first.final, "I saw the cat today.")
    }

    func test_savedSentence_carriesADateButNoTimeOfDay() throws {
        let log = makeLog()

        log.noteSentence("I saw the cat today.")

        let line = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(line.contains(#""day":"2026-11-1"#), line)
        XCTAssertFalse(line.contains("T0") || line.contains(":00"), "no clock time belongs in the log: \(line)")
    }

    func test_file_isReadableByTheOwnerOnly() throws {
        let log = makeLog()

        log.noteSentence("I saw the cat today.")

        let permissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func test_fragmentsAndPastedBlocks_areNotSaved() {
        // #given text that is not a sentence worth training on
        let log = makeLog()

        // #when a two-word fragment and a very long run arrive
        log.noteSentence("Hello there")
        log.noteSentence(String(repeating: "word ", count: 200))

        // #then neither is saved
        XCTAssertEqual(log.sentenceCount(), 0)
    }

    func test_webAddressesEmailsAndCode_areNotSaved() {
        // #given a log that is on
        let log = makeLog()

        // #when sentences carrying an address, an email, or code are finished
        log.noteSentence("The page is at https://example.com/login today.")
        log.noteSentence("Write to sam@example.com about the invoice.")
        log.noteSentence("Then set count = count + 1 in the loop.")

        // #then none of them is saved
        XCTAssertEqual(log.sentenceCount(), 0)
    }

    func test_sentenceFixWordEntriesFromTheJournal_areNotDoubled() throws {
        // #given a sentence fix, which the journal reports word by word and the controller reports whole
        let log = makeLog()
        log.noteWord(.sentenceFixKept, typed: "tyoda", final: "toyota", offered: nil)
        log.noteSentenceFix(original: "I drive a Tyoda.", corrected: "I drive a Toyota.", kept: true)

        // #then only the whole-sentence form is in the file
        let lines = try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("sentenceFix"))
    }

    func test_clear_removesEverything() {
        let log = makeLog()
        log.noteSentence("I saw the cat today.")

        log.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(log.sentenceCount(), 0)
    }

    func test_afterDeleteAll_theNextLineStartsAFreshRecord() throws {
        // #given a record with a line in it, written by a launch that names its build
        let log = makeLog()
        log.session = { .session(version: "0.4.0", stripModel: "gemma.gguf", hasSentenceModel: true) }
        log.noteSentence("I saw the cat today.")

        // #when the writer deletes everything and then finishes another sentence
        log.clear()
        log.noteSentence("It ran off quickly.")

        // #then the new file opens with the build line and counts from one again
        let lines = try rawLines()
        XCTAssertEqual(lines.map { "\($0["event"] as? String ?? "") \($0["n"] as? Int ?? 0)" }, ["session 1", "sentence 2"])
    }

    func test_afterDeleteAll_theSameDecisionIsWrittenAgain() throws {
        // #given a decision that is already in the record
        let log = makeLog()
        let decision = SpellingDecisionRecord(
            typed: "teh", action: "offered", candidates: [.init(term: "the", score: 1.2)], confidence: 0.6, before: "I saw"
        )
        log.noteDecision(decision)

        // #when the writer deletes everything and the same decision is reached again
        log.clear()
        log.noteDecision(decision)

        // #then it is in the new file: nothing from before the delete counts as already written
        XCTAssertEqual(try rawLines().map { $0["event"] as? String }, ["decision"])
    }

    func test_afterDeleteAll_timeIsCountedFromTheNewFirstLine() throws {
        // #given a record whose first line was written five seconds before the delete
        var now: UInt64 = 5_000_000_000
        let log = TrainingLog(
            fileURL: fileURL, isEnabled: { true }, today: { Date(timeIntervalSince1970: 1_794_700_800) },
            uptimeNanoseconds: { now }
        )
        log.noteSentence("I saw the cat today.")
        now += 5_000_000_000

        // #when the writer deletes everything and then finishes another sentence
        log.clear()
        log.noteSentence("It ran off quickly.")

        // #then the new line is timed from itself, not from a line that no longer exists
        XCTAssertEqual(try rawLines().map { $0["ms"] as? Int }, [0])
    }

    /// Not a check: exports a training log from outside the app, for looking at what a real log
    /// turns into. Runs only with TEST_RUNNER_TRAINING_LOG_IN and TEST_RUNNER_TRAINING_LOG_OUT set.
    func test_exportOfAGivenLog() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["TRAINING_LOG_IN"], let output = environment["TRAINING_LOG_OUT"] else {
            throw XCTSkip("Set TEST_RUNNER_TRAINING_LOG_IN and TEST_RUNNER_TRAINING_LOG_OUT to export a log")
        }
        let log = TrainingLog(fileURL: URL(fileURLWithPath: input), isEnabled: { false })
        XCTAssertGreaterThan(try log.export(to: URL(fileURLWithPath: output)), 0)
    }

    func test_summaryLine_saysWhetherSavingIsOn() {
        XCTAssertEqual(
            TrainingDataSection.summary(sentenceCount: 0, hasSavedData: false, isSaving: false), "Nothing saved. Saving is off."
        )
        XCTAssertEqual(
            TrainingDataSection.summary(sentenceCount: 1, hasSavedData: true, isSaving: true), "1 sentence saved. Saving is on."
        )
        XCTAssertEqual(
            TrainingDataSection.summary(sentenceCount: 1204, hasSavedData: true, isSaving: true),
            "1,204 sentences saved. Saving is on."
        )
    }

    func test_fragmentsThatAreNotCountedAsSentences_stillLeaveSavedData() {
        // #given a record that is on, and a writer who has only typed a two-word reply so far, which
        // is too short to be saved or counted as a sentence
        let log = makeLog()
        log.noteSentence("Teh end")

        // #when a fix made in that reply arrives, which is saved although the sentence is not
        log.noteWord(.autoFixKept, typed: "teh", final: "the", offered: nil)

        // #then the record reports that it holds something, which is what enables Delete All
        XCTAssertTrue(log.hasSavedData())
    }

    func test_recordThatWasNeverWritten_hasNoSavedData() {
        // #given a record that is switched off
        let log = makeLog(isEnabled: { false })

        // #when something is typed
        log.noteWord(.autoFixKept, typed: "teh", final: "the", offered: nil)

        // #then there is nothing to show or delete
        XCTAssertFalse(log.hasSavedData())
    }

    func test_afterDeleteAll_thereIsNoSavedData() {
        // #given a record with a line in it
        let log = makeLog()
        log.noteWord(.autoFixKept, typed: "teh", final: "the", offered: nil)

        // #when the writer deletes everything
        log.clear()

        // #then the record reports nothing left
        XCTAssertFalse(log.hasSavedData())
    }

    func test_summaryLine_namesWhatIsSaved_whenNoSentenceIsCounted() {
        // #given a file that holds typed words but no counted sentence
        let summary = TrainingDataSection.summary(sentenceCount: 0, hasSavedData: true, isSaving: true)

        // #then the line does not claim that nothing is saved
        XCTAssertEqual(summary, "Typed words and fixes saved, no sentences counted yet. Saving is on.")
    }

    // MARK: - The detailed record

    private func rawLines() throws -> [[String: Any]] {
        try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func test_everyLine_carriesItsPlaceAndTheTimeSinceTheFirst_andNoClockTime() throws {
        // #given a log whose clock moves 250 ms between two events
        var now: UInt64 = 5_000_000_000
        let log = TrainingLog(
            fileURL: fileURL, isEnabled: { true }, today: { Date(timeIntervalSince1970: 1_794_700_800) },
            uptimeNanoseconds: { now }
        )
        log.noteWord(.autoFixKept, typed: "teh", final: "the", offered: nil)
        now += 250_000_000
        log.noteSentence("I saw the cat today.")

        // #then the lines are numbered within one launch and timed from its first line
        let lines = try rawLines()
        XCTAssertEqual(lines.map { $0["n"] as? Int }, [1, 2])
        XCTAssertEqual(lines.map { $0["ms"] as? Int }, [0, 250])
        XCTAssertEqual(Set(lines.compactMap { $0["run"] as? String }).count, 1)
        XCTAssertFalse(try String(contentsOf: fileURL, encoding: .utf8).contains("T"), "no ISO time stamp")
    }

    func test_firstLineOfALaunch_saysWhichBuildWroteIt() throws {
        let log = makeLog()
        log.session = { .session(version: "0.4.0", stripModel: "gemma.gguf", hasSentenceModel: true) }

        log.noteSentence("I saw the cat today.")
        log.noteSentence("It ran off quickly.")

        XCTAssertEqual(try rawLines().map { $0["event"] as? String }, ["session", "sentence", "sentence"])
    }

    func test_sameDecisionReachedOnEveryKey_isWrittenOnce() throws {
        let log = makeLog()
        let decision = SpellingDecisionRecord(
            typed: "teh", action: "offered", candidates: [.init(term: "the", score: 1.2)], confidence: 0.6, before: "I saw"
        )

        log.noteDecision(decision)
        log.noteDecision(decision)
        log.noteStrip(StripUse(before: "I saw", word: "the", shownFirst: ["the"], shownLast: ["the"], lettersTyped: 0, pickedSlot: 0))

        XCTAssertEqual(try rawLines().map { $0["event"] as? String }, ["decision", "strip"])
    }

    func test_contextAndApp_areSavedOnlyWhileTheirSwitchesAreOn() throws {
        // #given a record with both parts on, then with both off
        var savesMore = true
        let log = TrainingLog(
            fileURL: fileURL, isEnabled: { true }, today: { Date(timeIntervalSince1970: 1_794_700_800) },
            savesContext: { savesMore }, savesApp: { savesMore }
        )
        let field = "We went out late. I saw the cat today. "
        log.noteSentence("I saw the cat today.", textBefore: field, app: "com.example.notes")
        savesMore = false
        log.noteSentence("I saw the cat today.", textBefore: field, app: "com.example.notes")

        // #then only the first sentence carries them
        let lines = try rawLines()
        XCTAssertEqual(lines[0]["context"] as? String, "We went out late.")
        XCTAssertEqual(lines[0]["app"] as? String, "com.example.notes")
        XCTAssertNil(lines[1]["context"])
        XCTAssertNil(lines[1]["app"])
    }

    func test_context_isTheEndOfWhatCameBefore_cutAtAWord_andNeverCodeOrAddresses() {
        let long = String(repeating: "word ", count: 100) + "The last part. "
        let context = TrainingLog.context(before: "I saw it.", in: long + "I saw it. ")

        XCTAssertEqual(context?.hasSuffix("The last part."), true)
        XCTAssertLessThanOrEqual(context?.count ?? 0, TrainingLog.maximumContextCharacters)
        XCTAssertEqual(context?.hasPrefix("word "), true)
        XCTAssertNil(TrainingLog.context(before: "I saw it.", in: "I saw it. "))
        XCTAssertNil(TrainingLog.context(before: "I saw it.", in: "See https://example.com/a?b=c for it. I saw it. "))
        XCTAssertNil(TrainingLog.context(before: "Not there.", in: "Something else entirely. "))
    }

    func test_wordsInsideAddressesOrCode_leaveNoDecisionOrStripLine() {
        let log = makeLog()

        log.noteStrip(StripUse(before: "mail me at jo@example.com", word: "today", shownFirst: ["the"], shownLast: ["the"], lettersTyped: 0, pickedSlot: nil))
        log.noteDecision(SpellingDecisionRecord(typed: "teh", action: "fixed", candidates: [], confidence: nil, before: "let x = foo(bar);"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func test_sentencePass_isWrittenOnlyWhenTheModelWouldChangeSomething_andNeverForCode() throws {
        let log = makeLog()
        let change = [SentencePassWord(typed: "teh", written: "the", probability: 0.8, action: "asked")]

        // #when a pass with nothing to change, a pass over code, and a real one arrive
        log.noteSentencePass("I saw the cat today.", words: [])
        log.noteSentencePass("let teh = foo(bar);", words: change)
        log.noteSentencePass("I saw teh cat today.", words: change)

        // #then only the real one is in the file
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "sentencePass").count - 1, 1)
        XCTAssertTrue(text.contains("I saw teh cat today."))
    }

    func test_subSwitches_areOnUntilTurnedOff() {
        let suiteName = "cotabby.test.training.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(TrainingLog.isOn(TrainingLog.contextDefaultsKey, defaults: defaults))
        defaults.set(false, forKey: TrainingLog.appDefaultsKey)
        XCTAssertFalse(TrainingLog.isOn(TrainingLog.appDefaultsKey, defaults: defaults))
    }

    func test_exportOfTheDetailedRecord_hasTheTimeline() throws {
        let log = makeLog()
        log.noteStrip(StripUse(before: "I saw the", word: "cat", shownFirst: ["dog"], shownLast: ["cat", "car"], lettersTyped: 2, pickedSlot: nil))
        log.noteSentence("I saw the cat today.")

        let destination = directory.appendingPathComponent("export.jsonl")
        XCTAssertEqual(try log.export(to: destination), 1)

        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])
        let steps = try XCTUnwrap(exported["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.first?["kind"] as? String, "strip")
        XCTAssertEqual(steps.first?["rank"] as? Int, 0)
        XCTAssertEqual(steps.first?["ms"] as? Int, 0)
    }
}
