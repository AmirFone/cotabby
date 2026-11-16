#!/usr/bin/env python3
"""Scores every wrong-word training row with a small encoder model, as extra feature columns.

Reads the shards `cotabby-spell --wrong-features` was run on (`<dir>/wrongword-*.??` and their
`.csv`), and writes `<shard>.csv.<tag>.npy` (float32, one line per CSV row) plus `<dir>/<tag>.names`.

kind = mlm: the word is masked and the model, reading both sides, says how likely the typed word and
  each alternative are there. Columns: typed, candidate, delta, best rival's delta (natural log).
kind = rtd: an ELECTRA-style discriminator says, per word, how likely it was swapped in. Columns: the
  typed word's logit in the sentence as written, the alternative's logit when put in its place, delta.

Only the sentence view (words on both sides) is scored; caret-view rows get NaN.

Usage: score_word_judge.py <wrong-dir> <hf-model> <mlm|rtd> <tag> [shard-glob]
"""
import collections, glob, os, sys, time
import numpy as np
import torch
from transformers import AutoModelForMaskedLM, AutoModelForPreTraining, AutoTokenizer

wrong_dir, model_name, kind, tag = sys.argv[1:5]
pattern = sys.argv[5] if len(sys.argv) > 5 else "wrongword-*.??"
TOKEN_BUDGET = int(os.environ.get("TOKEN_BUDGET", 6000))
device = "mps"
tokenizer = AutoTokenizer.from_pretrained(model_name)
if kind == "mlm":
    model = AutoModelForMaskedLM.from_pretrained(model_name)
else:
    model = AutoModelForPreTraining.from_pretrained(model_name)
model = model.to(device).eval()
parameters = sum(p.numel() for p in model.parameters())
print(f"{model_name}: {parameters / 1e6:.1f}M parameters", flush=True)

# A tokenizer that marks word starts with a leading space encodes " cat" and "cat" differently.
SPACE_MATTERS = tokenizer.encode(" cat", add_special_tokens=False) != tokenizer.encode("cat", add_special_tokens=False)
CLS = [tokenizer.cls_token_id] if tokenizer.cls_token_id is not None else []
SEP = [tokenizer.sep_token_id] if tokenizer.sep_token_id is not None else []
MASK, PAD = tokenizer.mask_token_id, tokenizer.pad_token_id or 0
word_cache = {}


def word_spans(text):
    """Same words as the app's `WordToken.tokens`: runs of letters with inner apostrophes."""
    spans, start, n = [], None, len(text)
    for i, ch in enumerate(text):
        inner = ch in "'’" and start is not None and i + 1 < n and text[i + 1].isalpha()
        if ch.isalpha() or inner:
            if start is None:
                start = i
        elif start is not None:
            spans.append((start, i))
            start = None
    if start is not None:
        spans.append((start, n))
    return spans


def word_ids(word, after_space):
    key = (word, after_space)
    if key not in word_cache:
        word_cache[key] = tokenizer.encode((" " if after_space and SPACE_MATTERS else "") + word, add_special_tokens=False)
    return word_cache[key]


def cased_like(original, word):
    if len(original) > 1 and original.isupper():
        return word.upper()
    return word[0].upper() + word[1:] if original[0].isupper() else word


def run(inputs):
    """Yields (index, logits for that input, on the device) for token-id lists, batched by length."""
    order = sorted(range(len(inputs)), key=lambda i: len(inputs[i]))
    at = 0
    while at < len(order):
        longest = len(inputs[order[at]])
        size = 1
        while at + size < len(order) and (size + 1) * len(inputs[order[at + size]]) <= TOKEN_BUDGET:
            size += 1
        batch = order[at:at + size]
        longest = len(inputs[batch[-1]])
        ids = torch.full((len(batch), longest), PAD, dtype=torch.long)
        attention = torch.zeros((len(batch), longest), dtype=torch.long)
        for row, index in enumerate(batch):
            ids[row, :len(inputs[index])] = torch.tensor(inputs[index])
            attention[row, :len(inputs[index])] = 1
        with torch.no_grad():
            logits = model(input_ids=ids.to(device), attention_mask=attention.to(device)).logits
        yield batch, logits
        at += size


def score_shard(shard):
    lines = [line for line in open(shard, encoding="utf-8").read().split("\n") if line]
    sentences = []
    for line in lines:
        fields = line.split("\t")
        sentences.append(fields[1] + fields[2] + fields[3] if len(fields) == 4 else None)
    rows = []  # (sentence, word, view, typed, candidate)
    with open(shard + ".csv", encoding="utf-8") as f:
        f.readline()
        for line in f:
            parts = line.split(",", 7)
            rows.append((int(parts[0]), int(parts[1]), int(parts[4]), parts[5], parts[6]))
    places = collections.OrderedDict()  # (sentence, word) -> candidates in row order
    for sentence, word, view, typed, candidate in rows:
        if view == 0:
            places.setdefault((sentence, word), []).append(candidate)

    encoded, mismatches = {}, 0
    requests, targets = [], []  # token-id inputs; per input, what to read from it
    for (sentence, word), candidates in places.items():
        text = sentences[sentence]
        if sentence not in encoded:
            enc = tokenizer(text, add_special_tokens=False, return_offsets_mapping=True)
            encoded[sentence] = (enc["input_ids"], enc["offset_mapping"], word_spans(text))
        ids, offsets, spans = encoded[sentence]
        start, end = spans[word]
        original = text[start:end]
        left = [t for t, (a, b) in zip(ids, offsets) if b <= start]
        right = [t for t, (a, b) in zip(ids, offsets) if a >= end]
        after_space = start > 0 and text[start - 1] == " "
        options = [original] + [cased_like(original, c) for c in candidates]
        if kind == "mlm":
            by_length = collections.defaultdict(list)
            for slot, option in enumerate(options):
                by_length[len(word_ids(option, after_space))].append(slot)
            for length, slots in by_length.items():
                requests.append(CLS + left + [MASK] * length + right + SEP)
                targets.append((sentence, word, len(CLS) + len(left), [(slot, word_ids(options[slot], after_space)) for slot in slots]))
        else:
            for slot, option in enumerate(options):
                piece = word_ids(option, after_space)
                requests.append(CLS + left + piece + right + SEP)
                targets.append((sentence, word, len(CLS) + len(left), [(slot, piece)]))

    scores = collections.defaultdict(dict)  # (sentence, word) -> slot -> score
    for batch, logits in run(requests):
        if kind == "mlm":
            positions, owners = [], []
            for row, index in enumerate(batch):
                _, _, at, wanted = targets[index]
                longest = max(len(piece) for _, piece in wanted)
                for offset in range(longest):
                    positions.append((row, at + offset))
            picked = torch.log_softmax(logits[[p[0] for p in positions], [p[1] for p in positions]].float(), dim=-1).cpu().numpy()
            cursor = 0
            for row, index in enumerate(batch):
                sentence, word, at, wanted = targets[index]
                longest = max(len(piece) for _, piece in wanted)
                for slot, piece in wanted:
                    scores[(sentence, word)][slot] = float(sum(picked[cursor + i, token] for i, token in enumerate(piece)))
                cursor += longest
        else:
            values = logits.float().cpu().numpy()
            for row, index in enumerate(batch):
                sentence, word, at, wanted = targets[index]
                slot, piece = wanted[0]
                scores[(sentence, word)][slot] = float(values[row, at:at + max(len(piece), 1)].max())

    width = 4 if kind == "mlm" else 3
    out = np.full((len(rows), width), np.nan, dtype=np.float32)
    seen = collections.Counter()
    for index, (sentence, word, view, typed, candidate) in enumerate(rows):
        if view != 0:
            continue
        slot = seen[(sentence, word)] + 1
        seen[(sentence, word)] += 1
        found = scores[(sentence, word)]
        typed_score, candidate_score = found[0], found[slot]
        if kind == "mlm":
            rivals = [found[other] - typed_score for other in found if other not in (0, slot)]
            out[index] = (typed_score, candidate_score, candidate_score - typed_score, max(rivals) if rivals else -30.0)
        else:
            out[index] = (typed_score, candidate_score, typed_score - candidate_score)
        text = sentences[sentence]
        start, end = encoded[sentence][2][word]
        mismatches += text[start:end].lower() != typed
    np.save(f"{shard}.csv.{tag}.npy", out)
    return len(rows), len(requests), mismatches


names = ["Typed", "Candidate", "Delta", "RivalDelta"] if kind == "mlm" else ["Typed", "Candidate", "Delta"]
with open(f"{wrong_dir}/{tag}.names", "w") as f:
    f.write("\n".join(tag + name for name in names))
started, total_rows, total_requests, total_mismatches = time.time(), 0, 0, 0
for shard in sorted(glob.glob(f"{wrong_dir}/{pattern}")):
    if shard.endswith((".csv", ".rule", ".npy")):
        continue
    rows, requests, mismatches = score_shard(shard)
    total_rows += rows; total_requests += requests; total_mismatches += mismatches
    print(f"{os.path.basename(shard)}: {rows} rows, {requests} passes, {time.time() - started:.0f}s", flush=True)
print(f"done: {total_rows} rows, {total_requests} passes, {total_mismatches} word mismatches, {time.time() - started:.0f}s")
