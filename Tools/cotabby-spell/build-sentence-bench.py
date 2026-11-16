#!/usr/bin/env python3
"""Builds the in-sentence benchmarks for cotabby-spell from held-out Tatoeba sentences
(Tools/ngram/build_model.py writes them) and the Birkbeck splits (fetch-birkbeck.py):

  context-{dev,test}.txt       a sentence prefix ending in a Birkbeck typo      → --accuracy
  realword-{dev,test}.txt      a prefix ending in a swapped confusable word    → --accuracy
  clean-{dev,test}.txt         the same prefixes with the correct word         → --clean
  sent-swapped/clean-*.txt     whole sentences with/without one swapped word   → --sentence-bench

Confusable groups are read from RealWordErrorDetector.swift, so new groups are covered automatically.
Usage: build-sentence-bench.py <heldout.txt> <bench-dir>   (run from the repo root)
"""
import collections, random, re, sys

heldout, out = sys.argv[1:3]
sentences = [s.strip() for s in open(heldout, encoding="utf-8") if s.strip()]
half = len(sentences) // 2
source = open("Cotabby/Support/Spelling/RealWordErrorDetector.swift").read()
body = source.split("confusableGroups")[1].split("groupsByWord")[0]
alternatives = collections.defaultdict(set)
for group in (re.findall(r'"([^"]+)"', g) for g in re.findall(r'\[("[^\]]+")\]', body)):
    for word in group:
        alternatives[word].update(other for other in group if other != word)

def write(path, rows):
    with open(f"{out}/{path}", "w") as f:
        f.writelines(row + "\n" for row in rows)

for split, pool in (("dev", sentences[:half]), ("test", sentences[half:])):
    rng = random.Random(split)
    typos = collections.defaultdict(list)
    for name in ["holbrook-missp", "wikipedia", "aspell", "missp"]:
        for line in open(f"{out}/{name}-{split}.txt"):
            if not line.startswith("#"):
                intended, typo = line.rstrip("\n").split("\t")
                typos[intended].append(typo)
    context, realword, clean, swapped, whole = [], [], [], [], []
    for sentence in pool:
        words = sentence.split(" ")
        spots = [i for i, w in enumerate(words) if i > 0 and re.fullmatch(r"[a-z]+", w) and w in typos]
        if spots and len(context) < 2000:
            i = rng.choice(spots)
            context.append(f"{words[i]}\t{' '.join(words[:i] + [rng.choice(typos[words[i]])])} ")
        spots = [i for i, w in enumerate(words) if i > 0 and w in alternatives]
        if spots and len(realword) < 3000:
            i = rng.choice(spots)
            realword.append(f"{words[i]}\t{' '.join(words[:i] + [rng.choice(sorted(alternatives[words[i]]))])} ")
            clean.append(" ".join(words[:i + 1]) + " ")
        spots = [i for i, w in enumerate(words[:-1]) if i > 0 and w in alternatives]
        if spots and len(words) >= 4 and sentence[-1] in ".!?" and len(whole) < 1500:
            i = rng.choice(spots)
            swapped.append(f"{words[i]}\t{' '.join(words[:i] + [rng.choice(sorted(alternatives[words[i]]))] + words[i + 1:])}")
            whole.append(sentence)
    write(f"context-{split}.txt", context)
    write(f"realword-{split}.txt", realword)
    write(f"clean-{split}.txt", clean)
    write(f"sent-swapped-{split}.txt", swapped)
    write(f"sent-clean-{split}.txt", whole)
    print(split, len(context), len(realword), len(whole))
