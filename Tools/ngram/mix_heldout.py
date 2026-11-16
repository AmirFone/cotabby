#!/usr/bin/env python3
"""Mixes the per-source held-out files from prepare_corpora.py into one shuffled file: the sentences
the spelling models are trained and scored on (Tools/autofix/build_dataset.py). Sentences of 20 to
160 characters only, so a typo always has some context and no line is a whole paragraph.

Usage: mix_heldout.py <chunks-dir> <out.txt> name:count [name:count ...]
"""
import random, sys

chunks_dir, out_path, parts = sys.argv[1], sys.argv[2], sys.argv[3:]
random.seed(11)
mixed = []
for part in parts:
    name, count = part.split(":")
    lines = [l.strip() for l in open(f"{chunks_dir}/heldout-{name}.txt", encoding="utf-8") if 20 <= len(l.strip()) <= 160]
    random.shuffle(lines)
    mixed += lines[:int(count)]
random.shuffle(mixed)
with open(out_path, "w", encoding="utf-8") as f:
    f.write("\n".join(mixed) + "\n")
print(f"{len(mixed)} sentences", file=sys.stderr)
