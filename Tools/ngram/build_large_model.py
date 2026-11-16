#!/usr/bin/env python3
"""Builds the next-word table from several corpora at once, in parallel.

Same output format and rules as build_model.py (n-grams up to order 4, person names -> <name>,
numbers -> <num>, rare contexts pruned, top next words kept per context), for corpora too large to
count in one Python dictionary. Three differences:

- Input is a folder of plain-text chunk files, one sentence per line (see prepare_corpora.py, which
  also holds out every 50th sentence per source for evaluation).
- Counting is map-reduce over worker processes: each worker counts one chunk and files its counts
  by context into shards; each shard is then summed and pruned on its own.
- The vocabulary is capped (VOCAB, default 60000 most frequent words), because the binary format
  stores word ids in 16 bits. A context containing any other word is dropped; the app backs off to
  a shorter context there, as it does for any context it has not seen.

Usage: build_large_model.py <chunks-dir> <out_model.txt>
Env: NGRAM_ORDER (4), NGRAM_MIN_TOTAL (context total needed, default 8), NGRAM_MIN_NEXT (2),
     NGRAM_K_SCALE (1), VOCAB (60000), WORKERS (16)
"""
import collections, glob, os, pickle, re, sys, tempfile
from multiprocessing import Pool

MAX_ORDER = int(os.environ.get("NGRAM_ORDER", 4))
K_SCALE = float(os.environ.get("NGRAM_K_SCALE", 1))
MIN_TOTAL = int(os.environ.get("NGRAM_MIN_TOTAL", 8))
MIN_NEXT_COUNT = int(os.environ.get("NGRAM_MIN_NEXT", 2))
VOCAB = int(os.environ.get("VOCAB", 60000))
WORKERS = int(os.environ.get("WORKERS", 16))
SHARDS = 32
TOP_K = {n: int(k * K_SCALE) for n, k in {0: 400, 1: 40, 2: 24, 3: 16}.items()}
MIN_CONTEXT_TOTAL = {0: 0, 1: MIN_TOTAL, 2: MIN_TOTAL, 3: MIN_TOTAL + 2}
TOKEN = re.compile(r"[A-Za-z]+(?:['’][A-Za-z]+)*|\d+")
SPECIAL = ["<s>", "<name>", "<num>"]


def count_words(path):
    """Pass 1 for one chunk: how often each word occurs, and how often it is capitalized mid-sentence."""
    total, capitalized, first = collections.Counter(), collections.Counter(), collections.Counter()
    for line in open(path, encoding="utf-8"):
        for i, token in enumerate(TOKEN.findall(line)):
            if token.isdigit():
                continue
            low = token.lower().replace("’", "'")
            if i == 0:
                first[low] += 1
            else:
                total[low] += 1
                if token[0].isupper():
                    capitalized[low] += 1
    return total, capitalized, first


def count_ngrams(args):
    """Pass 2 for one chunk: n-gram counts keyed by packed word ids, written out by context shard."""
    path, ids, names, out_dir = args
    name_id, num_id = ids["<name>"], ids["<num>"]
    counts = collections.Counter()
    for line in open(path, encoding="utf-8"):
        seq = [ids["<s>"]]
        for token in TOKEN.findall(line):
            if token.isdigit():
                seq.append(num_id)
                continue
            low = token.lower().replace("’", "'")
            seq.append(name_id if low in names else ids.get(low, -1))
        for i in range(1, len(seq)):
            word = seq[i]
            if word < 0:
                continue
            context = 0
            for n in range(MAX_ORDER):
                if n > 0:
                    previous = seq[i - n] if i - n >= 0 else -1
                    if previous < 0:
                        break
                    # The context is packed nearest word first; the reducer unpacks it in order.
                    context |= (previous + 1) << (16 * (n - 1))
                counts[(context << 18) | (word << 2) | n] += 1
    shards = [dict() for _ in range(SHARDS)]
    for key, count in counts.items():
        shards[(key >> 18) % SHARDS][key] = count
    name = os.path.basename(path)
    for shard, table in enumerate(shards):
        with open(f"{out_dir}/{name}.{shard}.pkl", "wb") as f:
            pickle.dump(table, f, protocol=pickle.HIGHEST_PROTOCOL)
    return len(counts)


def reduce_shard(args):
    """Sums one shard across chunks, prunes it, and returns its lines of the text table."""
    shard, out_dir, vocab = args
    counts = collections.Counter()
    for path in glob.glob(f"{out_dir}/*.{shard}.pkl"):
        with open(path, "rb") as f:
            counts.update(pickle.load(f))
    by_context = collections.defaultdict(list)
    for key, count in counts.items():
        by_context[(key >> 18, key & 3)].append((count, (key >> 2) & 0xFFFF))
    lines, kept = [], collections.Counter()
    for (packed, n), nexts in by_context.items():
        total = sum(count for count, _ in nexts)
        if total < MIN_CONTEXT_TOTAL[n]:
            continue
        nexts.sort(reverse=True)
        best = [(vocab[w], c) for c, w in nexts if c >= MIN_NEXT_COUNT and not vocab[w].startswith("<")][:TOP_K[n]]
        if not best:
            continue
        # Unpack farthest word first, so the context reads left to right.
        words = [vocab[((packed >> (16 * k)) & 0xFFFF) - 1] for k in range(n - 1, -1, -1)]
        lines.append(" ".join(words) + "\t" + str(total) + "\t" + " ".join(f"{w} {c}" for w, c in best) + "\n")
        kept[n] += 1
    return lines, kept


def main():
    chunks_dir, out_model = sys.argv[1:3]
    chunks = sorted(glob.glob(f"{chunks_dir}/chunk-*.txt"))
    with Pool(WORKERS) as pool:
        total, capitalized, first = collections.Counter(), collections.Counter(), collections.Counter()
        for t, c, f in pool.imap_unordered(count_words, chunks):
            total.update(t); capitalized.update(c); first.update(f)
        # Person and place names: capitalized in more than 90% of their mid-sentence uses.
        names = {w for w, n in total.items() if n >= 3 and capitalized[w] / n > 0.9 and w != "i"}
        frequency = total + first
        common = [w for w, _ in frequency.most_common() if w not in names][:VOCAB]
        vocab = SPECIAL + common
        ids = {w: i for i, w in enumerate(vocab)}
        print(f"names={len(names)} vocabulary={len(vocab)} tokens={sum(frequency.values())}", file=sys.stderr)
        with tempfile.TemporaryDirectory(dir=os.path.dirname(os.path.abspath(out_model))) as work:
            distinct = sum(pool.imap_unordered(count_ngrams, [(c, ids, names, work) for c in chunks]))
            print(f"n-gram entries before merging: {distinct}", file=sys.stderr)
            kept = collections.Counter()
            with open(out_model, "w", encoding="utf-8") as out:
                out.write(f"# names={len(names)} vocabulary={len(vocab)} chunks={len(chunks)}\n")
                for lines, shard_kept in pool.imap_unordered(reduce_shard, [(s, work, vocab) for s in range(SHARDS)]):
                    out.writelines(lines)
                    kept.update(shard_kept)
    for n in range(MAX_ORDER):
        print(f"order {n + 1}: {kept[n]} contexts", file=sys.stderr)


if __name__ == "__main__":
    main()
