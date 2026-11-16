#!/usr/bin/env python3
"""Scores corrected sentences word by word. Input: <kind><TAB><intended><TAB><typed><TAB><output>[...].
The last word of each sentence is left out: the app handles it as it is typed, before the sentence pass.
Usage: score_sentences.py <label> <file.tsv> [--show kind]"""
import collections, sys
label, path = sys.argv[1:3]
show = sys.argv[sys.argv.index("--show") + 1] if "--show" in sys.argv else None
stats = collections.defaultdict(collections.Counter)
for line in open(path, encoding="utf-8"):
    kind, intended, typed, output = line.rstrip("\n").split("\t")[:4]
    want, got_in, got = intended.split(), typed.split(), output.split()
    s = stats[kind]
    s["sentences"] += 1
    s["reshaped"] += len(got) != len(want)
    bad = False
    for i in range(len(want) - 1):
        out_word = got[i] if len(got) == len(want) else None
        if got_in[i] != want[i]:
            s["errors"] += 1
            s["fixed"] += out_word == want[i]
            s["untouched"] += out_word == got_in[i]
        else:
            s["correct"] += 1
            if out_word != want[i]:
                s["broken"] += 1; bad = True
    s["harmed"] += bad
    if show == kind and (bad or output != intended):
        print(f"    {typed}\n      -> {output}")
print(label)
for kind, s in stats.items():
    line = f"  {kind:11s} {s['sentences']:4d} sentences"
    if s["errors"]:
        line += f"  errors fixed {100 * s['fixed'] / s['errors']:5.1f}%  left alone {100 * s['untouched'] / s['errors']:5.1f}%  made different {100 * (s['errors'] - s['fixed'] - s['untouched']) / s['errors']:5.1f}%  |"
    line += f"  correct words changed {1000 * s['broken'] / max(s['correct'], 1):5.2f} per 1,000  sentences harmed {100 * s['harmed'] / s['sentences']:5.2f}%"
    print(line)
