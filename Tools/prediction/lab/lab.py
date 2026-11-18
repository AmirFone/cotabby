#!/usr/bin/env python3
"""Tries another way of ordering the word strip on typing moments recorded once.

    TYPING_MOMENTS=out.jsonl cotabby-spell --typing texts.jsonl 100000 --lm model.gguf --adaptive
    python3 lab.py ranker.py out.jsonl [more.jsonl ...]

Recording runs the language model (minutes); this reads the record (seconds). A record holds, for
every moment of a typing run, the words the strip chose between and what is known about each: the
app's own score, the model's log-probability, how often this writer typed the word before, after
which words, in how many texts, how long ago, and how common it is in general. See
Tools/cotabby-spell/MomentRecorder.swift for the fields.

A ranker is a Python file with one function:

    def order(m):            # m is a Moment
        return [words]       # best first; only the first five are looked at

`m.c` is the list of candidates (Cand), `m.L` the letters typed, `m.p` those letters, `m.k` the
word before, `m.n` the words the writer typed in earlier texts, `m.T` how often the writer wrote
the last one, two and three words before. The word that was typed (`m.t`) is in the record so the
result can be scored: A RANKER MUST NOT READ m.t OR m.h.

The report compares against the strip as it is (the first word of `m.h`): how often the first
suggestion is right by letters typed, how many moments the ranker turned from wrong to right
(helped) and from right to wrong (harmed), and the same per file, so a gain on one writer that is
a loss on another shows. A candidate whose `s` is None was not considered by the app; a ranker
that orders such a word first is measuring a change to which words are considered, not only to
their order, and the report says how often it did.
"""
import importlib.util
import json
import os
import pickle
import sys
from collections import namedtuple

Cand = namedtuple("Cand", "w s s0 lm own c1 c2 c3 nt last f")
Moment = namedtuple("Moment", "i L t p k n T h c")
LETTERS = 5  # columns 0, 1, 2, 3 and "4 or more"
# The sum of every count in frequency_dictionary_en_82_765.txt: Cand.f / GENERAL_TOTAL is how often
# a word comes up in general English, to compare with how often this writer uses it (own / n).
GENERAL_TOTAL = 541_808_760_578


def load(path):
    """The moments of one record, parsed once and kept next to it."""
    # Plain tuples in the cache, named again on the way out: named tuples pickle with the name of the
    # module that made them, which differs between running this file and importing it.
    cache = path + ".pickle"
    if os.path.exists(cache) and os.path.getmtime(cache) >= os.path.getmtime(path):
        with open(cache, "rb") as handle:
            rows = pickle.load(handle)
    else:
        rows = []
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                row = json.loads(line)
                rows.append((row["i"], row["L"], row["t"], row["p"], row["k"], row["n"], tuple(row["T"]),
                             tuple(row["h"]), tuple(tuple(c) for c in row["c"])))
        with open(cache, "wb") as handle:
            pickle.dump(rows, handle, protocol=pickle.HIGHEST_PROTOCOL)
    return [Moment(*row[:8], tuple(Cand(*c) for c in row[8])) for row in rows]


def baseline(m):
    """The strip as it is: the app's score, the writer's word counts not mixed in."""
    return [c.w for c in sorted((c for c in m.c if c.s is not None), key=lambda c: (-c.s, c.w))[:5]]


class Tally:
    def __init__(self):
        self.moments = [0] * LETTERS
        self.right = [0] * LETTERS
        self.was_right = [0] * LETTERS
        self.listed = 0
        self.helped = 0
        self.harmed = 0
        self.unconsidered_first = 0
        self.early = [0, 0, 0, 0]  # moments, right, was right, in the first third of the texts
        self.late = [0, 0, 0, 0]

    def add(self, m, words, last_text):
        column = min(m.L, LETTERS - 1)
        first = words[0] if words else None
        before = m.h[0] if m.h else None
        self.moments[column] += 1
        self.right[column] += first == m.t
        self.was_right[column] += before == m.t
        self.listed += m.t in words[:5]
        self.helped += first == m.t and before != m.t
        self.harmed += first != m.t and before == m.t
        part = self.early if m.i * 3 < last_text + 1 else self.late if m.i * 3 >= 2 * (last_text + 1) else None
        if part is not None:
            part[0] += 1
            part[1] += first == m.t
            part[2] += before == m.t

    def merge(self, other):
        for name in ("moments", "right", "was_right", "early", "late"):
            setattr(self, name, [a + b for a, b in zip(getattr(self, name), getattr(other, name))])
        for name in ("listed", "helped", "harmed", "unconsidered_first"):
            setattr(self, name, getattr(self, name) + getattr(other, name))

    def summary(self):
        total = max(sum(self.moments), 1)
        with_letters = max(total - self.moments[0], 1)
        return {
            "moments": sum(self.moments),
            "first_right": [round(100 * r / max(n, 1), 1) for r, n in zip(self.right, self.moments)],
            "was": [round(100 * r / max(n, 1), 1) for r, n in zip(self.was_right, self.moments)],
            "all": round(100 * sum(self.right) / total, 2),
            "all_was": round(100 * sum(self.was_right) / total, 2),
            "typed": round(100 * sum(self.right[1:]) / with_letters, 2),
            "typed_was": round(100 * sum(self.was_right[1:]) / with_letters, 2),
            "listed": round(100 * self.listed / total, 2),
            "helped": self.helped,
            "harmed": self.harmed,
            "early": round(100 * (self.early[1] - self.early[2]) / max(self.early[0], 1), 2),
            "late": round(100 * (self.late[1] - self.late[2]) / max(self.late[0], 1), 2),
            "unconsidered_first": self.unconsidered_first,
        }


def evaluate(order, paths):
    """{name: summary} for every record and for all of them together under "ALL"."""
    results, everything = {}, Tally()
    for path in paths:
        moments = load(path)
        last_text = max((m.i for m in moments), default=0)
        tally = Tally()
        for m in moments:
            words = list(order(m))[:5]
            tally.add(m, words, last_text)
            if words:
                considered = {c.w for c in m.c if c.s is not None}
                tally.unconsidered_first += words[0] not in considered
        results[os.path.basename(path).replace(".jsonl", "")] = tally.summary()
        everything.merge(tally)
    results["ALL"] = everything.summary()
    return results


def report(results):
    print(f"{'record':<22}{'moments':>8}  first suggestion right by letters typed (0 1 2 3 4+)      all      "
          f"1+ letters   helped harmed   early  late")
    for name, r in results.items():
        cells = " ".join(f"{now:5.1f}" for now in r["first_right"])
        print(f"{name:<22}{r['moments']:>8}  {cells}   {r['all']:6.2f} ({r['all'] - r['all_was']:+5.2f})  "
              f"{r['typed']:6.2f} ({r['typed'] - r['typed_was']:+5.2f})  {r['helped']:>6} {r['harmed']:>6}  "
              f"{r['early']:+6.2f} {r['late']:+5.2f}")
    files = [r for name, r in results.items() if name != "ALL"]
    if len(files) > 1:
        gains = sorted(r["typed"] - r["typed_was"] for r in files)
        print(f"per record, change with 1+ letters: worst {gains[0]:+.2f}, median {gains[len(gains) // 2]:+.2f}, "
              f"best {gains[-1]:+.2f}; records that got worse: {sum(g < 0 for g in gains)} of {len(gains)}")
    if results["ALL"]["unconsidered_first"]:
        print(f"first word was one the app does not consider today: {results['ALL']['unconsidered_first']} moments")
    print("(in brackets: change against the strip as it is; early and late: the change in the first and the "
          "last third of each record's texts)")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    spec = importlib.util.spec_from_file_location("ranker", sys.argv[1])
    ranker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ranker)
    results = evaluate(ranker.order, sys.argv[2:])
    report(results)
    if os.environ.get("LAB_JSON"):
        with open(os.environ["LAB_JSON"], "w", encoding="utf-8") as handle:
            json.dump(results, handle)


if __name__ == "__main__":
    main()
