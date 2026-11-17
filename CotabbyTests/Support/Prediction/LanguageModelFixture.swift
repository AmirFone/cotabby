import Foundation
@testable import Cotabby

/// A language model answer written by hand, for tests of what is done with one.
enum LanguageModelFixture {
    /// The answer for `textBefore` in which each given word has the given probability and every
    /// word is a single piece of its own. Words not listed are unknown to this "model".
    ///
    /// `textWords` are the writer's own words the "model" found in the text: how each is written,
    /// and its probability (nil for a dictionary word that only gets its capital from the text).
    static func scores(
        textBefore: String, _ probabilities: [String: Float], textWords: [(display: String, probability: Float?)] = []
    ) -> LanguageModelScores {
        let words = probabilities.keys.sorted()
        let ids = Dictionary(uniqueKeysWithValues: words.enumerated().map { (" " + $1, Int32($0)) })
        let lexicon = LanguageModelLexicon(entries: words.map { ($0, 1) }, pieces: { ids[$0].map { [$0] } ?? [] })
        let raw = words.map { log(probabilities[$0] ?? 1e-9) }
        // The text is expected to end at a space, where every fixture word is spelled with one.
        let key = LanguageModelContext.make(textBefore: textBefore)?.key ?? .init(text: textBefore, isSpaced: true)
        let result = raw.withUnsafeBufferPointer { lexicon.probabilities(scores: $0, normalizer: 0, isSpaced: key.isSpaced) }
        return LanguageModelScores(
            key: key, lexicon: lexicon, probabilities: result,
            textWords: textWords.map {
                .init(display: $0.display, lowercased: $0.display.lowercased(), logProbability: $0.probability.map { log($0) })
            }
        )
    }
}
