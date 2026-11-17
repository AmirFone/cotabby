#!/usr/bin/env python3
"""Checks the writers' passages and merges them into a tuning half and a held-back test half.

Ten writers (see writer-brief.txt) each produce passages-NN.jsonl. Passages that are not plain
text, are the wrong length, or carry no tense label are dropped; a misspelled copy is kept only
when it differs from the text in exactly the listed words. Of the first ten writers, the
even-numbered go to passages-dev.jsonl (for tuning) and the odd-numbered to passages-test.jsonl
(scored once, at the end): the split is by writer, so no writer's style or topic is on both sides.
Writers 10 and up are a second group on other themes, written after tuning was finished; they go
to passages-fresh.jsonl and are only ever scored.

Usage: merge_passages.py <folder with passages-NN.jsonl> <output folder>
"""
import collections, json, re, sys
src, out = sys.argv[1], sys.argv[2]
WORD = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)*|\d+")
kept = {"dev": [], "test": [], "fresh": []}
problems = collections.Counter()
openers = collections.Counter()
import os
for writer in range(100):
    path = f"{src}/passages-{writer:02d}.jsonl"
    if not os.path.exists(path):
        continue
    lines = [l for l in open(path, encoding="utf-8") if l.strip()]
    for line in lines:
        p = json.loads(line)
        text, typed = p.get("text", ""), p.get("typed", "")
        if not text.isascii():
            text = text.replace("’", "'").replace("‘", "'").replace("“", '"').replace("”", '"').replace("—", ", ").replace("–", "-")
            typed = typed.replace("’", "'").replace("‘", "'").replace("“", '"').replace("”", '"').replace("—", ", ").replace("–", "-")
            problems["non-ascii repaired"] += 1
        if not text.isascii() or "\n" in text:
            problems["dropped: not plain text"] += 1; continue
        words = len(WORD.findall(text))
        if not 25 <= words <= 110:
            problems["dropped: length"] += 1; continue
        if p.get("tense") not in ("past", "present", "future", "mixed"):
            problems["dropped: tense label"] += 1; continue
        # The spelling half is kept only when the misspelled copy differs from the text in exactly
        # the listed words; the prediction half does not depend on it.
        a, b = text.split(), typed.split()
        diffs = [(y.strip('.,!?;:"()').lower(), x.strip('.,!?;:"()').lower()) for x, y in zip(a, b) if x != y] if len(a) == len(b) else None
        fixes = [(w.lower(), r.lower()) for w, r in p.get("fixes", []) if isinstance(w, str)] if all(isinstance(f, list) and len(f) == 2 for f in p.get("fixes", [])) else None
        spelling_ok = diffs is not None and fixes is not None and 1 <= len(diffs) <= 8 and sorted(diffs) == sorted(fixes)
        if not spelling_ok:
            problems["spelling copy does not match its list (prediction half kept)"] += 1
        openers[" ".join(text.split()[:2]).lower()] += 1
        record = {"id": p["id"], "register": p.get("register", ""), "tense": p["tense"], "text": text}
        if spelling_ok:
            record["typed"] = typed
            record["fixes"] = [[w, r] for w, r in diffs]
        kept["fresh" if writer >= 10 else "dev" if writer % 2 == 0 else "test"].append(record)
for name, records in kept.items():
    if not records:
        continue
    with open(f"{out}/passages-{name}.jsonl", "w", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps(r, ensure_ascii=True) + "\n")
    tenses = collections.Counter(r["tense"] for r in records)
    n_words = sum(len(WORD.findall(r["text"])) for r in records)
    print(f"{name}: {len(records)} passages, {n_words} words, {sum('typed' in r for r in records)} with a usable misspelled copy, tenses {dict(tenses)}")
print("checks:", dict(problems))
print("most repeated two-word openers:", openers.most_common(6))
