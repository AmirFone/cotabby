#!/usr/bin/env python3
"""Runs the app's own sentence pass (cotabby-spell --proofread) over the sentence test set and
writes <out>-auto.tsv (fixes applied without asking) and <out>-suggested.tsv (suggestions accepted).
Usage: run_current_pipeline.py <set.tsv> <cotabby-spell> <out-prefix> [extra cli args...]"""
import re, subprocess, sys

set_path, cli, out_prefix = sys.argv[1:4]
extra = sys.argv[4:]
rows = [line.rstrip("\n").split("\t") for line in open(set_path, encoding="utf-8")]


def unescape(text):
    return text.replace("\\'", "'").replace('\\"', '"')


outputs = {}
for at in range(0, len(rows), 100):
    batch = rows[at:at + 100]
    args = [cli] + extra
    for _, _, typed in batch:
        args += ["--proofread", typed]
    text = subprocess.run(args, capture_output=True, text=True).stdout
    found = re.findall(r'^(auto-fixed|suggested)\s+"(.*)"(?:\s+\([\d.]+ ms\))?$', text, flags=re.M)
    auto = [unescape(value) for name, value in found if name == "auto-fixed"]
    suggested = [unescape(value) for name, value in found if name == "suggested"]
    assert len(auto) == len(batch) == len(suggested), (len(auto), len(suggested), len(batch))
    for row, a, s in zip(batch, auto, suggested):
        outputs[tuple(row)] = (a, s)
for name, pick in (("auto", 0), ("suggested", 1)):
    with open(f"{out_prefix}-{name}.tsv", "w", encoding="utf-8") as out:
        for row in rows:
            out.write("\t".join(row + [outputs[tuple(row)][pick]]) + "\n")
