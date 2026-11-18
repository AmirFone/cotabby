import Foundation

/// File overview:
/// Undoes Shift-key timing slips, which are not spelling mistakes and need no ranking: Shift held
/// one letter too long (`THe` → The, `HEllo` → Hello) or pressed one letter too late (`kKing` →
/// King, `tThe` → The). The spell checker either accepts these or guesses at unrelated words
/// (`THe` → Thee), so they are recognized by shape before it is asked.
///
/// The shape alone cannot tell a slip from a word that is written that way: `OAuth`, `GHz` and
/// `OSes` are two capitals and then lowercase, exactly like `THe`. So a fix needs two things. Its
/// letters must be a dictionary word, which keeps `MHz`, `IDs`, `PCs`, `iPhone` and `McDonald`
/// untouched. And the caller, which owns the spell checker and the term lists, must say how the
/// recased word is written: `The` as it stands, `Iphone` as iPhone, `Ghz` and `Oauth` not at all,
/// so `GHz` and `OAuth` stay as typed. Changing a word that was typed correctly is the worst thing
/// this rule can do, far worse than missing a slip, and that is why it gives up whenever the result
/// is not plainly a word.
nonisolated enum CaseSlip {
    /// - Parameters:
    ///   - isWord: whether a lowercased word is in the dictionary.
    ///   - acceptedSpelling: the way the recased word is written: itself when it is fine as it
    ///     stands (`The`), the same letters in their known capitals when it has them (`Iphone` →
    ///     iPhone), nil when it is not an accepted word in any casing (`Ghz`). The default accepts
    ///     the word as it stands, for callers that only want the shape rule.
    /// - Returns: the fix, or nil when there is none or the word is already written that way.
    static func fix(
        for word: String,
        isWord: (String) -> Bool,
        acceptedSpelling: (String) -> String? = { $0 }
    ) -> String? {
        let letters = Array(word)
        guard letters.count >= 3, letters.allSatisfy({ $0.isLetter || $0 == "'" }) else { return nil }
        let rest = letters.dropFirst(2)
        guard !rest.isEmpty, rest.allSatisfy({ $0.isLowercase || $0 == "'" }) else { return nil }
        let first = letters[0], second = letters[1]

        let recased: String
        if first.isUppercase, second.isUppercase, String(rest) != "s" {
            // Shift held one letter too long. A lone trailing `s` is a plural acronym (`IDs`).
            recased = String(first) + String(second).lowercased() + String(rest)
            guard isWord(recased.lowercased()) else { return nil }
        } else {
            // Shift pressed one letter too late, so the first letter was typed twice: `kKing`, or
            // `Kking` when that is not itself a word (`Llama` is).
            guard String(first).lowercased() == String(second).lowercased(), first.isUppercase != second.isUppercase else {
                return nil
            }
            let withoutFirst = String(letters.dropFirst())
            guard isWord(withoutFirst.lowercased()), !isWord(word.lowercased()) else { return nil }
            recased = withoutFirst.prefix(1).uppercased() + withoutFirst.dropFirst()
        }
        guard let fixed = acceptedSpelling(recased), fixed != word else { return nil }
        return fixed
    }
}
