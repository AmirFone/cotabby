#!/usr/bin/env python3
"""Trains the auto-fix confidence model from `cotabby-spell --features` rows and writes
Cotabby/Resources/autofix_confidence_en.json (read by AutoFixConfidenceModel).

The model answers one question about one candidate fix for a finished, flagged word: how likely is
it to be the word the writer meant? It is asked once per candidate (up to eight), with the features
written as if that candidate led the list. The app shows the candidates in order of that
probability and applies the first one unasked when its probability clears the threshold.

Positives are candidates equal to the intended word (British and American spellings count as the
same word). Negatives are every other candidate, and every candidate offered for a correct word the
engine flags (names, slang), where any fix is wrong.

The threshold is picked on out-of-fold predictions of the training rows, never on the test rows:
the lowest probability at which at most TARGET_WRONG of the auto-applied fixes are wrong. Birkbeck
labels are noisy (`realy` is listed for `ready`), so the measured wrong rate overstates the real one.

Generated keyboard slips (keys-train, see build_dataset.py) are always reported on (keys-test) and
train the model only when KEYS_WEIGHT is set. They never tune the threshold: most are one edit from
a common word and would loosen it for the recorded typos.
SHORT_TARGET_WRONG sets a stricter bar for typed words of up to four letters, where a slip is one key
from several common words: the lowest probability at which that share of their out-of-fold fixes
(recorded and generated) is wrong. The model file has one threshold, so the stricter bar is written
as one more tree that lowers the log-odds of every candidate of a short word by the difference; the
app needs no change and the candidates keep their order.
SHORT_SWAPS_EXEMPT=1 leaves one kind of short candidate out of that stricter bar: two neighbouring
letters swapped (`teh` for `the`), the one short slip that has a single reading. The bar then holds
for a short candidate that is anything else, the tree asks for the swap as well as the length, and
a swap candidate of a short word keeps the model's own answer.
SHORT_PLAIN=1 goes further: short typed words are judged by a second model trained without the
keyboard slips, at the threshold that model earns by itself, so they behave exactly as they would
with no keyboard slips at all and only longer words gain. Both models go into the one file: every
tree first asks for the typed length and then walks the short or the long model's tree.

Usage: train.py <rows-dir> <dictionary.txt> <birkbeck-dir> <out.json> [--report-only]
Env: TARGET_WRONG (default 0.03), CLEAN_WEIGHT (default 3), TREES (250), LEAVES (15), SHOW_WRONG=1,
     KEYS_WEIGHT (default 0: trains without the keyboard slips), SHORT_TARGET_WRONG (default none),
     SHORT_SWAPS_EXEMPT=1 (with SHORT_TARGET_WRONG),
     SHORT_PLAIN=1 (instead of SHORT_TARGET_WRONG),
     CHECK=<file> (sample inputs and probabilities for `cotabby-spell --check-model`)
"""
import collections, glob, json, os, re, sys, zlib
import numpy as np
import lightgbm as lgb
from sklearn.model_selection import GroupKFold

rows_dir, dictionary_path, bench, out_path = sys.argv[1:5]
TARGET_WRONG = float(os.environ.get("TARGET_WRONG", 0.03))
CLEAN_WEIGHT = float(os.environ.get("CLEAN_WEIGHT", 3))
TREES = int(os.environ.get("TREES", 250))
LEAVES = int(os.environ.get("LEAVES", 15))
KEYS_WEIGHT = float(os.environ.get("KEYS_WEIGHT", 0))
SHORT_TARGET_WRONG = float(os.environ["SHORT_TARGET_WRONG"]) if os.environ.get("SHORT_TARGET_WRONG") else None
SHORT_PLAIN = bool(os.environ.get("SHORT_PLAIN"))
SHORT_LENGTH = 4
SHORT_SWAPS_EXEMPT = bool(os.environ.get("SHORT_SWAPS_EXEMPT"))

dictionary = {line.split()[0] for line in open(dictionary_path, encoding="utf-8")}
UK_US = [(r"isation", "ization"), (r"ise$", "ize"), (r"ised$", "ized"), (r"ising$", "izing"), (r"ises$", "izes"),
         (r"yse$", "yze"), (r"our$", "or"), (r"ours$", "ors"), (r"oured$", "ored"), (r"ouring$", "oring"),
         (r"ourite", "orite"), (r"ourable", "orable"), (r"ourhood", "orhood"), (r"tre$", "ter"), (r"tres$", "ters"),
         (r"ence$", "ense"), (r"ences$", "enses"), (r"lled$", "led"), (r"lling$", "ling"), (r"ller$", "ler"),
         (r"ogue$", "og"), (r"mme$", "m"), (r"^grey", "gray"), (r"^sceptic", "skeptic"), (r"^moustache", "mustache"),
         (r"^practise", "practice"), (r"lful", "llful"), (r"^tyre", "tire"), (r"^cheque", "check")]


def american(word):
    """British and American spellings of one word count as the same word."""
    word = word.lower()
    for pattern, replacement in UK_US:
        candidate = re.sub(pattern, replacement, word)
        if candidate != word and candidate in dictionary:
            return candidate
    return word


intended_by_typo = collections.defaultdict(set)
for path in glob.glob(f"{bench}/*-dev.txt") + glob.glob(f"{bench}/*-test.txt"):
    name = os.path.basename(path)
    if not name.startswith(("holbrook", "wikipedia", "aspell", "missp")):
        continue
    for line in open(path):
        if not line.startswith("#"):
            intended, typo = line.rstrip("\n").split("\t")
            intended_by_typo[typo].add(american(intended))


def load(pattern, kind, weight=1.0, isolated=False, tunes_threshold=True, repeats=3):
    """One dict per flagged word: a feature vector and a label per candidate, plus what the rule did.
    `tunes_threshold` is False for synthetic rows that are easier than recorded typos (run-together
    words, keyboard slips): they train the model but must not loosen the threshold for everything
    else. `repeats` caps the rows of one typo for one word; None keeps them all, for slips generated
    as often as the word occurs in text."""
    result = []
    for path in sorted(glob.glob(f"{rows_dir}/{pattern}")):
        lines = open(path, encoding="utf-8").read().split("\n")
        header = json.loads(lines[0])["features"]
        seen = collections.Counter()
        for line in lines[1:]:
            row = json.loads(line)
            if not row.get("xs"):
                continue
            typed, candidates = row["typed"].lower(), row["candidates"]
            if kind == "clean":
                if american(typed) == american(candidates[0]):  # Americanizing a British spelling is not an error
                    continue
                seen[typed] += 1
                if seen[typed] > 2:  # Tatoeba repeats a handful of names hundreds of times
                    continue
                labels = [0] * len(candidates)
            else:
                # Frequent words have few recorded typos, so one pair (`thoy` for `the`) would
                # otherwise fill hundreds of rows.
                seen[(typed, row["intended"])] += 1
                if repeats and seen[(typed, row["intended"])] > repeats:
                    continue
                wanted = {american(row["intended"])} | (intended_by_typo[typed] if isolated else set())
                labels = [int(american(candidate) in wanted) for candidate in candidates]
            result.append({"xs": row["xs"], "labels": labels, "w": weight, "rule": row["ruleAuto"], "typed": typed,
                           "candidates": candidates, "intended": row["intended"], "kind": kind, "header": header,
                           "tunes": tunes_threshold and kind == "typo" and weight == 1.0,
                           "keys": os.path.basename(path).startswith("keys-")})
    return result


train = (load("typos-train.jsonl", "typo") + load("bare-train.jsonl", "typo", isolated=True)
         + load("runon-train.jsonl", "typo", tunes_threshold=False)
         + load("iso-holbrook-missp-dev.jsonl", "typo", isolated=True)
         + load("iso-wikipedia-dev.jsonl", "typo", isolated=True) + load("iso-aspell-dev.jsonl", "typo", isolated=True)
         + load("iso-missp-dev.jsonl", "typo", 0.3, isolated=True) + load("clean-train-*.jsonl", "clean", CLEAN_WEIGHT))
keys_start = len(train)
if KEYS_WEIGHT > 0:
    train += load("keys-train.jsonl", "typo", KEYS_WEIGHT, tunes_threshold=False, repeats=None)
tests = {
    "in sentences": load("typos-test.jsonl", "typo"),
    "empty field": load("bare-test.jsonl", "typo", isolated=True),
    "run-together": load("runon-test.jsonl", "typo"),
    "holbrook": load("iso-holbrook-missp-test.jsonl", "typo", isolated=True),
    "wikipedia": load("iso-wikipedia-test.jsonl", "typo", isolated=True),
    "aspell": load("iso-aspell-test.jsonl", "typo", isolated=True),
    "clean words": load("clean-test.jsonl", "clean"),
    "keyboard": load("keys-test.jsonl", "typo", repeats=None),
}
names = list(train[0]["header"])
LENGTH_COLUMN = names.index("typoLength")
SWAP_COLUMN = names.index("topIsAdjacentSwap")


def under_stricter_bar(rows):
    """The candidate rows the stricter bar for short words applies to: every candidate of a typed word
    of up to SHORT_LENGTH letters, or with SHORT_SWAPS_EXEMPT those that are not a swap of two
    neighbouring letters."""
    short = rows[:, LENGTH_COLUMN] <= SHORT_LENGTH + 0.5
    return short & (rows[:, SWAP_COLUMN] < 0.5) if SHORT_SWAPS_EXEMPT else short


def flatten_rows(words):
    X = np.array([x for word in words for x in word["xs"]], dtype=float)
    y = np.array([label for word in words for label in word["labels"]])
    weights = np.array([word["w"] for word in words for _ in word["xs"]])
    groups = np.array([zlib.crc32(word["typed"].encode()) % 1000 for word in words for _ in word["xs"]])
    return X, y, weights, groups


def choices(words, probabilities):
    """Per word: (probability of the model's first choice, whether it is right, its term, hand top right)."""
    picked, offset = [], 0
    for word in words:
        count = len(word["xs"])
        scores = probabilities[offset:offset + count]
        offset += count
        order = np.argsort(-scores, kind="stable")
        best = int(order[0])
        top3 = max(word["labels"][int(i)] for i in order[:3])
        picked.append((float(scores[best]), word["labels"][best], word["candidates"][best], word["labels"][0], top3, max(word["labels"])))
    return picked


X, y, weights, groups = flatten_rows(train)
params = dict(objective="binary", learning_rate=0.05, num_leaves=LEAVES, min_child_samples=40,
              subsample=0.8, subsample_freq=1, colsample_bytree=0.8, reg_lambda=5.0, verbose=-1, n_jobs=32, seed=7)

oof = np.zeros(len(X))
for fit, held in GroupKFold(5).split(X, y, groups):
    fold = lgb.LGBMClassifier(n_estimators=TREES, **params).fit(X[fit], y[fit], sample_weight=weights[fit])
    oof[held] = fold.predict_proba(X[held])[:, 1]
oof_choices = choices(train, oof)
trusted = [choice for choice, word in zip(oof_choices, train) if word["tunes"]]


def threshold_for(target, scored=None):
    """Lowest probability whose auto-applied trusted typo fixes are wrong at most `target` of the time."""
    ordered = sorted(trusted if scored is None else scored, key=lambda choice: -choice[0])
    wrong = np.cumsum([1 - choice[1] for choice in ordered])
    passing = np.nonzero(wrong / np.arange(1, len(ordered) + 1) <= target)[0]
    return ordered[passing[-1]][0] if len(passing) else 1.0


threshold = threshold_for(TARGET_WRONG)
final = lgb.LGBMClassifier(n_estimators=TREES, **params).fit(X, y, sample_weight=weights)


def log_odds(probability):
    return float(np.log(probability / (1 - probability)))


# The stricter bar for short words, as the log-odds taken off every candidate of one.
short_cut, short_shift = None, 0.0
if SHORT_TARGET_WRONG is not None:
    def is_held(word, choice):
        """Whether the word's first choice is a candidate the stricter bar applies to."""
        if len(word["typed"]) > SHORT_LENGTH:
            return False
        if not SHORT_SWAPS_EXEMPT:
            return True
        return word["xs"][word["candidates"].index(choice[2])][SWAP_COLUMN] < 0.5

    short = sorted((choice for choice, word in zip(oof_choices, train)
                    if (word["tunes"] or word["keys"]) and is_held(word, choice)),
                   key=lambda choice: -choice[0])
    wrong = np.cumsum([1 - choice[1] for choice in short])
    passing = np.nonzero(wrong / np.arange(1, len(short) + 1) <= SHORT_TARGET_WRONG)[0]
    short_cut = short[passing[-1]][0] if len(passing) else 1 - 1e-6
    short_shift = max(0.0, log_odds(short_cut) - log_odds(threshold))


def shifted(probabilities, shift):
    return 1 / (1 + np.exp(-(np.log(probabilities / (1 - probabilities)) - shift)))


# The model for short typed words, trained on everything but the keyboard slips. Its own threshold
# becomes a shift of its log-odds, so the file's one threshold means that threshold for short words.
plain_final = None
if SHORT_PLAIN and keys_start < len(train):
    plain_rows = sum(len(word["xs"]) for word in train[:keys_start])
    plain_oof = np.zeros(plain_rows)
    for fit, held in GroupKFold(5).split(X[:plain_rows], y[:plain_rows], groups[:plain_rows]):
        fold = lgb.LGBMClassifier(n_estimators=TREES, **params).fit(X[fit], y[fit], sample_weight=weights[fit])
        plain_oof[held] = fold.predict_proba(X[held])[:, 1]
    plain_final = lgb.LGBMClassifier(n_estimators=TREES, **params).fit(X[:plain_rows], y[:plain_rows], sample_weight=weights[:plain_rows])
    plain_choices = choices(train[:keys_start], plain_oof)
    short_cut = threshold_for(TARGET_WRONG, [choice for choice, word in zip(plain_choices, train) if word["tunes"]])
    short_shift = log_odds(short_cut) - log_odds(threshold)
    # Out-of-fold answers of the two models together, for the report and the other targets below.
    is_short = X[:, LENGTH_COLUMN] <= SHORT_LENGTH + 0.5
    plain_all = np.concatenate([plain_oof, plain_final.predict_proba(X[plain_rows:])[:, 1]])
    oof[is_short] = shifted(plain_all[is_short], short_shift)
    trusted = [choice for choice, word in zip(choices(train, oof), train) if word["tunes"]]


def probabilities_of(words):
    """The shipped file's answer for every candidate row: the trees, with what it does for short words."""
    rows = flatten_rows(words)[0]
    result = final.predict_proba(rows)[:, 1]
    is_short = rows[:, LENGTH_COLUMN] <= SHORT_LENGTH + 0.5
    if is_short.any():
        if plain_final is not None:
            result[is_short] = plain_final.predict_proba(rows[is_short])[:, 1]
            if short_shift:
                result[is_short] = shifted(result[is_short], short_shift)
        elif short_shift:
            held = under_stricter_bar(rows)
            result[held] = shifted(result[held], short_shift)
    return result


def slip_kind(intended, typed):
    """Which finger slip turns `intended` into `typed`; "two edits" for anything further."""
    if len(typed) == len(intended):
        differs = [i for i in range(len(typed)) if typed[i] != intended[i]]
        if len(differs) == 1:
            return "neighboring key"
        if len(differs) == 2 and differs[1] == differs[0] + 1 and typed[differs[0]] == intended[differs[1]] \
                and typed[differs[1]] == intended[differs[0]]:
            return "swapped letters"
    if len(typed) == len(intended) - 1 and any(intended[:i] + intended[i + 1:] == typed for i in range(len(intended))):
        return "dropped letter"
    if len(typed) == len(intended) + 1 and any(typed[:i] + typed[i + 1:] == intended for i in range(len(typed))):
        return "extra letter"
    return "two edits"


def keyboard_report(words, picked, cut):
    """The keyboard test by slip and by typed length: how many are fixed unasked, how many of those
    wrongly, and how many of the right first candidates are fixed rather than only offered."""
    def line(label, pairs):
        total = len(pairs)
        right = sum(choice[1] for choice, _ in pairs)
        auto = [choice for choice, _ in pairs if choice[0] >= cut]
        wrong = sum(1 - choice[1] for choice in auto)
        return (f"  {label:16s} {total:5d}  first right {right / max(total, 1) * 100:5.1f}%  fixed unasked {len(auto) / max(total, 1) * 100:5.1f}% "
                f"({wrong:3d} wrong, {wrong / max(len(auto), 1) * 100:4.1f}%)  right first candidates fixed "
                f"{(len(auto) - wrong) / max(right, 1) * 100:5.1f}% ({len(auto) - wrong} of {right})")

    pairs = list(zip(picked, words))
    print(line("all", pairs))
    for kind in ("neighboring key", "dropped letter", "extra letter", "swapped letters", "two edits"):
        print(line(kind, [pair for pair in pairs if slip_kind(pair[1]["intended"], pair[1]["typed"]) == kind]))
    for label, low, high in (("2-3 letters", 0, 3), ("4 letters", 4, 4), ("5+ letters", 5, 99)):
        print(line(label, [pair for pair in pairs if low <= len(pair[1]["typed"]) <= high]))
    short_one_edit = [pair for pair in pairs if len(pair[1]["typed"]) <= SHORT_LENGTH
                      and slip_kind(pair[1]["intended"], pair[1]["typed"]) != "two edits"]
    print(line("one edit, <=4", short_one_edit))
    print(line("one edit, 5+", [pair for pair in pairs if len(pair[1]["typed"]) > SHORT_LENGTH
                                and slip_kind(pair[1]["intended"], pair[1]["typed"]) != "two edits"]))


def report(label, words, picked, cut):
    total = len(words)
    rule = [word["rule"] for word in words]
    auto = [choice for choice in picked if choice[0] >= cut]
    if words[0]["kind"] == "clean":
        return (f"{label:13s} {total:5d} flagged correct words   edited by rule {sum(rule):3d} ({sum(rule) / total * 100:4.1f}%)   "
                f"by model {len(auto):3d} ({len(auto) / total * 100:4.1f}%)")
    rule_wrong = sum(1 for word in words if word["rule"] and not word["labels"][0])
    wrong = sum(1 - choice[1] for choice in auto)
    first = sum(choice[1] for choice in picked) / total * 100
    return (f"{label:13s} {total:5d} typos  first guess right: ranker {sum(choice[3] for choice in picked) / total * 100:4.1f}% "
            f"model {first:4.1f}% (top-3 {sum(choice[4] for choice in picked) / total * 100:4.1f}%, offered at all "
            f"{sum(choice[5] for choice in picked) / total * 100:4.1f}%)\n"
            f"{'':13s}       fixed unasked: rule {sum(rule) / total * 100:4.1f}% ({rule_wrong / max(sum(rule), 1) * 100:4.1f}% wrong)   "
            f"model {len(auto) / total * 100:4.1f}% ({wrong / max(len(auto), 1) * 100:4.1f}% wrong)")


print(f"train: {len(train)} words ({len(train) - keys_start} keyboard slips at weight {KEYS_WEIGHT:g}), {len(X)} candidate rows, "
      f"{X.shape[1]} features; threshold {threshold:.3f} for <= {TARGET_WRONG * 100:.1f}% wrong out-of-fold")
if plain_final is not None:
    print(f"words of up to {SHORT_LENGTH} letters: the model without keyboard slips, from {short_cut:.3f} "
          f"(its <= {TARGET_WRONG * 100:.1f}% wrong out-of-fold)")
elif short_cut is not None:
    print(f"words of up to {SHORT_LENGTH} letters: {short_cut:.3f} for <= {SHORT_TARGET_WRONG * 100:.1f}% wrong out-of-fold "
          f"({short_shift:.2f} log-odds stricter)")
print(report("out-of-fold", [word for word in train if word["tunes"]], trusted, threshold))
picked = {}
for label, words in tests.items():
    picked[label] = choices(words, probabilities_of(words))
    print(report(label, words, picked[label], threshold))
print("keyboard slips by kind and by typed length:")
keyboard_report(tests["keyboard"], picked["keyboard"], threshold)
for target in (0.01, 0.02, 0.03, 0.04, 0.05):
    cut = threshold_for(target)
    auto = [choice for choice in picked["in sentences"] if choice[0] >= cut]
    print(f"  target {target * 100:3.0f}% → cut {cut:.3f}: in sentences {len(auto) / len(picked['in sentences']) * 100:5.1f}% fixed, "
          f"{sum(1 - c[1] for c in auto) / max(len(auto), 1) * 100:4.1f}% wrong; "
          f"correct words edited {sum(c[0] >= cut for c in picked['clean words'])}; "
          f"keyboard {sum(c[0] >= cut for c in picked['keyboard']) / len(picked['keyboard']) * 100:5.1f}% fixed, "
          f"{sum(1 - c[1] for c in picked['keyboard'] if c[0] >= cut) / max(sum(c[0] >= cut for c in picked['keyboard']), 1) * 100:4.1f}% wrong")
if os.environ.get("SHOW_WRONG"):
    for label in ("in sentences", "holbrook", "wikipedia", "aspell", "clean words", "keyboard"):
        for choice, word in sorted(zip(picked[label], tests[label]), key=lambda item: -item[0][0]):
            if choice[0] >= threshold and not choice[1]:
                print(f"  WRONG {choice[0]:.2f} [{label}] {word['typed']} → {choice[2]} (wanted {word['intended']})")
gains = sorted(zip(final.booster_.feature_importance("gain"), names), reverse=True)
print("top features: " + ", ".join(f"{name} {gain / sum(g for g, _ in gains) * 100:.0f}%" for gain, name in gains[:12]))

if "--report-only" in sys.argv:
    sys.exit(0)


def flatten(tree):
    """A LightGBM tree as parallel arrays; leaves have feature -1."""
    feature, cut, left, right, value = [], [], [], [], []

    def visit(node):
        index = len(feature)
        for column in (feature, cut, left, right, value):
            column.append(0)
        if "leaf_value" in node:
            feature[index], value[index] = -1, round(node["leaf_value"], 6)
            return index
        if node["decision_type"] != "<=":
            raise ValueError("unsupported split " + node["decision_type"])
        feature[index], cut[index] = node["split_feature"], node["threshold"]
        left[index] = visit(node["left_child"])
        right[index] = visit(node["right_child"])
        return index

    visit(tree["tree_structure"])
    return {"feature": feature, "threshold": cut, "left": left, "right": right, "value": value}


def by_length(short, long):
    """One tree that walks `short` for a typed word of up to SHORT_LENGTH letters and `long` for any other."""
    def children(tree, side, offset):
        return [child + offset if feature >= 0 else 0 for child, feature in zip(tree[side], tree["feature"])]

    first, second = 1, 1 + len(short["feature"])
    return {"feature": [LENGTH_COLUMN] + short["feature"] + long["feature"],
            "threshold": [SHORT_LENGTH + 0.5] + short["threshold"] + long["threshold"],
            "left": [first] + children(short, "left", first) + children(long, "left", second),
            "right": [second] + children(short, "right", first) + children(long, "right", second),
            "value": [0] + short["value"] + long["value"]}


trees = [flatten(tree) for tree in final.booster_.dump_model()["tree_info"]]
if plain_final is not None:
    trees = [by_length(flatten(short), long) for short, long in zip(plain_final.booster_.dump_model()["tree_info"], trees, strict=True)]
if short_shift and SHORT_SWAPS_EXEMPT and plain_final is None:
    # Short word (node 0, left) and not a swap (node 1, left): the leaf that takes the shift off.
    trees.append({"feature": [LENGTH_COLUMN, SWAP_COLUMN, -1, -1, -1], "threshold": [SHORT_LENGTH + 0.5, 0.5, 0, 0, 0],
                  "left": [1, 3, 0, 0, 0], "right": [2, 4, 0, 0, 0], "value": [0, 0, 0, round(-short_shift, 6), 0]})
elif short_shift:
    trees.append({"feature": [LENGTH_COLUMN, -1, -1], "threshold": [SHORT_LENGTH + 0.5, 0, 0], "left": [1, 0, 0],
                  "right": [2, 0, 0], "value": [0, round(-short_shift, 6), 0]})
with open(out_path, "w") as f:
    json.dump({"features": names, "threshold": round(threshold, 4), "trees": trees}, f, separators=(",", ":"))
print(f"wrote {out_path} ({os.path.getsize(out_path) // 1024} KB, {len(trees)} trees)")
# Reference outputs so the Swift evaluator can be checked against LightGBM (cotabby-spell --check-model).
if os.environ.get("CHECK"):
    sample = flatten_rows(tests["in sentences"][:60])[0]
    with open(os.environ["CHECK"], "w") as f:
        json.dump([{"x": list(map(float, x)), "p": float(p)}
                   for x, p in zip(sample, probabilities_of(tests["in sentences"][:60]))], f)
