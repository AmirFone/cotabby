#!/usr/bin/env python3
"""Measures a next-word model on held-out sentences (reference implementation of the app's scoring).

Reports next-word top-1 / top-5 accuracy (before typing any letter of the word) and keystroke
savings: a simulated writer types letter by letter and picks the word with one key as soon as it is
in the list of 5. Savings = 1 - keys pressed / characters in the text (letters + spaces).

Usage: evaluate.py <model.txt> <dictionary.txt> <heldout.txt> [sentences=3000] [backoff=0.4]
"""
import re, sys, random

model_path, dictionary_path, heldout_path = sys.argv[1:4]
limit = int(sys.argv[4]) if len(sys.argv) > 4 else 3000
alpha = float(sys.argv[5]) if len(sys.argv) > 5 else 0.4
TOKEN = re.compile(r"[A-Za-z]+(?:['’][A-Za-z]+)*|\d+")
LIST = 5

table = {}
for line in open(model_path, encoding="utf-8"):
    if line.startswith("#"):
        continue
    context, total, rest = line.rstrip("\n").split("\t")
    parts = rest.split()
    table[tuple(context.split()) if context else ()] = (int(total), [(parts[i], int(parts[i + 1])) for i in range(0, len(parts), 2)])

MAX_CONTEXT = max(len(k) for k in table)
unigram = sorted(((w, int(c)) for w, c in (l.split()[:2] for l in open(dictionary_path, encoding="utf-8"))), key=lambda x: -x[1])
by_letter = {}
for w, c in unigram:
    by_letter.setdefault(w[0], []).append((w, c))

def predict(history, prefix):
    scores = {}
    for n in range(MAX_CONTEXT, -1, -1):
        if n > len(history):
            continue
        entry = table.get(tuple(history[len(history) - n:]))
        if not entry:
            continue
        total, nexts = entry
        weight = alpha ** (MAX_CONTEXT - n)
        for w, c in nexts:
            if w.startswith(prefix):
                s = weight * c / total
                if s > scores.get(w, 0):
                    scores[w] = s
    ranked = sorted(scores, key=lambda w: -scores[w])[:LIST]
    if len(ranked) < LIST and prefix:
        for w, _ in by_letter.get(prefix[0], []):
            if len(ranked) >= LIST:
                break
            if w.startswith(prefix) and w not in ranked and w != prefix:
                ranked.append(w)
    return ranked

random.seed(7)
sentences = [s.strip() for s in open(heldout_path, encoding="utf-8") if s.strip()]
sentences = random.sample(sentences, min(limit, len(sentences)))
top1 = top5 = predictions = 0
keys = chars = 0
def context_token(raw, position):
    """The runtime rule: a capitalized word mid-sentence (not I) is a name; digits are a number."""
    if raw.isdigit():
        return "<num>"
    if position > 0 and raw[0].isupper() and raw != "I" and not raw.startswith("I'"):
        return "<name>"
    return raw.lower().replace("’", "'")

for s in sentences:
    raws = TOKEN.findall(s)
    words = [t.lower().replace("’", "'") for t in raws]
    history = ["<s>"]
    for position, word in enumerate(words):
        is_name = context_token(raws[position], position) == "<name>"
        chars += len(word) + 1
        if not word.isdigit() and not is_name:
            first = predict(history, "")
            predictions += 1
            top1 += bool(first) and first[0] == word
            top5 += word in first
        typed = ""
        for i in range(len(word) + 1):
            if word in predict(history, typed):
                keys += 1
                break
            if i == len(word):
                keys += 1  # the space
                break
            typed += word[i]
            keys += 1
        history.append(context_token(raws[position], position))
print(f"sentences={len(sentences)} next-word top1={top1 / predictions:.1%} top5={top5 / predictions:.1%} keystroke savings={1 - keys / chars:.1%}")
