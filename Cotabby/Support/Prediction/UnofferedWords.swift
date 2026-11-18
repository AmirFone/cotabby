import Foundation

/// File overview:
/// Words the word strip never offers. The dictionary and the language model both know slurs,
/// sexual terms, and swearing, and a model ranks whatever is likely: without this list the strip
/// can put one of these first after two innocent letters (`Ra…`). Nothing here stops the writer
/// from typing any word, and the spelling checks still treat these as correctly spelled words;
/// this only decides what Cotabby volunteers.
///
/// A fixed list of whole words, not stems: matching by beginning would also hide ordinary words
/// (`assess`, `rapeseed`, `cockpit`). Kept short on purpose. It is the words a suggestion bar on a
/// phone also leaves out, not a moral filter on vocabulary.
///
/// The same question ("may the strip volunteer this?") has a second kind of no: pieces of words
/// that the tables hold as if they were words (`fragments`). Both are asked here, in the one place
/// every path that builds the list already asks, with or without the language model.
nonisolated enum UnofferedWords {
    static func contains(_ word: String) -> Bool {
        unoffered.contains(word)
    }

    /// One set, so the check stays a single lookup: it runs for every candidate on every key.
    private static let unoffered = words.union(fragments)

    /// Pieces of words that are not words. The n-gram table was counted with a number and the
    /// letters written against it as two tokens, so `5th`, `1st`, `49ers`, `1990s`, `3d`, `5h` and
    /// `10 p.m.` taught it that `th`, `st`, `ers`, `s`, `d`, `h` and `p` are words that follow a
    /// number. After `March 3 ` the strip then offered `th` first, and a pick typed `March 3 th`.
    ///
    /// The endings are words nowhere. Of single letters English has two words, `a` and `I`; every
    /// other one is an initial, a unit or a piece (`vitamin c`, `plan b`), and a pick of one letter
    /// and a space saves nothing over typing it. Two-letter units a writer does put after a space
    /// (`pm`, `km`) are not here.
    private static let fragments = Set(["th", "st", "nd", "rd", "ers"] + "bcdefghjklmnopqrstuvwxyz".map { String($0) })

    private static let words: Set<String> = [
        "rape", "raped", "rapes", "raping", "rapist", "rapists", "molest", "molested", "molester", "molesting",
        "incest", "pedophile", "pedophiles", "paedophile", "paedophiles", "porn", "porno", "pornography",
        "fuck", "fucked", "fucker", "fuckers", "fuckin", "fucking", "fucks", "motherfucker", "motherfuckers",
        "motherfucking", "shit", "shits", "shitty", "shitting", "bullshit", "bitch", "bitches", "bitching",
        "bastard", "bastards", "cunt", "cunts", "cock", "cocks", "dick", "dicks", "pussy", "pussies",
        "slut", "sluts", "slutty", "whore", "whores", "asshole", "assholes", "arsehole", "arseholes",
        "nigger", "niggers", "nigga", "niggas", "faggot", "faggots", "fag", "fags", "dyke", "dykes",
        "retard", "retarded", "retards", "spic", "spics", "chink", "chinks", "kike", "kikes", "wetback",
        "wetbacks", "tranny", "trannies", "coon", "coons", "gook", "gooks", "towelhead", "raghead",
        "cum", "cumshot", "jizz", "blowjob", "blowjobs", "handjob", "dildo", "dildos", "tits", "titties",
        "boobs", "anal", "wank", "wanker", "wankers", "twat", "twats"
    ]
}
