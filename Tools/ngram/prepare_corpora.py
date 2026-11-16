#!/usr/bin/env python3
"""Turns the raw corpora into what build_large_model.py reads: chunk files of one sentence per line,
plus one held-out file per source (every 50th sentence by a stable hash, the same rule
build_model.py uses, so a Tatoeba sentence held out there is held out here too).

Sources, any number, each as kind:name:path[:max_lines]
  tatoeba  the Tatoeba export (`eng_sentences.tsv.bz2`; the sentence is the third column)
  leipzig  a Leipzig Corpora `*-sentences.txt` file (`number<TAB>sentence`)
  gzlines  a gzip file of one sentence per line; may be a truncated download

Lines in capitals only (subtitle captions) are skipped: they would teach that every word is a name.

Usage: prepare_corpora.py <out-dir> <source> [<source> ...]     Env: CHUNKS (32)
"""
import bz2, gzip, os, sys, zlib

out_dir, sources = sys.argv[1], sys.argv[2:]
CHUNKS = int(os.environ.get("CHUNKS", 32))
os.makedirs(out_dir, exist_ok=True)
chunks = [open(f"{out_dir}/chunk-{i:02d}.txt", "w", encoding="utf-8") for i in range(CHUNKS)]
written = 0


def sentences(kind, path, limit):
    if kind == "tatoeba":
        for line in bz2.open(path, "rt", encoding="utf-8"):
            if line.count("\t") >= 2:
                yield line.rstrip("\n").split("\t")[2]
    elif kind == "leipzig":
        for line in open(path, encoding="utf-8", errors="replace"):
            parts = line.rstrip("\n").split("\t", 1)
            if len(parts) == 2:
                yield parts[1]
    elif kind == "gzlines":
        count = 0
        try:
            for line in gzip.open(path, "rt", encoding="utf-8", errors="replace"):
                yield line.rstrip("\n")
                count += 1
                if limit and count >= limit:
                    return
        except (EOFError, zlib.error):
            return  # a truncated download ends mid-stream; everything before that is usable
    else:
        raise SystemExit(f"unknown source kind: {kind}")


for source in sources:
    kind, name, path, *rest = source.split(":")
    limit = int(rest[0]) if rest else 0
    kept = held = 0
    with open(f"{out_dir}/heldout-{name}.txt", "w", encoding="utf-8") as heldout:
        for sentence in sentences(kind, path, limit):
            if not sentence or (sentence.isupper() and len(sentence) > 3):
                continue
            if zlib.crc32(sentence.encode()) % 50 == 0:
                heldout.write(sentence + "\n")
                held += 1
            else:
                chunks[written % CHUNKS].write(sentence + "\n")
                written += 1
                kept += 1
    print(f"{name}: {kept} sentences, {held} held out", file=sys.stderr)
for chunk in chunks:
    chunk.close()
