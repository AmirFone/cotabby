import Foundation

/// File overview:
/// The text before the caret as the writer's keys say it must be, kept next to what the field
/// itself reports.
///
/// Why this exists: a host tells Accessibility about a key some time after it was typed, 30 to
/// 400 ms in Electron and Chromium apps, often longer than the gap to the next key. A read of the
/// field in that time is true and old. Three things went wrong by taking such a read for the text
/// now: a pick counted its backspaces against letters the field had already moved past, the strip
/// was put back to a word the writer had finished, and the spelling check looked at the middle of
/// a burst and never at its end.
///
/// So the keys are followed themselves. `text` is the last read with every key since applied, and
/// `earlier` is each state the text passed through on the way. A read can then be placed exactly:
/// it is the text now (`holds`), or one of those earlier states, which is a host that is behind
/// (`isEarlierState`), or neither, which is a field that something other than these keys changed
/// and that has to be believed.
///
/// Why the states are remembered instead of comparing prefixes: "the read is the expected text
/// without its last few characters" is also true of a field where the writer deleted those
/// characters by some means no key showed, and "with a few more" is true after text was accepted
/// into it. A remembered state is only ever a text this field really held a moment ago.
///
/// Pure and small. `WordPredictionController` owns one per focused field, tells it what each key
/// does, and asks it before believing a read.
nonisolated struct TextFromKeys: Equatable, Sendable {
    /// The text before the caret by now; nil when a key was seen whose effect the key alone does
    /// not tell (an arrow, a shortcut, composed input), until the field is read again.
    private(set) var text: String?
    /// The ends of the states the text passed through since the last read, oldest first.
    private var earlier: [String] = []

    /// Texts are compared by their last characters: the focus reader keeps only the last few
    /// thousand characters before the caret, so in a long document one typed key pushes a
    /// character out at the front and two readings never match as wholes. A shorter text is
    /// compared whole.
    static let comparedTailLength = 200
    /// More states than a writer types keys in the longest time a host is waited for.
    static let mostEarlierStates = 64

    /// The field was read and holds `text`; nil when no field is known.
    mutating func settle(on text: String?) {
        self.text = text
        earlier = []
    }

    /// A key did `change` to the text: the new text, or nil when the key alone does not tell.
    /// After a key of the second kind nothing is known until the next read.
    mutating func apply(_ change: (String) -> String?) {
        guard let current = text else { return }
        guard let next = change(current) else {
            settle(on: nil)
            return
        }
        move(from: current, to: next)
    }

    /// Cotabby typed something itself and the field will hold `next`, passing through `steps` on
    /// the way (a pick deletes the letters typed and types the word, a key at a time).
    mutating func jump(to next: String, through steps: [String] = []) {
        if let current = text { remember(current) }
        steps.forEach { remember($0) }
        text = next
    }

    /// True when the field reads as the text the keys left.
    func holds(_ read: String) -> Bool {
        text.map { Self.end(of: $0) == Self.end(of: read) } ?? false
    }

    /// True when `read` is a state the text passed through since the last read, and not the text
    /// now: what a host shows while it has not published the last keys.
    func isEarlierState(_ read: String) -> Bool {
        let end = Self.end(of: read)
        guard let text, Self.end(of: text) != end else { return false }
        return earlier.contains(end)
    }

    /// Whether `read` is the text now with `typed` after it: a field that shows a key this model
    /// has not been told about yet. Nil when the text is not known, and the caller has to judge
    /// the field some other way.
    ///
    /// A host can be told about a key a few milliseconds before Cotabby is. Whoever then waits
    /// for the field to change waits for a change that has already happened. Asked of the keys,
    /// the answer is exact through a burst, and a doubled letter does not fool it: after `al`
    /// and a second `l`, a field that reads `al` is one key behind, not one ahead.
    func isAhead(_ read: String, by typed: String) -> Bool? {
        text.map { Self.end(of: $0 + typed) == Self.end(of: read) }
    }

    /// True when a read that says `after` follows the caret is a read taken while keys were
    /// landing: the caret is from before the last keys and the text from after them, so the
    /// letters "after the caret" are the ones just typed. `before` and the first letters of
    /// `after` together are then the text the keys left.
    ///
    /// A field is asked for its text and for its caret in separate requests. A native view
    /// answers both within a millisecond. An app that takes 30 ms or more per answer is often
    /// typed into between the two, and the read then looked like a caret in the middle of a
    /// word, where the strip offers nothing: it came down while the writer was typing, and Tab
    /// went to the app.
    func isCaretBehindItsText(before: String, after: String) -> Bool {
        guard let text, !after.isEmpty else { return false }
        let now = Self.end(of: text)
        var joined = before
        for character in after.prefix(Self.mostKeysDuringOneRead) {
            joined.append(character)
            if Self.end(of: joined) == now { return true }
        }
        return false
    }

    /// More keys than a writer types while one read of the field is answered.
    static let mostKeysDuringOneRead = 8

    static func isSameText(_ one: String, _ other: String) -> Bool {
        end(of: one) == end(of: other)
    }

    private mutating func move(from current: String, to next: String) {
        remember(current)
        text = next
    }

    private mutating func remember(_ state: String) {
        earlier.append(Self.end(of: state))
        if earlier.count > Self.mostEarlierStates { earlier.removeFirst(earlier.count - Self.mostEarlierStates) }
    }

    private static func end(of text: String) -> String {
        String(text.suffix(comparedTailLength))
    }
}
