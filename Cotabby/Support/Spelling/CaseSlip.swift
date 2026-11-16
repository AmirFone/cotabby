import Foundation

/// File overview:
/// Undoes Shift-key timing slips, which are not spelling mistakes and need no ranking: Shift held
/// one letter too long (`THe` → The, `HEllo` → Hello) or pressed one letter too late (`kKing` →
/// King, `tThe` → The). The spell checker either accepts these or guesses at unrelated words
/// (`THe` → Thee), so they are recognized by shape before it is asked.
///
/// A fix is offered only when the result is a dictionary word, which keeps units and plural
/// acronyms (`MHz`, `IDs`, `PCs`) and deliberate mixed case (`iPhone`, `McDonald`) untouched.
nonisolated enum CaseSlip {
    /// - Parameter isWord: whether a lowercased word is in the dictionary.
    static func fix(for word: String, isWord: (String) -> Bool) -> String? {
        let letters = Array(word)
        guard letters.count >= 3, letters.allSatisfy({ $0.isLetter || $0 == "'" }) else { return nil }
        let rest = letters.dropFirst(2)
        guard !rest.isEmpty, rest.allSatisfy({ $0.isLowercase || $0 == "'" }) else { return nil }
        let first = letters[0], second = letters[1]

        // Shift held one letter too long. A lone trailing `s` is a plural acronym (`IDs`).
        if first.isUppercase, second.isUppercase, String(rest) != "s" {
            let fixed = String(first) + String(second).lowercased() + String(rest)
            return isWord(fixed.lowercased()) ? fixed : nil
        }
        // Shift pressed one letter too late, so the first letter was typed twice: `kKing`, or `Kking`
        // when that is not itself a word (`Llama` is).
        guard String(first).lowercased() == String(second).lowercased(), first.isUppercase != second.isUppercase else {
            return nil
        }
        let withoutFirst = String(letters.dropFirst())
        guard isWord(withoutFirst.lowercased()), !isWord(word.lowercased()) else { return nil }
        return withoutFirst.prefix(1).uppercased() + withoutFirst.dropFirst()
    }
}
