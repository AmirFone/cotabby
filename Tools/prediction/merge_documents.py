#!/usr/bin/env python3
"""Checks the long-document writers' files and merges them into a tuning half and a test half.

Ten writers (20 to 29) each produce long-NN.jsonl: ten documents of 200 to 320 words in two to four
paragraphs. Documents that are not plain ASCII or are far off the length are dropped. Even-numbered
writers go to documents-dev.jsonl, odd-numbered to documents-test.jsonl: the split is by writer, so
no writer's style or subject is on both sides.

Usage: merge_documents.py <folder with long-NN.jsonl> <output folder>
"""
import collections
import json
import os
import re
import sys

src, out = sys.argv[1], sys.argv[2]
WORD = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)*|\d+")
REPAIRS = {"’": "'", "‘": "'", "“": '"', "”": '"', "—": ", ", "–": "-", "…": "..."}
kept = {"dev": [], "test": []}
problems = collections.Counter()
for writer in range(20, 100):
    path = f"{src}/long-{writer:02d}.jsonl"
    if not os.path.exists(path):
        continue
    with open(path, encoding="utf-8") as handle:
        lines = [line for line in handle if line.strip()]
    for line in lines:
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            problems["dropped: not JSON"] += 1
            continue
        text = record.get("text", "")
        for wrong, right in REPAIRS.items():
            if wrong in text:
                text = text.replace(wrong, right)
                problems["non-ASCII punctuation repaired"] += 1
        text = re.sub(r"\n{3,}", "\n\n", text.strip())
        words = len(WORD.findall(text))
        if not text.isascii():
            problems["dropped: not plain text"] += 1
            continue
        if not 150 <= words <= 400:
            problems["dropped: length"] += 1
            continue
        tense = record.get("tense") if record.get("tense") in ("past", "present", "future", "mixed") else "mixed"
        kept["dev" if writer % 2 == 0 else "test"].append(
            {"id": record.get("id", f"{writer}-?"), "register": record.get("register", ""), "tense": tense, "text": text}
        )
for name, records in kept.items():
    with open(f"{out}/documents-{name}.jsonl", "w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=True) + "\n")
    words = sum(len(WORD.findall(r["text"])) for r in records)
    print(f"{name}: {len(records)} documents, {words} words, tenses {dict(collections.Counter(r['tense'] for r in records))}")
for problem, count in problems.items():
    print(f"  {problem}: {count}")
