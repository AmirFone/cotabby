#!/usr/bin/env python3
"""Scores model answers with the same rules as the app's `SentenceModelGate`: a changed word is typed
in place when the model's probability clears 0.9 (0.95 when the typed word is in the dictionary),
offered for review from 0.6, and ignored when the word's punctuation changed or the answer has a
different number of words. "Known word" here is the bundled frequency dictionary; the app also
counts the writer's own vocabulary.

Usage: app_gate_report.py <run_model or SentenceModelEvalTests output.tsv> [dictionary.txt]
"""
import collections, math, sys

path = sys.argv[1]
dictionary_path = sys.argv[2] if len(sys.argv) > 2 else "Cotabby/Resources/frequency_dictionary_en_82_765.txt"
known = {line.split()[0] for line in open(dictionary_path, encoding="utf-8")}
APPLY, APPLY_KNOWN, SUGGEST = 0.9, 0.95, 0.6


def core(word):
    start, end = 0, len(word)
    while start < end and not word[start].isalnum():
        start += 1
    while end > start and not word[end - 1].isalnum():
        end -= 1
    return start, end


def gate(given, got, probabilities):
    """Returns (sentence with fixes typed in place, sentence with suggestions accepted too)."""
    applied, suggested = list(given), list(given)
    if len(got) != len(given) or len(probabilities) != len(got):
        return applied, suggested
    for i, (old, new, p) in enumerate(zip(given, got, probabilities)):
        if old == new:
            continue
        (a, b), (c, d) = core(old), core(new)
        if a == b or c == d or old[a:b] == new[c:d] or old[:a] != new[:c] or old[b:] != new[d:]:
            continue
        bar = APPLY_KNOWN if old[a:b].lower() in known else APPLY
        if p >= bar:
            applied[i] = suggested[i] = new
        elif p >= SUGGEST:
            suggested[i] = new
    return applied, suggested


stats = {"typed in place": collections.defaultdict(collections.Counter), "plus suggestions accepted": collections.defaultdict(collections.Counter)}
for line in open(path, encoding="utf-8"):
    kind, intended, typed, output, ms, confidence = (line.rstrip("\n").split("\t") + [""] * 3)[:6]
    want, given = intended.split(), typed.split()
    if len(want) != len(given):
        continue
    applied, suggested = gate(given, output.split(), [math.exp(float(c)) for c in confidence.split()])
    for label, out in (("typed in place", applied), ("plus suggestions accepted", suggested)):
        s, bad = stats[label][kind], False
        s["sentences"] += 1
        for w, g, o in zip(want, given, out):
            if g != w:
                s["errors"] += 1; s["fixed"] += o == w; s["other"] += o not in (w, g)
            elif o != w:
                s["broken"] += 1; bad = True
            s["correct"] += g == w
        s["harmed"] += bad
print(path)
for label, by_kind in stats.items():
    parts = [f"{kind} fixed {100 * by_kind[kind]['fixed'] / max(by_kind[kind]['errors'], 1):4.1f}% (wrong {100 * by_kind[kind]['other'] / max(by_kind[kind]['errors'], 1):3.1f}%)"
             for kind in ("misspelled", "wrongword", "hard")]
    correct = sum(s["correct"] for s in by_kind.values()); broken = sum(s["broken"] for s in by_kind.values())
    clean = by_kind["clean"]
    print(f"  {label:26s} " + "  ".join(parts) + f"  | correct words changed {1000 * broken / max(correct, 1):4.2f}/1,000, "
          f"clean sentences harmed {100 * clean['harmed'] / max(clean['sentences'], 1):4.2f}%, names harmed {by_kind['hard-clean']['harmed']}/{by_kind['hard-clean']['sentences']}")
