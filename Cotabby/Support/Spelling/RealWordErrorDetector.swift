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
        ["hole", "whole"],
        // Homophones judged by the n-gram sentence rule; one previous word could not tell these
        // apart, three usually can.
        ["no", "know"],
        ["for", "four"],
        ["one", "won"],
        ["see", "sea"],
        ["son", "sun"],
        ["meet", "meat"],
        ["our", "hour"],
        ["ate", "eight"],
        ["brake", "break"],
        ["wood", "would"],
        ["wait", "weight"],
        ["allowed", "aloud"],
        ["threw", "through"],
        ["mail", "male"],
        ["plain", "plane"],
        ["tail", "tale"],
        ["pair", "pear"],
        ["flower", "flour"],
        ["road", "rode"],
        ["knight", "night"],
        ["not", "knot"],
        ["blew", "blue"],
        ["made", "maid"],
        ["sale", "sail"],
        ["cell", "sell"],
        ["dear", "deer"],
        ["heal", "heel"],
        ["hair", "hare"],
        ["fair", "fare"],
        ["bored", "board"],
        ["scene", "seen"],
        ["steal", "steel"],
        ["course", "coarse"],
        ["are", "our"],
        ["of", "off"]
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

    /// Sentence-rule thresholds, tuned with `cotabby-spell --accuracy`/`--clean` on Tatoeba sentences
    /// with swapped confusables: recall 70.7% → 79.7%, false alarms on correct words 1.2% → 0.5%.
    /// An alternative must be at least this much likelier than the typed word...
    static let sentenceMinimumRatio = 8.0
    /// ...and likely in its own right after the sentence so far.
    static let sentenceMinimumScore = 0.01
    /// The typed word's own likelihood is floored, since the pruned table omits rare continuations.
    static let sentenceScoreFloor = 0.002
    /// The typed word "fits" (vetoing a flag) when at least this fraction as likely as the best alternative.
    static let sentenceVetoFraction = 0.5

    /// Sentence-level check with the n-gram table (up to three words of context, contractions
    /// intact). Returns the alternatives it flags, and whether it vetoes the typed word being
    /// flagged at all because the sentence model finds it likely enough.
    static func sentenceVerdict(word: String, score: (String) -> Double) -> (flagged: [SpellingCandidate], typedFits: Bool) {
        let options = alternatives(for: word)
        guard !options.isEmpty else { return ([], true) }
        let typed = score(word.lowercased())
        let floor = sentenceScoreFloor
        var flagged: [SpellingCandidate] = []
        var bestAlternative = 0.0
        for option in options {
            let value = score(option)
            bestAlternative = max(bestAlternative, value)
            if value >= sentenceMinimumScore, value >= sentenceMinimumRatio * max(typed, floor) {
                flagged.append(SpellingCandidate(
                    term: TypoCaseTransfer.applying(caseOf: word, to: option),
                    score: min(0.8, 0.55 + 0.05 * log10(value / max(typed, floor)))
                ))
            }
        }
        return (flagged.sorted { $0.score > $1.score }, typed > 0 && typed >= sentenceVetoFraction * bestAlternative)
    }

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
