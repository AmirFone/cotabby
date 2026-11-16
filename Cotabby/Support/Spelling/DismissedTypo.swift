import Foundation

/// File overview:
/// The word whose spelling bar the writer just closed with Escape. Escape means "leave this word
/// alone", so until the caret moves on to another word the gate neither reopens the bar nor fixes
/// the word when Space finishes it. Without this the bar came straight back on the next keystroke.
///
/// It is deliberately short-lived and not saved: the same misspelling typed again later is offered
/// again (keeping a word for good is what the quoted "as typed" slot does), and the sentence pass
/// still gets a look once the sentence is finished.
nonisolated struct DismissedTypo: Equatable, Sendable {
    /// Everything in the field before the word.
    let textBefore: String
    let word: String

    /// Nil when the caret is not at a word (nothing to dismiss).
    init?(precedingText: String) {
        guard let current = CurrentWordExtractor.extractTrailingWord(from: precedingText),
              let before = CurrentWordExtractor.textBeforeTrailingWord(in: precedingText) else { return nil }
        textBefore = before
        word = current.result.word
    }

    /// True while the caret is still at that word: the same letters, more letters added to them, or
    /// the word just finished with a space or punctuation.
    func covers(precedingText: String) -> Bool {
        guard let current = CurrentWordExtractor.extractTrailingWord(from: precedingText),
              CurrentWordExtractor.textBeforeTrailingWord(in: precedingText) == textBefore else { return false }
        return current.result.word.lowercased().hasPrefix(word.lowercased())
    }
}
