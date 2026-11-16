#!/usr/bin/env python3
"""Runs a spelling fine-tune over the sentence test set and records how sure it was of every word.

The model gets the typed sentence as the user turn and writes the corrected sentence. For every
output word two numbers are kept:
  confidence  the lowest probability the model gave any piece of that word as it wrote it
  margin      log P(the word it wrote) - log P(the word as typed), both read in place (natural log)
A gate (gate_report.py) then decides which changed words to keep.

Output lines: <kind><TAB><intended><TAB><typed><TAB><output><TAB><ms><TAB><confidences><TAB><margins>
With FAST=1 the sentence is written by `correct_fast` (same output, about a quarter of the time) and
the last column holds the number of model passes the sentence took instead of the margins.

Usage: [FAST=1] run_model.py <set.tsv> <model> <adapter-dir|-> <out.tsv> [limit-per-kind]
"""
import collections, os, sys, time
import mlx.core as mx
from mlx_lm import load
from mlx_lm.generate import generate_step
from mlx_lm.models.cache import make_prompt_cache, trim_prompt_cache

set_path, model_name, adapter, out_path = sys.argv[1:5]
limit = int(sys.argv[5]) if len(sys.argv) > 5 else 10 ** 9
model, tokenizer = load(model_name, adapter_path=None if adapter == "-" else adapter)
END = {tokenizer.eos_token_id} | {tokenizer.convert_tokens_to_ids(t) for t in ("<|im_end|>", "<|endoftext|>")}


def by_word(tokens, values):
    """Groups per-token values by the whitespace-separated word each token belongs to."""
    words, text = collections.defaultdict(list), ""
    for token, value in zip(tokens, values):
        piece = tokenizer.decode([token])
        starts_word = not text or text[-1].isspace() or piece[:1].isspace()
        if piece.strip():
            words[len(text.split()) if starts_word else len(text.split()) - 1].append(value)
        text += piece
    return words, text


def correct(sentence):
    # The fine-tune learned to open its answer with an empty thinking block; handing that block over
    # in the prompt saves writing it one piece at a time.
    prompt = tokenizer.apply_chat_template([{"role": "user", "content": sentence}], add_generation_prompt=True, enable_thinking=False)
    started = time.perf_counter()
    tokens, logps = [], []
    budget = len(tokenizer.encode(sentence)) + 16
    for token, logprobs in generate_step(mx.array(prompt), model, max_tokens=budget):
        token = int(token)
        if token in END:
            break
        tokens.append(token)
        logps.append(float(logprobs[token]))
    ms = (time.perf_counter() - started) * 1000
    written, text = by_word(tokens, logps)
    # The same sentence as typed, scored in place of the answer in one pass.
    typed_tokens = tokenizer.encode(sentence, add_special_tokens=False)
    logits = model(mx.array([prompt + typed_tokens]))[0, len(prompt) - 1:-1]
    typed_logps = logits - mx.logsumexp(logits, axis=-1, keepdims=True)
    typed_values = [float(typed_logps[i, t]) for i, t in enumerate(typed_tokens)]
    copied, _ = by_word(typed_tokens, typed_values)
    count = len(text.split())
    confidence = [min(written[i]) if written[i] else 0.0 for i in range(count)]
    margin = [sum(written[i]) - sum(copied[i]) if i in copied else 99.0 for i in range(count)]
    return text.strip(), ms, confidence, margin


def correct_fast(sentence):
    """Same answer as `correct`, written far faster: guess that the answer is the sentence as typed,
    check the whole guess in one pass, and only write piece by piece where the model disagrees.

    A plain run writes one piece per pass, so a 25-piece sentence costs 25 passes. Here a correct
    sentence costs one pass, and a sentence with one error costs that pass, a few single steps for
    the corrected word, and one more pass for the rest. The guess is only ever accepted where it
    equals the model's own first choice, so the output is exactly what the plain run would write.
    """
    prompt = tokenizer.apply_chat_template([{"role": "user", "content": sentence}], add_generation_prompt=True, enable_thinking=False)
    typed_words = sentence.split()
    started = time.perf_counter()
    cache = make_prompt_cache(model)
    out, conf, passes = [], [], 0

    def forward(tokens):
        nonlocal passes
        passes += 1
        # 32-bit before the softmax: the model's own 16-bit numbers round probabilities too coarsely
        # for a confidence bar near 1.
        logits = model(mx.array([tokens]), cache=cache)[0].astype(mx.float32)
        logps = logits - mx.logsumexp(logits, axis=-1, keepdims=True)
        return logps, mx.argmax(logps, axis=-1).tolist()

    def check(guess, logps, best, first_row):
        """Accepts the guessed pieces while they are the model's first choice. `first_row` is the row
        that predicts guess[0]. Returns the row that predicts the piece after the last accepted one."""
        taken = 0
        while taken < len(guess) and best[first_row + taken] == guess[taken]:
            out.append(guess[taken]); conf.append(float(logps[first_row + taken, guess[taken]]))
            taken += 1
        if taken < len(guess):
            trim_prompt_cache(cache, len(guess) - taken)
        return logps[first_row + taken], best[first_row + taken]

    guess = tokenizer.encode(sentence, add_special_tokens=False)
    logps, best = forward(prompt + guess)
    row, choice = check(guess, logps, best, len(prompt) - 1)
    budget = len(guess) + 16
    while choice not in END and len(out) < budget:
        out.append(choice); conf.append(float(row[choice]))
        logps, best = forward([choice])
        row, choice = logps[0], best[0]
        # When the model is about to start a new word, guess the rest of the sentence as typed.
        if choice not in END and tokenizer.decode([choice])[:1].isspace():
            rest = typed_words[len(tokenizer.decode(out).split()):]
            guess = tokenizer.encode(" " + " ".join(rest), add_special_tokens=False) if rest else []
            if guess and guess[0] == choice:
                out.append(choice); conf.append(float(row[choice]))
                logps, best = forward(guess)
                row, choice = check(guess[1:], logps, best, 0)
    ms = (time.perf_counter() - started) * 1000
    written, text = by_word(out, conf)
    count = len(text.split())
    confidence = [min(written[i]) if written[i] else 0.0 for i in range(count)]
    return text.strip(), ms, confidence, [float(passes)] * count


FAST = bool(os.environ.get("FAST"))
rows = [line.rstrip("\n").split("\t") for line in open(set_path, encoding="utf-8")]
taken, times = collections.Counter(), []
if FAST:
    correct = correct_fast
correct("Warm up the modle.")
with open(out_path, "w", encoding="utf-8") as out:
    for kind, intended, typed in rows:
        if taken[kind] >= limit:
            continue
        taken[kind] += 1
        output, ms, confidence, margin = correct(typed)
        times.append(ms)
        out.write("\t".join((kind, intended, typed, output.replace("\n", " "), f"{ms:.0f}",
                             " ".join(f"{c:.3f}" for c in confidence), " ".join(f"{m:.2f}" for m in margin))) + "\n")
times.sort()
print(f"{model_name} + {adapter}: median {times[len(times) // 2]:.0f} ms, 90% within {times[int(len(times) * 0.9)]:.0f} ms per sentence")
