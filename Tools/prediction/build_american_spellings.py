#!/usr/bin/env python3
"""Builds Cotabby/Resources/american_spellings_en.txt: British spellings with their American form.

On a Mac set to the United States, a misspelling should be fixed to the American spelling and the
word strip should not offer `travelling` next to `traveling`. The app needs to know which words are
the same word spelled two ways; this script finds them.

A pair is written when all of these hold:
- one of the spelling rules below turns the British word into the American one (or the pair is on
  the short list of irregular ones);
- both are words the app knows (the frequency dictionary or prediction_words_en.txt);
- in the corpora the context table is built from, which are mostly American, the American form is
  used at least as often as the British one. That is what keeps `dialogue`, `aesthetic` and
  `glamour` out (American writers keep those), and with the length limits it keeps out look-alikes
  that are different words (`four`/`for`, `filled`/`filed`).

The result is small enough to read; read it after every rebuild.

Usage:
  python3 -I Tools/prediction/build_american_spellings.py <folder with chunk-*.txt> \
      Cotabby/Resources/american_spellings_en.txt
"""
import collections
import glob
import multiprocessing
import os
import re
import sys

WORD = re.compile(r"[A-Za-z]+")
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RESOURCES = os.path.join(REPO, "Cotabby/Resources")

# Verbs ending in an unstressed vowel + l double the l in British spelling only (travelled,
# cancelling). A stressed one doubles it everywhere (controlled, filled), so the rule is limited to
# bases of five letters or more plus the three short ones that follow it.
SHORT_L_BASES = {"fuel", "dial", "duel"}

IRREGULAR = {
    "grey": "gray", "greys": "grays", "tyre": "tire", "tyres": "tires", "plough": "plow", "ploughed": "plowed",
    "ploughing": "plowing", "programme": "program", "programmes": "programs", "jewellery": "jewelry",
    "aluminium": "aluminum", "moustache": "mustache", "pyjamas": "pajamas", "sceptical": "skeptical",
    "sceptic": "skeptic", "sceptics": "skeptics", "scepticism": "skepticism", "cosy": "cozy",
    "aeroplane": "airplane", "aeroplanes": "airplanes", "mould": "mold", "moulds": "molds", "moulded": "molded",
    "moulding": "molding", "smoulder": "smolder", "smouldering": "smoldering", "sulphur": "sulfur",
    "sulphate": "sulfate", "speciality": "specialty", "specialities": "specialties", "artefact": "artifact",
    "artefacts": "artifacts", "enrol": "enroll", "enrolment": "enrollment", "fulfil": "fulfill",
    "fulfilment": "fulfillment", "instalment": "installment", "instalments": "installments",
    "skilful": "skillful", "skilfully": "skillfully", "wilful": "willful", "wilfully": "willfully",
    "defence": "defense", "defences": "defenses", "offence": "offense", "offences": "offenses",
    "licence": "license", "licences": "licenses", "pretence": "pretense", "manoeuvre": "maneuver",
    "manoeuvres": "maneuvers", "manoeuvred": "maneuvered", "manoeuvring": "maneuvering", "mum": "mom",
    "mums": "moms", "woollen": "woolen", "marvellous": "marvelous", "counsellor": "counselor",
    "counsellors": "counselors", "traveller": "traveler", "travellers": "travelers", "jeweller": "jeweler",
    "jewellers": "jewelers", "cheque": "check", "cheques": "checks", "kerb": "curb", "doughnut": "donut",
    "doughnuts": "donuts", "omelette": "omelet", "omelettes": "omelets", "liquorice": "licorice",
    "chilli": "chili", "chillies": "chilies", "tonne": "ton", "tonnes": "tons", "storey": "story",
    "fibre": "fiber", "metre": "meter", "litre": "liter", "sabre": "saber", "mitre": "miter",
}
# Listed above for completeness but different enough in meaning or use to leave alone.
NOT_PAIRS = {"cheque", "cheques", "kerb", "tonne", "tonnes", "storey", "doughnut", "doughnuts", "mum", "mums"}
# Pairs the rules produce that are two different words, a name, or a spelling Americans keep for
# one meaning (`daemon` in computing). Found by reading the output; read it again after a rebuild.
FALSE_PAIRS = {
    "aether", "boeing", "chartres", "chimaera", "compositae", "daemon", "daemons", "forgoes", "prised", "prises",
    "rachael", "scoured", "scouring", "soever", "soloed", "stelae", "timbre", "timbres",
}


def candidates(word):
    """American spellings the rules give for a British word (most words give none)."""
    found = set()
    if len(word) >= 6 or word in ("odour", "odours"):
        match = re.fullmatch(r"(.+)our(s|ed|ing|er|ers|ite|ites|able|ably|ful|fully|less|ly|hood|hoods|ist|ists|ism)?", word)
        if match:
            found.add(match.group(1) + "or" + (match.group(2) or ""))
    if len(word) >= 6:
        match = re.fullmatch(r"(.+)is(e|es|ed|ing|er|ers|ation|ations|able)", word)
        if match:
            found.add(match.group(1) + "iz" + match.group(2))
        match = re.fullmatch(r"(.+)ys(e|es|ed|ing|er|ers)", word)
        if match:
            found.add(match.group(1) + "yz" + match.group(2))
        match = re.fullmatch(r"(.+[tb])re(s|d)?", word)
        if match:
            found.add(match.group(1) + "er" + {"": "", "s": "s", "d": "ed"}[match.group(2) or ""])
        match = re.fullmatch(r"(.+)ogue(s|d)?", word)
        if match:
            found.add(match.group(1) + "og" + (match.group(2) or ""))
        for old in ("ae", "oe"):
            if old in word:
                found.add(word.replace(old, "e", 1))
    match = re.fullmatch(r"(.+[aeiou]l)l(ed|ing|er|ers)", word)
    if match and (len(match.group(1)) >= 5 or match.group(1) in SHORT_L_BASES):
        found.add(match.group(1) + match.group(2))
    return found


def count_chunk(path):
    counts = collections.Counter()
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            counts.update(word for word in WORD.findall(line) if word.islower())
    return counts


def main():
    chunks_folder, output = sys.argv[1], sys.argv[2]
    counts = collections.Counter()
    with multiprocessing.Pool(min(32, os.cpu_count() or 4)) as pool:
        for part in pool.imap_unordered(count_chunk, sorted(glob.glob(f"{chunks_folder}/chunk-*.txt"))):
            counts.update(part)
    known = set()
    for name in ("frequency_dictionary_en_82_765.txt", "prediction_words_en.txt"):
        with open(os.path.join(RESOURCES, name), encoding="utf-8") as handle:
            known.update(line.split(" ")[0] for line in handle)

    pairs = {}
    for british in sorted(known - FALSE_PAIRS):
        options = set(candidates(british))
        if british in IRREGULAR and british not in NOT_PAIRS:
            options.add(IRREGULAR[british])
        for american in options:
            if american == british or american not in known:
                continue
            # The verb's base must be a word for the l rule (`travel`), or `tilled` would pair with `tiled`.
            match = re.fullmatch(r"(.+[aeiou]l)l(ed|ing|er|ers)", british)
            if match and american == match.group(1) + match.group(2) and match.group(1) not in known:
                continue
            if counts[american] >= max(counts[british], 5):
                pairs[british] = american
    with open(output, "w", encoding="utf-8") as handle:
        for british, american in sorted(pairs.items()):
            handle.write(f"{british} {american}\n")
    print(f"{len(pairs)} pairs written")


if __name__ == "__main__":
    main()
