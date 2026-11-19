#!/usr/bin/env python3
"""Builds the line files that `cotabby-spell --features` turns into training rows for the auto-fix
confidence model (see Cotabby/Support/Spelling/AutoFixConfidence.swift and train.py).

Every line is `<intended><TAB><text ending in the typed word and a space>`; `=` as the intended word
marks a correct word, where any fix is wrong.

  typos-train.txt   Birkbeck dev-half typos placed in dev-half held-out sentences (all four corpora;
                    missp is noisy but large)
  typos-test.txt    test-half typos from the trusted corpora (holbrook, wikipedia, aspell) in
                    test-half held-out sentences
  bare-{train,test}.txt  the trusted typos alone in an empty field (no context at all)
  runon-{train,test}.txt two neighboring words typed without their space (`nextdoor`)
  keys-{train,test}.txt  generated keyboard slips (a key beside the one meant, a dropped letter, an
                    extra letter, two letters swapped) on words drawn from held-out sentences as
                    often as they occur in text, so short common words get their share. The Birkbeck
                    typos are handwriting and spelling beliefs; these are finger slips
  clean-train-NN.txt every word of sampled Tatoeba training sentences (the engine flags well under
                    1% of them: names, slang, British spellings)
  clean-test.txt    every word of the test-half held-out sentences
  wrongword-*.txt   whole sentences with one real word swapped for another, and the same sentences
                    untouched, for the wrong-word model (see WrongWordDetector.swift)

The typos use held-out sentences only, because the n-gram context model was trained on the rest and
would otherwise score the intended word unrealistically well. Clean words can come from training
sentences: the features there describe the *wrong* candidates, which the n-gram model never saw in
that position.

Usage: build_dataset.py <eng_sentences.tsv.bz2> <heldout.txt> <birkbeck-dir> <out-dir>
"""
import bz2, collections, os, random, re, sys, zlib

source, heldout_path, bench, out = sys.argv[1:5]
os.makedirs(out, exist_ok=True)
CLEAN_TRAIN_SENTENCES = 400_000
CLEAN_SHARDS = 16
KEY_TRAIN_LINES = 40_000
KEY_TEST_LINES = 8_000
# One day of a real writer's one-edit slips: neighboring key 25%, dropped letter 26%, extra letter
# 20% (half of them a key beside the one meant), swapped neighbors 18%.
SLIP_KINDS = {"neighbor": 25, "drop": 26, "extra": 20, "swap": 18}
TWO_EDIT_SHARE = 0.15
WORD = re.compile(r"[a-z]+")
dictionary = {line.split()[0] for line in open("Cotabby/Resources/frequency_dictionary_en_82_765.txt", encoding="utf-8")}


def typo_table(split, names):
    table = collections.defaultdict(list)
    for name in names:
        for line in open(f"{bench}/{name}-{split}.txt"):
            if not line.startswith("#"):
                intended, typo = line.rstrip("\n").split("\t")
                table[intended].append(typo)
    return table


def typo_lines(pool, table, per_sentence, limit, seed):
    """Typos in place of the words they were recorded for, including the first word of a sentence
    (capitalized as the sentence had it), where there is no context to lean on."""
    rng = random.Random(seed)
    lines = []
    for sentence in pool:
        words = sentence.split(" ")
        spots = [i for i, w in enumerate(words) if WORD.fullmatch(w.lower()) and w.lower() in table
                 and (i == 0 or w == w.lower())]
        rng.shuffle(spots)
        for i in spots[:per_sentence]:
            typo = rng.choice(table[words[i].lower()])
            if words[i][0].isupper():
                typo = typo.capitalize()
            lines.append(f"{words[i].lower()}\t{' '.join(words[:i] + [typo])} ")
    rng.shuffle(lines)
    return lines[:limit]


def bare_lines(table):
    """Each recorded typo alone in an empty field."""
    return [f"{intended}\t{typo} " for intended, typos in sorted(table.items()) for typo in typos]


def run_on_lines(pool, limit, seed):
    """Two neighboring words typed without the space between them (`nextdoor`), where the result is
    not itself a word. The intended "word" is the pair."""
    rng = random.Random(seed)
    lines = []
    for sentence in pool:
        words = sentence.split(" ")
        spots = [i for i in range(1, len(words) - 1)
                 if WORD.fullmatch(words[i]) and WORD.fullmatch(words[i + 1]) and len(words[i]) >= 2 and len(words[i + 1]) >= 2
                 and words[i] in dictionary and words[i + 1] in dictionary and words[i] + words[i + 1] not in dictionary]
        if spots and rng.random() < 0.25:
            i = rng.choice(spots)
            lines.append(f"{words[i]} {words[i + 1]}\t{' '.join(words[:i] + [words[i] + words[i + 1]])} ")
    rng.shuffle(lines)
    return lines[:limit]


def key_neighbors():
    """The same map as `AutoFixFeatures.keyNeighbors` (AutoFixConfidence.swift): the keys beside a key
    in its own row, and the two it touches in each neighboring row (the rows are staggered)."""
    rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    near = {}
    for r, row in enumerate(rows):
        for column, key in enumerate(row):
            beside = {row[c] for c in (column - 1, column + 1) if 0 <= c < len(row)}
            for other in (r - 1, r + 1):
                if 0 <= other < len(rows):
                    offsets = (column - 1, column) if r < other else (column, column + 1)
                    beside |= {rows[other][c] for c in offsets if 0 <= c < len(rows[other])}
            near[key] = sorted(beside)
    return near


KEY_NEIGHBORS = key_neighbors()


def slip(word, kind, rng):
    """One finger slip of `kind` at a random place in `word`."""
    if len(word) < 2:  # a second slip on what the first left of a two-letter word
        return word
    at = rng.randrange(len(word))
    if kind == "neighbor":
        return word[:at] + rng.choice(KEY_NEIGHBORS[word[at]]) + word[at + 1:]
    if kind == "drop":
        return word[:at] + word[at + 1:]
    if kind == "swap":
        at = rng.randrange(len(word) - 1)
        return word[:at] + word[at + 1] + word[at] + word[at + 2:]
    # An extra letter: the key beside the one meant caught as well (half), the key itself twice, or any letter.
    roll = rng.random()
    extra = rng.choice(KEY_NEIGHBORS[word[at]]) if roll < 0.5 else word[at] if roll < 0.8 else rng.choice("abcdefghijklmnopqrstuvwxyz")
    at += rng.randrange(2)
    return word[:at] + extra + word[at:]


def keyboard_lines(pool, limit, seed):
    """Finger slips on words drawn uniformly from the running text, so a word gets slips as often as
    it is written (`teh`, `yhe`, `thr` far more often than any long word). A slip that is itself a
    word is skipped. Nothing marks the ambiguous ones: a short form one key from several common
    words gets whatever first candidate the engine gives it, and when that is not the word it was
    made from the row is a negative, which is how the model learns to leave those as offers."""
    rng = random.Random(seed)
    kinds, weights = list(SLIP_KINDS), list(SLIP_KINDS.values())
    spots = [(words, i) for words in (sentence.split(" ") for sentence in pool) for i, w in enumerate(words)
             if len(w) >= 2 and WORD.fullmatch(w.lower()) and w.lower() in dictionary and (i == 0 or w == w.lower())]
    rng.shuffle(spots)
    lines = []
    for words, i in spots:
        if len(lines) == limit:
            break
        intended = words[i].lower()
        chosen = [rng.choices(kinds, weights)[0] for _ in range(2 if rng.random() < TWO_EDIT_SHARE else 1)]
        for _ in range(8):  # another place in the word when the slip is a word itself
            typo = intended
            for kind in chosen:
                typo = slip(typo, kind, rng)
            if typo != intended and len(typo) >= 2 and typo not in dictionary:
                if words[i][0].isupper():
                    typo = typo.capitalize()
                lines.append(f"{intended}\t{' '.join(words[:i] + [typo])} ")
                break
    return lines


def clean_lines(pool):
    for sentence in pool:
        words = sentence.split(" ")
        for i in range(1, len(words)):
            if re.search(r"[A-Za-z]{3,}", words[i]):
                yield "=\t" + " ".join(words[:i + 1]) + " "


def write(name, lines):
    with open(f"{out}/{name}", "w", encoding="utf-8") as f:
        f.writelines(line + "\n" for line in lines)
    print(name, len(lines))


heldout = [s.strip() for s in open(heldout_path, encoding="utf-8") if s.strip()]
half = len(heldout) // 2
write("typos-train.txt", typo_lines(heldout[:half], typo_table("dev", ["holbrook-missp", "wikipedia", "aspell", "missp"]), 2, 40_000, 1))
write("typos-test.txt", typo_lines(heldout[half:], typo_table("test", ["holbrook-missp", "wikipedia", "aspell"]), 1, 8_000, 2))
write("clean-test.txt", list(clean_lines(heldout[half:])))
write("runon-train.txt", run_on_lines(heldout[:half], 2_000, 21))
write("runon-test.txt", run_on_lines(heldout[half:], 600, 22))
write("bare-train.txt", bare_lines(typo_table("dev", ["holbrook-missp", "wikipedia", "aspell"])))
write("bare-test.txt", bare_lines(typo_table("test", ["holbrook-missp", "wikipedia", "aspell"])))
write("keys-train.txt", keyboard_lines(heldout[:half], KEY_TRAIN_LINES, 31))
write("keys-test.txt", keyboard_lines(heldout[half:], KEY_TEST_LINES, 32))

# Wrong-word rows: a sentence with one real word swapped for another the corpora recorded for it
# (`went` typed as `want`), or for a listed confusable. `<intended><TAB><before><TAB><typed><TAB><after>`;
# `=` with empty middle fields is a correct sentence. Rare pairs are capped so a few common words do
# not fill the file.
groups_source = open("Cotabby/Support/Spelling/RealWordErrorDetector.swift").read()
groups_body = groups_source.split("confusableGroups")[1].split("groupsByWord")[0]
confusable = collections.defaultdict(list)
for group in (re.findall(r'"([^"]+)"', g) for g in re.findall(r'\[("[^\]]+")\]', groups_body)):
    for word in group:
        confusable[word] += [other for other in group if other != word]


def wrong_word_lines(pool, split, seed):
    rng = random.Random(seed)
    table = typo_table(split, ["holbrook-missp-realword", "wikipedia-realword", "aspell-realword", "missp-realword"])
    used = collections.Counter()
    swapped, clean = [], []
    for sentence in pool:
        if sentence[-1:] not in ".!?" or len(sentence.split(" ")) < 3:
            continue
        clean.append("=\t\t\t" + sentence)
        matches = [m for m in re.finditer(r"[A-Za-z]+(?:'[a-z]+)?", sentence)
                   if m.group().lower() in table or m.group().lower() in confusable]
        rng.shuffle(matches)
        for match in matches[:1]:
            intended = match.group().lower()
            # Listed confusables are the commonest real slips, so they get half the swaps when both exist.
            options = confusable[intended] if intended in confusable and (intended not in table or rng.random() < 0.5) else table[intended]
            typed = rng.choice(options)
            used[(intended, typed)] += 1
            if used[(intended, typed)] > 12:
                continue
            if match.group()[0].isupper():
                typed = typed.capitalize()
            swapped.append(f"{intended}\t{sentence[:match.start()]}\t{typed}\t{sentence[match.end():]}")
    return swapped, clean


for split, pool in (("dev", heldout[:half]), ("test", heldout[half:])):
    swapped, clean = wrong_word_lines(pool, split, 11 if split == "dev" else 12)
    name = "train" if split == "dev" else "test"
    write(f"wrongword-{name}.txt", swapped)
    write(f"wrongword-clean-{name}.txt", clean)

train = []
for line in bz2.open(source, "rt", encoding="utf-8"):
    fields = line.rstrip("\n").split("\t")
    if len(fields) >= 3 and zlib.crc32(fields[2].encode()) % 50 != 0:
        train.append(fields[2])
random.Random(3).shuffle(train)
shards = [[] for _ in range(CLEAN_SHARDS)]
for index, line in enumerate(clean_lines(train[:CLEAN_TRAIN_SENTENCES])):
    shards[index % CLEAN_SHARDS].append(line)
for index, shard in enumerate(shards):
    write(f"clean-train-{index:02d}.txt", shard)
