import Foundation
import Logging

/// A local, append-only record of spelling events, so the engine can be tuned against this
/// writer's real mistakes (`cotabby-spell --journal`) and the writer can see what it learned.
///
/// It is deliberately not a keystroke log: it stores only the word that was wrong, what it became,
/// how, and one word of context. Nothing else typed is written, secure fields never reach the
/// pipeline, and the file lives in Application Support and never leaves the Mac. One JSON object per
/// line; trimmed to its newer half past `maximumBytes`.
@MainActor
final class CorrectionJournal {
    enum Kind: String {
        /// Cotabby fixed it automatically and the writer typed on.
        case autoFixKept
        /// Cotabby fixed it automatically and the writer undid it.
        case autoFixUndone
        /// The writer picked a fix from the spelling bar or card.
        case picked
        /// The writer kept the word as typed from the bar.
        case keptAsTyped
        /// The writer went back and retyped the word themselves.
        case selfCorrected
        /// A sentence fix the writer kept or undid.
        case sentenceFixKept
        case sentenceFixUndone
    }

    static let enabledDefaultsKey = "cotabbyCorrectionJournalEnabled"
    static let maximumBytes = 2_000_000

    let fileURL: URL?
    private let isEnabled: () -> Bool

    init(fileURL: URL? = CorrectionJournal.defaultFileURL(), isEnabled: @escaping () -> Bool = CorrectionJournal.isEnabledInDefaults) {
        self.fileURL = fileURL
        self.isEnabled = isEnabled
    }

    nonisolated deinit {}

    nonisolated static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Cotabby", isDirectory: true)
            .appendingPathComponent("correction-journal.jsonl")
    }

    static func isEnabledInDefaults() -> Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    func record(_ kind: Kind, typed: String, final: String, previousWord: String? = nil) {
        guard isEnabled(), let fileURL, !typed.isEmpty else { return }
        var entry: [String: String] = [
            "time": ISO8601DateFormatter().string(from: Date()),
            "kind": kind.rawValue,
            "typed": typed,
            "final": final
        ]
        if let previousWord { entry["previous"] = previousWord }
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data("\n".utf8))
            if try handle.offset() > UInt64(Self.maximumBytes) { trimToNewerHalf() }
        } catch {
            CotabbyLogger.app.error("Could not write the correction journal: \(error.localizedDescription)")
        }
    }

    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func trimToNewerHalf() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let lines = data.split(separator: UInt8(ascii: "\n"))
        let kept = lines.suffix(lines.count / 2).map { Data($0) + Data("\n".utf8) }.reduce(Data(), +)
        try? kept.write(to: fileURL, options: .atomic)
    }
}
