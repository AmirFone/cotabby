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
nonisolated enum UnofferedWords {
    static func contains(_ word: String) -> Bool {
        words.contains(word)
    }

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
