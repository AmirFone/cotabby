import Foundation

/// File overview:
/// The last few things the writer finished, shown to the word language model before the text of
/// the field they are typing in now.
///
/// Why: in a chat box or a comment field the model only ever saw the message being typed, so it
/// began every message knowing nothing about the writer's subject, their terms or the names they
/// use, and its first guesses were those of a stranger. In a long document it does far better,
/// because the document itself tells it all that. Measured on a day of one writer's real work
/// sentences, reading the previous messages first put the first suggestion right after one typed
/// letter 53% of the time against 44%, and after two letters 65% against 54%; twenty invented
/// writers in twenty jobs gained six to ten points the same way (`Tools/prediction/README.md`).
/// It also lets the strip offer a name or a term from an earlier message (`TextVocabulary` reads
/// the same text the model does).
///
/// What is kept: sentences the writer finished and left unchanged, which the proofreader would not
/// touch, newest last, about a page at most. In memory only: nothing here is written to disk, and
/// it is gone when Cotabby quits. It follows the "learn from my writing" switch, because the same
/// call that learns a sentence adds it here, and clearing what was learned clears it too.
///
/// Owned by `CotabbyAppEnvironment`; `WordLanguageModelService` reads it on every request.
@MainActor
final class RecentWriting {
    /// Past this the oldest texts are dropped, down to `charactersKeptAfterTrim`. Dropping in one
    /// step, not one text per new sentence, keeps the beginning of what the model reads unchanged
    /// for many sentences in a row, so it re-reads this page once in a while and not every time.
    ///
    /// Measured on four writers: 600 characters shown instead of 1,200 cost about a point of
    /// first-suggestion accuracy, 2,400 gained under a point on invented writers and nothing on
    /// real sentences, for twice the text to re-read. So the page stays between 800 and 1,200.
    static let maximumCharacters = 1_200
    static let charactersKeptAfterTrim = 800
    /// A text longer than this is not kept: it is a pasted block more often than something typed,
    /// and it would push out everything else.
    static let longestTextKept = 600
    /// A field with this much text of its own tells the model enough, and the room is better
    /// spent on that text (`LanguageModelContext.Reach`).
    static let fieldTextThatNeedsNone = 800

    private(set) var texts: [String] = []
    private var length = 0

    /// Remembers a finished text.
    func add(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= Self.longestTextKept, texts.last != text else { return }
        texts.append(text)
        length += text.utf8.count + 1
        guard length > Self.maximumCharacters else { return }
        while length > Self.charactersKeptAfterTrim, texts.count > 1 {
            length -= texts.removeFirst().utf8.count + 1
        }
    }

    func clear() {
        texts = []
        length = 0
    }

    /// What the model should read before `textBefore`: the kept texts, one per line, without those
    /// the field itself still shows (a sentence just finished in a document is in both places, and
    /// reading it twice would tell the model it is being repeated). Empty when the field has
    /// enough text of its own.
    func preamble(for textBefore: String) -> String {
        guard !texts.isEmpty, textBefore.utf8.count < Self.fieldTextThatNeedsNone else { return "" }
        let shown = texts.filter { !textBefore.contains($0) }
        return shown.isEmpty ? "" : shown.joined(separator: "\n") + "\n"
    }
}
