import Foundation

/// File overview:
/// The bundled software-engineering vocabulary: where its two word lists are and whether they are
/// in use.
///
/// The general dictionary knows `server` and `database` but not `backend`, `config`, `async`,
/// `kubectl` or `jsonb`. For someone who writes about software, the strip then never offers the
/// word they are typing and the spelling engine flags it or changes it into an ordinary word.
/// `Tools/prediction/build_technical_words.py` writes two lists for that, and decides there, once,
/// which term goes where:
/// - `technical_words_en.txt` for the word strip: every term with a count and its usual capitals
///   (`json 3000000 JSON`). The strip's sources read it like any other word list.
/// - `technical_spelling_en.txt` for the spelling dictionary: the terms the dictionary lacks,
///   without those that are one ordinary slip from a common word, because such a term there makes
///   the slip look right (`aws` for `was`).
///
/// It is on unless turned off (`defaults write <app> cotabbyTechnicalVocabularyEnabled -bool false`):
/// the terms only compete where the text calls for them, and measured on ordinary text nothing
/// changes (see FORK.md). The lists are read once at launch by the features that use them.
nonisolated enum TechnicalVocabulary {
    static let enabledDefaultsKey = "cotabbyTechnicalVocabularyEnabled"
    static let stripListName = "technical_words_en"
    static let spellingListName = "technical_spelling_en"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// The strip's list in the app bundle, or nil when the vocabulary is off or the file is missing.
    static func stripListURL(in bundle: Bundle = .main, defaults: UserDefaults = .standard) -> URL? {
        isEnabled(in: defaults) ? bundle.url(forResource: stripListName, withExtension: "txt") : nil
    }

    /// The spelling dictionary's lines (`word count`), or nothing when the vocabulary is off.
    static func spellingLines(in bundle: Bundle = .main, defaults: UserDefaults = .standard) -> String {
        guard isEnabled(in: defaults), let url = bundle.url(forResource: spellingListName, withExtension: "txt") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// The terms the spelling dictionary took, in lowercase; empty when the vocabulary is off.
    static func spellingTerms(in bundle: Bundle = .main, defaults: UserDefaults = .standard) -> Set<String> {
        terms(inSpellingList: spellingLines(in: bundle, defaults: defaults))
    }

    static func terms(inSpellingList contents: String) -> Set<String> {
        Set(contents.split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap { $0.split(separator: " ").first.map(String.init) })
    }

    /// The usual capitals of the terms that have them, by lowercase word (`github` → `GitHub`).
    /// A term that is also an ordinary word (`swift`, `spring`) has none in the list, so the strip
    /// does not capitalize it in every sentence.
    static func capitals(inStripList contents: String) -> [String: String] {
        var capitals: [String: String] = [:]
        for line in contents.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: " ")
            if fields.count == 3 { capitals[String(fields[0])] = String(fields[2]) }
        }
        return capitals
    }
}
