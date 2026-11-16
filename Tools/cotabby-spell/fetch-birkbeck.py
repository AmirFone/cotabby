#!/usr/bin/env python3
"""Downloads the Birkbeck spelling error corpora (Roger Mitton, freely available for research) and
writes dev/test halves for `cotabby-spell --accuracy`: non-word typos (the typo is not a dictionary
word and the intended word is) in <name>-{dev,test}.txt, and real-word errors (the typo is itself a
dictionary word), which need sentence context, in <name>-realword-{dev,test}.txt.

Tune on the *-dev.txt halves; report on *-test.txt only. The split is by CRC32 of the typo, so it is
stable across runs. Note: missp.dat is noisy (many "intended" words are not what the typo reads as),
so holbrook/wikipedia/aspell are the trustworthy sets for wrong-auto-fix rates.

Usage: fetch-birkbeck.py <out-dir>   (run from the repo root)
"""
import re, sys, urllib.request, zlib, os

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
dictionary = set(line.split()[0] for line in open("Cotabby/Resources/frequency_dictionary_en_82_765.txt"))
for name in ["holbrook-missp", "wikipedia", "aspell", "missp"]:
    raw = urllib.request.urlopen(f"https://www.dcs.bbk.ac.uk/~roger/{name}.dat").read().decode("latin-1")
    pairs, real_word_pairs, intended = set(), set(), None
    for line in raw.splitlines():
        fields = line.split()
        if not fields:
            continue
        if fields[0].startswith("$"):
            intended = fields[0][1:]
            continue
        typo = fields[0]
        if not (intended and re.fullmatch(r"[a-z]+", intended) and re.fullmatch(r"[a-z]+", typo)
                and typo != intended and intended in dictionary):
            continue
        if typo not in dictionary and len(typo) >= 3:
            pairs.add((intended, typo))
        elif typo in dictionary and len(typo) >= 2:
            # A real word typed for another (`wether` for whether): the wrong-word model's data.
            real_word_pairs.add((intended, typo))
    for kind, found in (("", pairs), ("-realword", real_word_pairs)):
        for split, parity in (("dev", 0), ("test", 1)):
            with open(f"{out}/{name}{kind}-{split}.txt", "w") as f:
                f.write(f"# Birkbeck {name} ({split} half, {'real-word' if kind else 'non-word'} typos only). <intended><TAB><typo>\n")
                for intended, typo in sorted(found):
                    if zlib.crc32(typo.encode()) % 2 == parity:
                        f.write(f"{intended}\t{typo}\n")
    print(name, len(pairs), "real-word", len(real_word_pairs))
