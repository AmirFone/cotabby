#!/usr/bin/env python3
"""Scores a fine-tuned corrector's output with a confidence gate on each changed word.

A changed word is kept only if the model's confidence in it clears a bar; an output whose word count
differs from the typed sentence is dropped whole. Sweeps the bar and prints, per bar: errors fixed
by kind, errors changed to the wrong thing, correct words changed, and correct sentences harmed.
The last word of each sentence is scored too (the model sees the whole sentence).

Usage: gate_report.py <run_model output.tsv> [--show bar]
"""
import collections, math, sys

path = sys.argv[1]
show = float(sys.argv[sys.argv.index("--show") + 1]) if "--show" in sys.argv else None
rows = []
for line in open(path, encoding="utf-8"):
    kind, intended, typed, output, ms, confidence, margin = (line.rstrip("\n").split("\t") + ["", ""])[:7]
    rows.append((kind, intended.split(), typed.split(), output.split(),
                 [float(c) for c in confidence.split()], [float(m) for m in margin.split()]))


def gated(given, got, confidence, bar):
    if len(got) != len(given) or len(confidence) != len(got):
        return list(given)
    return [new if new == old or math.exp(c) >= bar else old for old, new, c in zip(given, got, confidence)]


print(path)
reshaped = sum(len(got) != len(given) for _, _, given, got, _, _ in rows)
print(f"  outputs with a different word count (dropped): {reshaped} of {len(rows)}")
for bar in (0.0, 0.5, 0.7, 0.8, 0.9, 0.95, 0.98, 0.99):
    stats = collections.defaultdict(collections.Counter)
    for kind, want, given, got, confidence, margin in rows:
        if len(given) != len(want):
            continue  # an earlier stage merged or split words; not comparable word for word
        out = gated(given, got, confidence, bar)
        s, bad = stats[kind], False
        s["sentences"] += 1
        for i in range(len(want)):
            if given[i] != want[i]:
                s["errors"] += 1; s["fixed"] += out[i] == want[i]; s["other"] += out[i] not in (want[i], given[i])
            else:
                s["correct"] += 1
                if out[i] != want[i]:
                    s["broken"] += 1; bad = True
        s["harmed"] += bad
        if show == bar and bad:
            changed = [f"{a}->{b}" for a, b in zip(given, out) if a != b and a in want]
            print("      " + " ".join(given)[:110] + "  ::  " + ", ".join(changed))
    parts = []
    for kind in ("misspelled", "wrongword", "hard"):
        s = stats[kind]
        parts.append(f"{kind} fixed {100 * s['fixed'] / max(s['errors'], 1):4.1f}% (wrong {100 * s['other'] / max(s['errors'], 1):3.1f}%)")
    correct = sum(s["correct"] for s in stats.values()); broken = sum(s["broken"] for s in stats.values())
    clean, names = stats["clean"], stats["hard-clean"]
    print(f"  keep changes the model is >= {bar:4.2f} sure of: " + "  ".join(parts)
          + f"  | correct words changed {1000 * broken / max(correct, 1):4.2f}/1,000, clean sentences harmed "
          f"{100 * clean['harmed'] / max(clean['sentences'], 1):4.2f}%, names harmed {names['harmed']}/{names['sentences']}")
