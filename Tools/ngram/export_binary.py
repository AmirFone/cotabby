#!/usr/bin/env python3
"""Converts the text next-word table into the compact binary file the app memory-maps.

Layout (little-endian):
  magic "CNW1", u32 vocab_count, u32 context_count, u32 entry_count
  vocab: vocab_count words, each u8 length + UTF-8 bytes (id = position)
  context_hashes: context_count x u64, sorted ascending (FNV-1a over the context's word ids)
  context_totals: context_count x u32
  context_starts: (context_count + 1) x u32 offsets into entries
  entry_words: entry_count x u16 word id
  entry_counts: entry_count x u16. A context whose top count exceeds 65535 has its counts and total
    divided by the same factor, so ratios (all the scorer uses) survive.

The FNV-1a hash here must match `NextWordModel.contextHash` in Swift.

Usage: export_binary.py <model.txt> <out.bin>
"""
import struct, sys

src, out_path = sys.argv[1:3]
rows = []
vocab_index = {}
vocab = []

def word_id(word):
    if word not in vocab_index:
        vocab_index[word] = len(vocab)
        vocab.append(word)
    return vocab_index[word]

for special in ("<s>", "<name>", "<num>"):
    word_id(special)
for line in open(src, encoding="utf-8"):
    if line.startswith("#"):
        continue
    context, total, rest = line.rstrip("\n").split("\t")
    parts = rest.split()
    ids = [word_id(w) for w in context.split()] if context else []
    entries = [(word_id(parts[i]), int(parts[i + 1])) for i in range(0, len(parts), 2)]
    total = int(total)
    top = max(c for _, c in entries)
    if top > 65535:
        factor = top / 65535
        entries = [(w, max(1, round(c / factor))) for w, c in entries]
        total = max(1, round(total / factor))
    rows.append((ids, total, entries))

def fnv(ids):
    h = 0xcbf29ce484222325
    for i in ids:
        for byte in (i & 0xff, i >> 8):
            h ^= byte
            h = (h * 0x100000001b3) & 0xffffffffffffffff
    h ^= len(ids)
    h = (h * 0x100000001b3) & 0xffffffffffffffff
    return h

keyed = sorted(((fnv(ids), total, entries) for ids, total, entries in rows), key=lambda r: r[0])
assert len({k for k, _, _ in keyed}) == len(keyed), "hash collision"
assert len(vocab) < 65536
with open(out_path, "wb") as out:
    entry_count = sum(len(e) for _, _, e in keyed)
    out.write(b"CNW1" + struct.pack("<III", len(vocab), len(keyed), entry_count))
    for w in vocab:
        b = w.encode("utf-8")
        out.write(struct.pack("<B", len(b)) + b)
    out.write(struct.pack(f"<{len(keyed)}Q", *[k for k, _, _ in keyed]))
    out.write(struct.pack(f"<{len(keyed)}I", *[t for _, t, _ in keyed]))
    starts, position = [], 0
    for _, _, entries in keyed:
        starts.append(position)
        position += len(entries)
    starts.append(position)
    out.write(struct.pack(f"<{len(starts)}I", *starts))
    out.write(struct.pack(f"<{entry_count}H", *[w for _, _, e in keyed for w, _ in e]))
    out.write(struct.pack(f"<{entry_count}H", *[c for _, _, e in keyed for _, c in e]))
print(f"vocab={len(vocab)} contexts={len(keyed)} entries={entry_count}", file=sys.stderr)
