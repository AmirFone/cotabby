import Foundation
import Logging

/// File overview:
/// The writer's own training record: finished sentences and what became of the fixes offered in
/// them, kept in one local file so a spelling model can be trained on this writer's mistakes.
///
/// What makes this a training record and not a keystroke log, and must stay true of it:
/// - **Off until the writer switches it on** (`enabledDefaultsKey` defaults to false). With it off
///   every method here returns before touching the disk.
/// - **Only finished sentences and spelling decisions.** No keys, no shortcuts, no text that was
///   typed and deleted, no app or window names, no time of day (a calendar date only).
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
    /// About 100,000 sentences. Past this the older half is dropped, so the file cannot grow
    /// without bound on a Mac where it was switched on and forgotten.
    static let maximumBytes = 20_000_000
    /// A "sentence" longer than this is pasted text or a run-on with no stops, not something to
    /// train a sentence model on.
    static let maximumSentenceCharacters = 400

    let fileURL: URL?
    private let isEnabled: () -> Bool
    private let today: () -> Date

    init(
        fileURL: URL? = TrainingLog.defaultFileURL(),
        isEnabled: @escaping () -> Bool = TrainingLog.isEnabledInDefaults,
        today: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.isEnabled = isEnabled
        self.today = today
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

    // MARK: - Recording

    /// A finished sentence the writer left standing. Fragments, pasted blocks, and anything with a
    /// web address, an email address, or code in it are not saved.
    func noteSentence(_ sentence: String) {
        guard sentence.count <= Self.maximumSentenceCharacters,
              sentence.split(whereSeparator: \.isWhitespace).count >= 3,
              !FinishedSentenceExtractor.looksMachineReadable(sentence) else { return }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        append(.sentence(text: sentence, day: formatter.string(from: today())))
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
        events().reduce(into: 0) { count, event in
            if case .sentence = event { count += 1 }
        }
    }

    /// Writes the training examples to `destination`, one JSON object per line, and returns how
    /// many there are.
    @discardableResult
    func export(to destination: URL) throws -> Int {
        let examples = TrainingExampleBuilder.examples(from: events())
        try TrainingExampleBuilder.jsonLines(examples).write(to: destination, options: .atomic)
        return examples.count
    }

    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - File

    private func events() -> [TrainingLogEvent] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]).flatMap(TrainingLogEvent.init(json:))
        }
    }

    private func append(_ event: TrainingLogEvent) {
        guard isEnabled(), let fileURL,
              let data = try? JSONSerialization.data(withJSONObject: event.json, options: [.sortedKeys]) else { return }
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
        let lines = data.split(separator: UInt8(ascii: "\n"))
        let kept = lines.suffix(lines.count / 2).map { Data($0) + Data("\n".utf8) }.reduce(Data(), +)
        try? kept.write(to: fileURL, options: .atomic)
    }
}
