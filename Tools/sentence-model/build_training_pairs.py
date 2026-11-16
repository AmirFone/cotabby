#!/usr/bin/env python3
"""Builds (typed sentence -> correct sentence) pairs for fine-tuning a small model on spelling.

Sentences come from the training part of the corpora (the held-out 2% the benchmarks use is never
read). About a third stay untouched, so the model learns that the usual right answer is to copy.
The rest get one to three errors of the kinds a dyslexic writer makes:
  - a recorded misspelling of that word (Birkbeck, dev half only; the test half scores the result)
  - a real word in place of another (recorded real-word slips, and the app's confusable groups)
  - a made-up misspelling (swapped, dropped, doubled, neighboring-key and sound-alike letters), which
    is the only way to cover names and technical words no typo list has
Word count never changes, so a correction can be checked word against word.

Usage: build_training_pairs.py <chunks-dir> <birkbeck-dir> <repo-root> <out-dir> <sentences>
"""
import collections, glob, json, os, random, re, sys

chunks_dir, birkbeck, repo, out_dir, count = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
rng = random.Random(17)
os.makedirs(out_dir, exist_ok=True)


def table(names):
    found = collections.defaultdict(list)
    for name in names:
        for line in open(f"{birkbeck}/{name}-dev.txt", encoding="utf-8"):
            if not line.startswith("#") and "\t" in line:
                intended, typo = line.rstrip("\n").split("\t")[:2]
                found[intended.lower()].append(typo)
    return found


misspellings = table(["holbrook-missp", "wikipedia", "aspell", "missp"])
real_words = table(["holbrook-missp-realword", "wikipedia-realword", "aspell-realword", "missp-realword"])
groups_body = open(f"{repo}/Cotabby/Support/Spelling/RealWordErrorDetector.swift").read().split("confusableGroups")[1].split("groupsByWord")[0]
for group in (re.findall(r'"([^"]+)"', g) for g in re.findall(r'\[("[^\]]+")\]', groups_body)):
    for word in group:
        real_words[word] += [other for other in group if other != word] * 3

ROWS = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
NEAR = collections.defaultdict(str)
for r, row in enumerate(ROWS):
    for c, key in enumerate(row):
        NEAR[key] += row[max(c - 1, 0):c] + row[c + 1:c + 2]
        for other in (r - 1, r + 1):
            if 0 <= other < len(ROWS):
                NEAR[key] += ROWS[other][max(c - 1, 0):c + 1]
SOUNDS = [("ie", "ei"), ("ei", "ie"), ("ph", "f"), ("f", "ph"), ("tion", "shun"), ("sion", "tion"), ("c", "k"), ("k", "c"),
          ("c", "s"), ("s", "c"), ("ough", "uff"), ("ight", "ite"), ("a", "e"), ("e", "a"), ("e", "i"), ("i", "e"),
          ("o", "u"), ("u", "o"), ("y", "i"), ("i", "y"), ("ea", "ee"), ("ee", "ea"), ("ou", "ow"), ("er", "or"),
          ("or", "er"), ("ar", "er"), ("le", "el"), ("el", "le"), ("ck", "k"), ("qu", "kw"), ("x", "ks"), ("wh", "w"),
          ("kn", "n"), ("wr", "r"), ("mb", "m"), ("gh", ""), ("b", "d"), ("d", "b"), ("p", "q"), ("m", "n"), ("n", "m"),
          ("ai", "a"), ("au", "o"), ("ch", "sh"), ("sch", "sh"), ("z", "s"), ("s", "z"), ("j", "g"), ("g", "j"),
          ("ance", "ence"), ("ence", "ance"), ("able", "ible"), ("ible", "able"), ("ary", "ery"), ("y", "ie")]


def slip(word):
    """One made-up slip in a lowercase word; the first letter is rarely touched, as in real typing."""
    letters = list(word)
    start = 0 if rng.random() < 0.08 else 1
    kind = rng.random()
    if kind < 0.22 and len(letters) - start >= 2:
        i = rng.randrange(start, len(letters) - 1)
        letters[i], letters[i + 1] = letters[i + 1], letters[i]
    elif kind < 0.45:
        doubled = [i for i in range(1, len(letters)) if letters[i] == letters[i - 1]]
        i = rng.choice(doubled) if doubled and rng.random() < 0.6 else rng.randrange(start, len(letters))
        del letters[i]
    elif kind < 0.57:
        i = rng.randrange(start, len(letters))
        letters.insert(i, letters[i])
    elif kind < 0.70:
        i = rng.randrange(start, len(letters))
        if NEAR[letters[i]]:
            letters[i] = rng.choice(NEAR[letters[i]])
    else:
        options = [(m.start(), old, new) for old, new in SOUNDS for m in re.finditer(old, word) if m.start() >= start]
        if options:
            at, old, new = rng.choice(options)
            letters = list(word[:at] + new + word[at + len(old):])
        elif len(letters) - start >= 2:
            i = rng.randrange(start, len(letters) - 1)
            letters[i], letters[i + 1] = letters[i + 1], letters[i]
    return "".join(letters)


def made_up(word):
    typo = slip(word)
    if len(word) >= 7 and rng.random() < 0.3:
        typo = slip(typo)
    return typo


def like(original, replacement):
    if len(original) > 1 and original.isupper():
        return replacement.upper()
    return replacement[0].upper() + replacement[1:] if original[0].isupper() else replacement


def corrupt(sentence):
    words = [m for m in re.finditer(r"[A-Za-z]+(?:'[a-z]+)?", sentence) if len(m.group()) >= 2]
    if rng.random() < 0.32 or not words:
        return sentence, 0
    wanted = rng.choices([1, 2, 3], weights=[55, 30, 15])[0]
    rng.shuffle(words)
    edits = []
    # Names and long technical words are rare among all words but are exactly where a writer needs
    # the model's knowledge, so half the corrupted sentences get one of those misspelled first.
    knowledge = [m for m in words if len(m.group()) >= 5 and m.group().isalpha()
                 and ((m.group()[0].isupper() and m.start() > 0) or len(m.group()) >= 9)]
    if knowledge and rng.random() < 0.5:
        m = knowledge[0]
        typo = slip(m.group().lower())
        if rng.random() < 0.45:
            typo = slip(typo)
        if typo != m.group().lower():
            edits.append((m.start(), m.end(), like(m.group(), typo)))
            words = [w for w in words if w is not m]
    for m in words:
        if len(edits) == wanted:
            break
        word, low = m.group(), m.group().lower()
        roll = rng.random()
        if low in real_words and roll < 0.45:
            new = rng.choice(real_words[low])
        elif low in misspellings and roll < 0.8:
            new = rng.choice(misspellings[low])
        elif len(low) >= 4 and low.isalpha():
            new = made_up(low)
        else:
            continue
        if new and new != low and " " not in new:
            edits.append((m.start(), m.end(), like(word, new)))
    for start, end, new in sorted(edits, reverse=True):
        sentence = sentence[:start] + new + sentence[end:]
    return sentence, len(edits)


chunks = sorted(glob.glob(f"{chunks_dir}/chunk-*.txt"))
per_chunk = count // len(chunks) + 1
pairs, kinds = [], collections.Counter()
for chunk in chunks:
    lines = [l.strip() for l in open(chunk, encoding="utf-8")]
    lines = [l for l in lines if 20 <= len(l) <= 200 and l[-1:] in ".!?\"'" and not re.search(r"https?:|@|\d{5,}", l)]
    for sentence in rng.sample(lines, min(per_chunk, len(lines))):
        typed, edits = corrupt(sentence)
        kinds[edits] += 1
        pairs.append({"prompt": typed, "completion": sentence})
rng.shuffle(pairs)
pairs = pairs[:count]
valid = max(len(pairs) // 100, 200)
for name, part in (("valid", pairs[:valid]), ("test", pairs[valid:2 * valid]), ("train", pairs[2 * valid:])):
    with open(f"{out_dir}/{name}.jsonl", "w", encoding="utf-8") as f:
        f.writelines(json.dumps(p, ensure_ascii=False) + "\n" for p in part)
print(f"{len(pairs)} pairs; errors per sentence: {dict(sorted(kinds.items()))}")
for p in pairs[:14]:
    if p["prompt"] != p["completion"]:
        print("  " + p["prompt"] + "\n   -> " + p["completion"])
