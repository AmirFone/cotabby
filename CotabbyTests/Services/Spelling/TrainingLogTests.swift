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
        XCTAssertEqual(TrainingDataSection.summary(sentenceCount: 0, isSaving: false), "Nothing saved. Saving is off.")
        XCTAssertEqual(TrainingDataSection.summary(sentenceCount: 1, isSaving: true), "1 sentence saved. Saving is on.")
        XCTAssertEqual(TrainingDataSection.summary(sentenceCount: 1204, isSaving: true), "1,204 sentences saved. Saving is on.")
    }
}
