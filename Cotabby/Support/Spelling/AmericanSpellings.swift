import Foundation

/// File overview:
/// Words that are one word spelled two ways across the Atlantic (`neighbour`/`neighbor`,
/// `travelling`/`traveling`), and the choice between them.
///
/// The spelling dictionary holds both spellings, so a slip that sits one letter from the British
/// one (`neighbur`) was fixed to `neighbour` on an American's Mac, and the word strip offered both
/// spellings side by side. With a preference set, every place that offers or applies a word passes
/// it through here first: a fix or a suggestion in the British spelling becomes the American one.
///
/// What the writer types themselves is not touched by this type: it changes what Cotabby proposes,
/// not what counts as a mistake.
///
/// The pairs come from `american_spellings_en.txt`, built by
/// `Tools/prediction/build_american_spellings.py` (spelling rules checked against how often each
/// form is used, then read by a person). Pure and immutable, so it is shared freely.
nonisolated struct AmericanSpellings: Sendable {
    private let americanByBritish: [String: String]

    /// - Parameter contents: one `british american` pair per line, lowercase.
    init(contents: String) {
        var pairs: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count == 2 else { continue }
            pairs[String(fields[0])] = String(fields[1])
        }
        americanByBritish = pairs
    }

    var isEmpty: Bool { americanByBritish.isEmpty }

    /// The American spelling of `word`, with the capitals `word` had; nil when `word` is not a
    /// British spelling on the list (which is nearly always).
    func american(for word: String) -> String? {
        guard let american = americanByBritish[word.lowercased()] else { return nil }
        return TypoCaseTransfer.applying(caseOf: word, to: american)
    }

    /// `words` with every British spelling replaced by its American one, in the same order. A word
    /// that is then listed twice keeps its first place (`favourite, favorite` becomes `favorite`).
    func preferring(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.compactMap { word in
            let preferred = american(for: word) ?? word
            return seen.insert(preferred.lowercased()).inserted ? preferred : nil
        }
    }

    /// The bundled list when this Mac's region writes the American way, nil elsewhere (and for
    /// anyone who set `cotabbySpellingStyle` to `british` in the app's defaults; `american` turns
    /// it on in any region).
    static func preferredOnThisMac(
        bundle: Bundle = .main, defaults: UserDefaults = .standard, region: String? = Locale.current.region?.identifier
    ) -> AmericanSpellings? {
        let choice = defaults.string(forKey: styleDefaultsKey)
        guard choice == "american" || (choice != "british" && region == "US") else { return nil }
        guard let url = bundle.url(forResource: "american_spellings_en", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let spellings = AmericanSpellings(contents: contents)
        return spellings.isEmpty ? nil : spellings
    }

    static let styleDefaultsKey = "cotabbySpellingStyle"
}
