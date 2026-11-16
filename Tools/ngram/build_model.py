#!/usr/bin/env python3
"""Builds Cotabby's next-word model from the Tatoeba English sentences (CC BY 2.0 FR).

Counts n-grams up to order 4 (three words of context), maps person names to <name> and numbers to
<num> (kept as context, never suggested), prunes rare contexts, and keeps only the most likely next
words per context. Output is a small text table the app loads into memory:

    <context words, space separated, may be empty>\t<context total>\t<word> <count> <word> <count> ...

Every 50th sentence (by stable hash) is held out and written to a separate file for evaluation.

Usage: build_model.py <eng_sentences.tsv.bz2> <dictionary.txt> <out_model.txt> <out_heldout.txt>
"""
import bz2, collections, os, re, sys, zlib

MAX_ORDER = int(os.environ.get("NGRAM_ORDER", 4))
K_SCALE = float(os.environ.get("NGRAM_K_SCALE", 1))
MIN_TOTAL = int(os.environ.get("NGRAM_MIN_TOTAL", 3))
TOP_K = {n: int(k * K_SCALE) for n, k in {0: 400, 1: 40, 2: 24, 3: 16, 4: 12}.items()}  # next words kept per context
MIN_CONTEXT_TOTAL = {n: MIN_TOTAL + (1 if n >= 3 else 0) for n in range(1, 5)}  # rarer contexts are dropped
MIN_NEXT_COUNT = 2
TOKEN = re.compile(r"[A-Za-z]+(?:['’][A-Za-z]+)*|\d+")

src, dictionary_path, out_model, out_heldout = sys.argv[1:5]
dictionary = {}
for line in open(dictionary_path, encoding="utf-8"):
    word, count = line.split()[:2]
    dictionary[word] = int(count)

sentences = [l.rstrip("\n").split("\t")[2] for l in bz2.open(src, "rt", encoding="utf-8") if l.count("\t") >= 2]
train, heldout = [], []
for s in sentences:
    (heldout if zlib.crc32(s.encode()) % 50 == 0 else train).append(s)

# Person names: tokens that are capitalized in >90% of their mid-sentence uses.
caps, total = collections.Counter(), collections.Counter()
for s in train:
    for i, tok in enumerate(TOKEN.findall(s)):
        if i == 0 or tok.isdigit():
            continue
        low = tok.lower()
        total[low] += 1
        if tok[0].isupper():
            caps[low] += 1
names = {w for w, n in total.items() if n >= 3 and caps[w] / n > 0.9 and w != "i"}

def tokens(sentence):
    out = []
    for tok in TOKEN.findall(sentence):
        low = tok.lower().replace("’", "'")
        if tok.isdigit():
            out.append("<num>")
        elif low in names:
            out.append("<name>")
        else:
            out.append(low)
    return out

counts = [collections.defaultdict(collections.Counter) for _ in range(MAX_ORDER)]
for s in train:
    seq = ["<s>"] + tokens(s)
    for i in range(1, len(seq)):
        word = seq[i]
        for n in range(0, MAX_ORDER):
            if i - n < 0:
                break
            context = tuple(seq[i - n:i])
            counts[n][context][word] += 1

with open(out_model, "w", encoding="utf-8") as out:
    out.write(f"# names={len(names)} train_sentences={len(train)}\n")
    for n in range(MAX_ORDER):
        kept = 0
        for context, nexts in counts[n].items():
            context_total = sum(nexts.values())
            if n > 0 and context_total < MIN_CONTEXT_TOTAL[n]:
                continue
            best = [(w, c) for w, c in nexts.most_common() if not w.startswith("<") and c >= MIN_NEXT_COUNT][:TOP_K[n]]
            if not best:
                continue
            kept += 1
            out.write(" ".join(context) + "\t" + str(context_total) + "\t" + " ".join(f"{w} {c}" for w, c in best) + "\n")
        print(f"order {n + 1}: {kept} contexts", file=sys.stderr)

with open(out_heldout, "w", encoding="utf-8") as out:
    for s in heldout:
        out.write(s + "\n")
print(f"names={len(names)} train={len(train)} heldout={len(heldout)}", file=sys.stderr)
