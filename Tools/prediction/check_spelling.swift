import AppKit

/// Reads "word count" lines and prints those the system spell checker accepts as American English.
/// Used by `build_word_supplement.py`; the language is pinned because with none given the checker
/// accepts words from every language enabled on the Mac.
let checker = NSSpellChecker.shared
let language = "en_US"
guard checker.setLanguage(language) else { fatalError("no en_US dictionary on this Mac") }
let tag = NSSpellChecker.uniqueSpellDocumentTag()
while let line = readLine() {
    let fields = line.split(separator: " ")
    guard fields.count == 2 else { continue }
    let range = checker.checkSpelling(
        of: String(fields[0]), startingAt: 0, language: language, wrap: false,
        inSpellDocumentWithTag: tag, wordCount: nil
    )
    if range.location == NSNotFound { print(line) }
}
