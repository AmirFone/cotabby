import Foundation

/// File overview:
/// Reduces an English spelling to how it sounds, so a word spelled the way it is pronounced
/// (`enuf`, `becos`, `skool`, `fisical`) finds the dictionary word it sounds like even when the
/// letters are three or more edits apart. Dyslexic misspellings are very often phonetic, and edit
/// distance alone cannot reach them.
///
/// The scheme is Metaphone-like: consonants are mapped to sound classes, vowels are dropped (except
/// a leading one), and doubled sounds collapse. Spellings that can be pronounced more than one way
/// (`gh` in enough / night, `ch` in chair / school, `l` in could) produce several keys, and a word is
/// indexed under all of them, so ambiguity widens the net instead of guessing.
nonisolated enum PhoneticKey {
    /// At most this many alternative keys per word; ambiguous spellings multiply quickly.
    static let maximumKeys = 4

    static func keys(for word: String) -> [String] {
        let letters = Array(word.lowercased().filter { $0.isLetter && $0.isASCII })
        guard letters.count >= 2 else { return [] }
        var results: [[Character]] = [[]]
        var index = 0
        while index < letters.count {
            let (options, consumed) = sounds(at: index, in: letters)
            var next: [[Character]] = []
            for partial in results {
                for option in options {
                    next.append(partial + option)
                }
            }
            results = Array(next.prefix(maximumKeys))
            index += consumed
        }
        var seen = Set<String>()
        return results.compactMap { raw in
            let key = String(collapse(raw))
            return key.isEmpty || !seen.insert(key).inserted ? nil : key
        }
    }

    private static func isVowel(_ character: Character?) -> Bool {
        guard let character else { return false }
        return "aeiouy".contains(character)
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    /// The sound options for the letters starting at `index`, and how many letters they cover.
    private static func sounds(at index: Int, in letters: [Character]) -> ([[Character]], Int) {
        let current = letters[index]
        let next = index + 1 < letters.count ? letters[index + 1] : nil
        let afterNext = index + 2 < letters.count ? letters[index + 2] : nil
        let previous = index > 0 ? letters[index - 1] : nil
        let isFirst = index == 0
        func starts(_ text: String) -> Bool {
            let chars = Array(text)
            guard index + chars.count <= letters.count else { return false }
            return Array(letters[index..<(index + chars.count)]) == chars
        }

        if isFirst {
            for (prefix, sound) in [("kn", "n"), ("gn", "n"), ("pn", "n"), ("wr", "r"), ("ps", "s"), ("wh", "w")]
            where starts(prefix) {
                return ([Array(sound)], 2)
            }
            if isVowel(current) { return ([["A"]], 1) }
        }
        if isVowel(current) { return ([[]], 1) }

        switch current {
        case "b":
            // Silent final b: climb, thumb.
            return (previous == "m" && next == nil ? [[]] : [["b"]], 1)
        case "c":
            if starts("ch") { return ([["x"], ["k"]], 2) }
            if starts("ck") { return ([["k"]], 2) }
            // ocean, special, delicious: c before a vowel pair can sound like "sh".
            if let next, "ei".contains(next), let afterNext, "aou".contains(afterNext) { return ([["x"], ["s"]], 1) }
            if let next, "eiy".contains(next) { return ([["s"]], 1) }
            return ([["k"]], 1)
        case "d":
            if starts("dge") || starts("dgi") || starts("dgy") { return ([["j"]], 2) }
            if starts("dj") { return ([["j"]], 2) }
            return ([["t"]], 1)
        case "g":
            if starts("gh") {
                // enough / cough (f), night / though (silent), ghost (g).
                return (isFirst ? [["g"]] : [["f"], []], 2)
            }
            if starts("gn"), afterNext == nil { return ([["n"]], 2) }
            if let next, "eiy".contains(next) { return ([["j"], ["g"]], 1) }
            return ([["k"]], 1)
        case "h":
            // Sounded only before a vowel and not after another consonant sound.
            return (isVowel(next) && !"cgpstwz".contains(previous ?? " ") ? [["h"]] : [[]], 1)
        case "k":
            return ([["k"]], 1)
        case "l":
            // could / would / should, talk / walk: a silent l after a vowel before d or k.
            if isVowel(previous), let next, "dk".contains(next) { return ([["l"], []], 1) }
            return ([["l"]], 1)
        case "p":
            if starts("ph") { return ([["f"]], 2) }
            return ([["p"]], 1)
        case "q":
            return ([["k"]], starts("qu") ? 2 : 1)
        case "s":
            if starts("sch") { return ([["s", "k"]], 3) }
            if starts("sh") { return ([["x"]], 2) }
            if starts("sio") || starts("sia") { return ([["x"], ["s"]], 1) }
            return ([["s"]], 1)
        case "t":
            if starts("tch") { return ([["x"]], 3) }
            if starts("th") { return ([["0"]], 2) }
            if starts("tio") || starts("tia") { return ([["x"]], 1) }
            // picture, nature, actually: "tu" before r or a vowel often sounds like "ch".
            if next == "u", let afterNext, "raeol".contains(afterNext) { return ([["t"], ["x"]], 1) }
            return ([["t"]], 1)
        case "v":
            return ([["f"]], 1)
        case "w":
            // Only a sounded w before a vowel: was, went (not law, now). After a consonant or between
            // vowels it is often swallowed (answer, sword, towards), so it is optional there.
            guard isVowel(next) else { return ([[]], 1) }
            return (isFirst ? [["w"]] : [["w"], []], 1)
        case "x":
            return (isFirst ? [["s"]] : [["k", "s"]], 1)
        case "z":
            return ([["s"]], 1)
        default:
            return ([[current]], 1)
        }
    }

    // swiftlint:enable cyclomatic_complexity function_body_length

    private static func collapse(_ key: [Character]) -> [Character] {
        var result: [Character] = []
        for character in key where character != result.last {
            result.append(character)
        }
        return result
    }
}
