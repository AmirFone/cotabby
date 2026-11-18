import Foundation
import Logging

/// File overview:
/// The writer's own training record: finished sentences and what became of the fixes offered in
/// them, kept in one local file so a spelling model can be trained on this writer's mistakes.
///
/// What makes this a training record and not a keystroke log, and must stay true of it:
/// - **Off until the writer switches it on** (`enabledDefaultsKey` defaults to false). With it off
///   every method here returns before touching the disk.
/// - **Sentences, words and what Cotabby did with them; not keys.** A finished sentence, what the
///   spelling engine decided about a word and with which candidates, what the word strip showed for
///   a word and whether it was picked, what the sentence model would change and how sure it was,
///   and what became of each fix. No key presses, no shortcuts,
///   no window titles, no text from a field once it is deleted before a word is finished.
/// - **Order and pace, not the clock.** Each line carries its place in the launch's sequence and
///   the milliseconds since that launch's first line, so a sentence's steps can be put in order
///   and the pauses between them seen. The time of day is not kept; a sentence has a calendar date.
/// - **Two things have a switch of their own,** on by default once the record is on, because they
///   say more about the writer than the sentence itself does: the text just before each sentence
///   (`contextDefaultsKey`) and the app it was typed in (`appDefaultsKey`).
/// - **Only where Cotabby is working.** The callers sit behind the same gates as the spelling
///   features: password fields never reach them, nor does anything typed while Cotabby is off,
///   paused, or disabled for the app in front.
/// - **Never sent anywhere.** The file lives in Application Support; the only way out is the
///   writer's own Export in Settings, which writes a second file where they choose.
/// - **The writer can see and delete it** (Show in Finder and Delete All in Settings).
///
/// It is separate from `CorrectionJournal` because the two make different promises: the journal is
/// on by default and holds single misspelled words, this holds whole sentences and is opt-in.
///
/// Recording appends one small line (`TrainingLogEvent`) and does no other work, because it runs on
/// the typing path. `TrainingExampleBuilder` joins the lines into examples when the writer exports.
/// Owned by `CotabbyAppEnvironment` for the life of the app.
@MainActor
final class TrainingLog {
    static let enabledDefaultsKey = "cotabbyTrainingLogEnabled"
    /// Save the text just before each sentence; only read while the record is on.
    static let contextDefaultsKey = "cotabbyTrainingLogContextEnabled"
    /// Save which app each sentence was typed in; only read while the record is on.
    static let appDefaultsKey = "cotabbyTrainingLogAppEnabled"
    /// Months of heavy typing (a word typed with the strip on is a line of about 200 bytes). Past
    /// this the older half is dropped, so the file cannot grow without bound on a Mac where it was
    /// switched on and forgotten.
    static let maximumBytes = 100_000_000
    /// How much of the text before a sentence is kept with it.
    static let maximumContextCharacters = 300
    /// A "sentence" longer than this is pasted text or a run-on with no stops, not something to
    /// train a sentence model on.
    static let maximumSentenceCharacters = 400

    let fileURL: URL?
    private let isEnabled: () -> Bool
    private let today: () -> Date
    private let savesContext: () -> Bool
    private let savesApp: () -> Bool
    private let uptimeNanoseconds: () -> UInt64
    /// The build and models behind this launch's lines, asked for once, when the first line is
    /// written (by then the models have been chosen).
    var session: (() -> TrainingLogEvent)?

    /// This launch's name in the file: random, so two launches' sequences cannot be confused, and
    /// saying nothing about when it was.
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private var order = 0
    private var firstUptime: UInt64?
    private var lastDecision: SpellingDecisionRecord?

    init(
        fileURL: URL? = TrainingLog.defaultFileURL(),
        isEnabled: @escaping () -> Bool = TrainingLog.isEnabledInDefaults,
        today: @escaping () -> Date = Date.init,
        savesContext: @escaping () -> Bool = { TrainingLog.isOn(TrainingLog.contextDefaultsKey) },
        savesApp: @escaping () -> Bool = { TrainingLog.isOn(TrainingLog.appDefaultsKey) },
        uptimeNanoseconds: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.fileURL = fileURL
        self.isEnabled = isEnabled
        self.today = today
        self.savesContext = savesContext
        self.savesApp = savesApp
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    nonisolated deinit {}

    nonisolated static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Cotabby", isDirectory: true)
            .appendingPathComponent("training-log.jsonl")
    }

    static func isEnabledInDefaults() -> Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    /// A sub-switch of the record: on unless the writer turned it off.
    nonisolated static func isOn(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    // MARK: - Recording

    /// A finished sentence the writer left standing. Fragments, pasted blocks, and anything with a
    /// web address, an email address, or code in it are not saved.
    ///
    /// - Parameters:
    ///   - textBefore: the field's text up to the caret when the sentence settled; the part just
    ///     before the sentence is saved as its context if that switch is on.
    ///   - app: the bundle identifier of the app in front, saved if that switch is on.
    func noteSentence(_ sentence: String, textBefore: String? = nil, app: String? = nil) {
        guard sentence.count <= Self.maximumSentenceCharacters,
              sentence.split(whereSeparator: \.isWhitespace).count >= 3,
              !FinishedSentenceExtractor.looksMachineReadable(sentence) else { return }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        append(.sentence(
            text: sentence, day: formatter.string(from: today()),
            context: savesContext() ? textBefore.flatMap { Self.context(before: sentence, in: $0) } : nil,
            app: savesApp() ? app : nil
        ))
    }

    /// The end of what stands before `sentence` in `text`, cut at a word; nil when the sentence is
    /// not there or nothing precedes it. Text that looks like code, an address or a link is left
    /// out, like a sentence of that kind would be.
    nonisolated static func context(before sentence: String, in text: String) -> String? {
        guard let range = text.range(of: sentence, options: .backwards) else { return nil }
        let before = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !before.isEmpty else { return nil }
        var tail = Substring(before.suffix(maximumContextCharacters))
        if tail.count < before.count {
            tail = tail.drop { !$0.isWhitespace }.drop { $0.isWhitespace }
        }
        guard !tail.isEmpty, !FinishedSentenceExtractor.looksMachineReadable(String(tail)) else { return nil }
        return String(tail)
    }

    /// What the spelling engine decided about a word, as it decided. The same decision for the same
    /// word is reached again on every key while the bar is up; it is written once.
    func noteDecision(_ record: SpellingDecisionRecord) {
        guard record != lastDecision, Self.isProse(record.before, record.typed) else { return }
        lastDecision = record
        append(.decision(record))
    }

    /// What the word strip showed for a word the writer has finished or picked.
    func noteStrip(_ use: StripUse) {
        guard Self.isProse(use.before, use.word) else { return }
        append(.strip(use))
    }

    /// What the sentence model would change in a finished sentence and how sure it was of each
    /// word. A pass that would change nothing is not written: the sentence's own line says the
    /// same. Saved under the same rules as the sentence itself.
    func noteSentencePass(_ sentence: String, words: [SentencePassWord]) {
        guard !words.isEmpty, sentence.count <= Self.maximumSentenceCharacters,
              !FinishedSentenceExtractor.looksMachineReadable(sentence) else { return }
        append(.sentencePass(sentence: sentence, words: words))
    }

    /// False for a word in the middle of a web address, an email address or code: the sentence it
    /// belongs to would not be saved, so neither is the word.
    private static func isProse(_ before: String, _ word: String) -> Bool {
        !FinishedSentenceExtractor.looksMachineReadable(before + " " + word)
    }

    /// What happened to one word (the same events the correction journal keeps). Sentence fixes
    /// come through `noteSentenceFix` with both whole sentences, so their word-by-word journal
    /// entries are left out here.
    func noteWord(_ kind: CorrectionJournal.Kind, typed: String, final: String, offered: String?) {
        guard kind != .sentenceFixKept, kind != .sentenceFixUndone, !typed.isEmpty else { return }
        append(.word(how: kind.rawValue, typed: typed, final: final, offered: offered))
    }

    /// A fix made to a finished sentence, once the writer has typed on (kept) or undone it.
    func noteSentenceFix(original: String, corrected: String, kept: Bool) {
        append(.sentenceFix(original: original, corrected: corrected, kept: kept))
    }

    // MARK: - For the writer

    /// How many sentences are saved, for the count shown in Settings.
    func sentenceCount() -> Int {
        lines().reduce(into: 0) { count, line in
            if case .sentence = line.event { count += 1 }
        }
    }

    /// Whether the file holds anything at all. Settings goes by this, and not by the sentence
    /// count, to say whether there is something to look at, export or delete. The two differ:
    /// `noteSentence` drops fragments, links and code, but the word, decision, strip and fix lines
    /// for that same text are still written, and they hold typed words and the text before them.
    /// A pane that went by the count said "Nothing saved" and greyed out Delete All over a file
    /// that had the writer's words in it.
    func hasSavedData() -> Bool {
        guard let fileURL,
              let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber
        else { return false }
        return size.intValue > 0
    }

    /// Writes the training examples to `destination`, one JSON object per line, and returns how
    /// many there are.
    @discardableResult
    func export(to destination: URL) throws -> Int {
        let examples = TrainingExampleBuilder.examples(fromLines: lines())
        try TrainingExampleBuilder.jsonLines(examples).write(to: destination, options: .atomic)
        return examples.count
    }

    /// Deletes the record, and with it what this launch remembers about the file it was writing.
    /// The next line then starts a file the way a launch's first line does: the build line goes in
    /// front of it (`append` writes that only at order zero), it is numbered and timed from itself,
    /// and a decision reached again is written again. Left as they were, the new file had no build
    /// line until the next launch, and a decision equal to the last one before the delete was
    /// skipped as a repeat of a line that no longer existed.
    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
        order = 0
        firstUptime = nil
        lastDecision = nil
    }

    // MARK: - File

    private func lines() -> [TrainingLogLine] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]).flatMap(TrainingLogLine.init(json:))
        }
    }

    /// The next line's place in this launch's sequence, with the time since its first line.
    private func nextStamp() -> TrainingLogLine.Stamp {
        let now = uptimeNanoseconds()
        let first = firstUptime ?? now
        firstUptime = first
        order += 1
        return .init(run: run, order: order, milliseconds: Int((now - first) / 1_000_000))
    }

    private func append(_ event: TrainingLogEvent) {
        guard isEnabled(), fileURL != nil else { return }
        // The first line of a launch is preceded by the line that says which build wrote it.
        if order == 0, let session = session?() {
            write(TrainingLogLine(session, stamp: nextStamp()))
        }
        write(TrainingLogLine(event, stamp: nextStamp()))
    }

    private func write(_ line: TrainingLogLine) {
        guard let fileURL,
              let data = try? JSONSerialization.data(withJSONObject: line.json, options: [.sortedKeys]) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                // Readable by this user only, whatever the folder above it allows.
                FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data("\n".utf8))
            if try handle.offset() > UInt64(Self.maximumBytes) { trimToNewerHalf() }
        } catch {
            CotabbyLogger.app.error("Could not write the training log: \(error.localizedDescription)")
        }
    }

    private func trimToNewerHalf() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        // The newer half starts at the first line break past the middle: one search and one copy,
        // where joining the kept lines one at a time copied everything again for each line.
        let middle = data.startIndex + data.count / 2
        guard let lineBreak = data[middle...].firstIndex(of: UInt8(ascii: "\n")) else { return }
        try? data[data.index(after: lineBreak)...].write(to: fileURL, options: .atomic)
    }
}
