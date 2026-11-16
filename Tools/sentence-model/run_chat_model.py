#!/usr/bin/env python3
"""Has a chat model rewrite each test sentence with its spelling fixed, and scores the result.

Per kind of sentence: how often the output is exactly the intended sentence, how often the error
was fixed at all (intended word present), how often a correct sentence came back changed, and the
time per sentence. Output file: <kind><TAB><intended><TAB><typed><TAB><model output><TAB><ms>.

Usage: run_chat_model.py <set.tsv> <mlx-model> <out.tsv> [limit-per-kind]
"""
import collections, sys, time
from mlx_lm import generate, load

set_path, model_name, out_path = sys.argv[1:4]
limit = int(sys.argv[4]) if len(sys.argv) > 4 else 10 ** 9
model, tokenizer = load(model_name)
SYSTEM = ("You fix spelling. Rewrite the sentence with every misspelled word and every wrongly used word "
          "(like their/there, form/from) corrected. Keep all other words, names, punctuation and capitalization "
          "exactly as they are. If nothing is wrong, repeat the sentence unchanged. Reply with the sentence only.")
SHOTS = [("I beleive their going to the libary tomorow.", "I believe they're going to the library tomorrow."),
         ("Dr. Okonkwo reviewed the Terraform plan on Friday.", "Dr. Okonkwo reviewed the Terraform plan on Friday."),
         ("She dose not no were the meeting is.", "She does not know where the meeting is.")]


def rewrite(sentence):
    messages = [{"role": "system", "content": SYSTEM}]
    for typed, fixed in SHOTS:
        messages += [{"role": "user", "content": typed}, {"role": "assistant", "content": fixed}]
    messages.append({"role": "user", "content": sentence})
    try:
        prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True, enable_thinking=False)
    except TypeError:
        prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
    started = time.perf_counter()
    text = generate(model, tokenizer, prompt=prompt, max_tokens=len(tokenizer.encode(sentence)) + 24, verbose=False)
    return text.strip().split("\n")[0].strip(), (time.perf_counter() - started) * 1000


rows = [line.rstrip("\n").split("\t") for line in open(set_path, encoding="utf-8")]
taken, stats, times = collections.Counter(), collections.defaultdict(collections.Counter), []
rewrite("Warm up the modle.")
with open(out_path, "w", encoding="utf-8") as out:
    for kind, intended, typed in rows:
        if taken[kind] >= limit:
            continue
        taken[kind] += 1
        output, ms = rewrite(typed)
        times.append(ms)
        out.write("\t".join((kind, intended, typed, output, f"{ms:.0f}")) + "\n")
        stats[kind]["n"] += 1
        stats[kind]["exact"] += output == intended
        stats[kind]["unchanged"] += output == typed
times.sort()
print(f"{model_name}: median {times[len(times) // 2]:.0f} ms, 90% within {times[int(len(times) * 0.9)]:.0f} ms per sentence")
for kind, s in stats.items():
    if kind.endswith("clean"):
        print(f"  {kind:11s} {s['n']:4d}  changed a correct sentence {100 * (s['n'] - s['exact']) / s['n']:5.1f}%")
    else:
        print(f"  {kind:11s} {s['n']:4d}  exactly right {100 * s['exact'] / s['n']:5.1f}%   left as typed {100 * s['unchanged'] / s['n']:5.1f}%   "
              f"changed to something else {100 * (s['n'] - s['exact'] - s['unchanged']) / s['n']:5.1f}%")
