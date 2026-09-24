import Foundation

/// File overview:
/// Catches correctly spelled words that are the wrong word: `their` for `there`, `form` for `from`,
/// `then` for `than`. A spell checker cannot see these, and they are among the most common slips for
/// dyslexic writers because the letters are all present.
///
/// Detection is local and conservative: it fires only when the previous word makes the typed word
/// far less likely than a sound-alike (by bigram count). A miss is cheap (the sentence check or the
/// writer catches it later); a false alarm interrupts a correct sentence, so the bar is high.
enum RealWordErrorDetector {
    /// Groups of words that are commonly swapped for one another. Pairs where the previous word alone
    /// cannot tell them apart (`I no longer` / `I know`, `turn of the century` / `turn off`) are left
    /// out on purpose.
    static let confusableGroups: [[String]] = [
        ["their", "there", "they're"],
        ["your", "you're"],
        ["its", "it's"],
        ["to", "too"],
        ["then", "than"],
        ["form", "from"],
        ["were", "where", "we're"],
        ["loose", "lose"],
        ["affect", "effect"],
        ["accept", "except"],
        ["quite", "quiet"],
        ["weather", "whether"],
        ["advise", "advice"],
        ["breath", "breathe"],
        ["passed", "past"],
        ["whose", "who's"],
        ["new", "knew"],
        ["right", "write"],
        ["hear", "here"],
        ["buy", "by"],
        ["week", "weak"],
        ["piece", "peace"],
        ["thought", "though", "through"],
        ["desert", "dessert"],
        ["lead", "led"],
        ["principal", "principle"],
        ["stationary", "stationery"],
        ["complement", "compliment"],
        ["dose", "does"],
        ["want", "what"],
        ["ware", "wear", "where"],
        // Sound-it-out spellings that happen to be real words.
        ["cud", "could"],
        ["tuff", "tough"],
        ["strait", "straight"],
        ["wether", "whether", "weather"],
        ["exited", "excited"],
        ["sed", "said"],
        ["rite", "right", "write"],
        ["sum", "some"],
        ["wen", "when"],
        ["cort", "caught"],
        ["lite", "light"],
        ["thier", "their"],
        ["witch", "which"],
        ["hole", "whole"]
    ]

    private static let groupsByWord: [String: [String]] = {
        var map: [String: [String]] = [:]
        for group in confusableGroups {
            for word in group {
                map[word, default: []].append(contentsOf: group.filter { $0 != word })
            }
        }
        return map
    }()

    /// The typed word's pairing with the previous word must be at least this many times rarer...
    static let minimumRatio: Double = 12
    /// ...and the alternative's pairing must be at least this common, so rare phrases never trigger.
    static let minimumAlternativeCount: Int64 = 20_000_000

    static func alternatives(for word: String) -> [String] {
        groupsByWord[word.lowercased()] ?? []
    }

    /// Ranked replacements for `word` given the word before it, or empty when `word` fits.
    /// - Parameter count: bigram count of (`previous`, candidate); nil when the model is not loaded.
    static func candidates(
        word: String,
        previous: String,
        minimumRatio: Double = minimumRatio,
        count: (_ previous: String, _ word: String) -> Int64?
    ) -> [SpellingCandidate] {
        let options = alternatives(for: word)
        guard !options.isEmpty, let typedCount = count(previous, word.lowercased()) else { return [] }
        let floor = max(Double(typedCount), 1_000_000)
        return options
            .compactMap { option -> SpellingCandidate? in
                guard let optionCount = count(previous, option),
                      optionCount >= minimumAlternativeCount,
                      Double(optionCount) >= floor * minimumRatio else { return nil }
                let ratio = Double(optionCount) / floor
                return SpellingCandidate(
                    term: TypoCaseTransfer.applying(caseOf: word, to: option),
                    score: min(0.8, 0.55 + 0.05 * log10(ratio))
                )
            }
            .sorted { $0.score > $1.score }
    }
}
