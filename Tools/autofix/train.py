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

Usage: train.py <rows-dir> <dictionary.txt> <birkbeck-dir> <out.json> [--report-only]
Env: TARGET_WRONG (default 0.03), CLEAN_WEIGHT (default 3), TREES (250), LEAVES (15), SHOW_WRONG=1,
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


def load(pattern, kind, weight=1.0, isolated=False, tunes_threshold=True):
    """One dict per flagged word: a feature vector and a label per candidate, plus what the rule did.
    `tunes_threshold` is False for synthetic rows that are easier than recorded typos (run-together
    words): they train the model but must not loosen the threshold for everything else."""
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
                if seen[(typed, row["intended"])] > 3:
                    continue
                wanted = {american(row["intended"])} | (intended_by_typo[typed] if isolated else set())
                labels = [int(american(candidate) in wanted) for candidate in candidates]
            result.append({"xs": row["xs"], "labels": labels, "w": weight, "rule": row["ruleAuto"], "typed": typed,
                           "candidates": candidates, "intended": row["intended"], "kind": kind, "header": header,
                           "tunes": tunes_threshold and kind == "typo" and weight == 1.0})
    return result


train = (load("typos-train.jsonl", "typo") + load("bare-train.jsonl", "typo", isolated=True)
         + load("runon-train.jsonl", "typo", tunes_threshold=False)
         + load("iso-holbrook-missp-dev.jsonl", "typo", isolated=True)
         + load("iso-wikipedia-dev.jsonl", "typo", isolated=True) + load("iso-aspell-dev.jsonl", "typo", isolated=True)
         + load("iso-missp-dev.jsonl", "typo", 0.3, isolated=True) + load("clean-train-*.jsonl", "clean", CLEAN_WEIGHT))
tests = {
    "in sentences": load("typos-test.jsonl", "typo"),
    "empty field": load("bare-test.jsonl", "typo", isolated=True),
    "run-together": load("runon-test.jsonl", "typo"),
    "holbrook": load("iso-holbrook-missp-test.jsonl", "typo", isolated=True),
    "wikipedia": load("iso-wikipedia-test.jsonl", "typo", isolated=True),
    "aspell": load("iso-aspell-test.jsonl", "typo", isolated=True),
    "clean words": load("clean-test.jsonl", "clean"),
}
names = list(train[0]["header"])


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


def threshold_for(target):
    """Lowest probability whose auto-applied trusted typo fixes are wrong at most `target` of the time."""
    ordered = sorted(trusted, key=lambda choice: -choice[0])
    wrong = np.cumsum([1 - choice[1] for choice in ordered])
    passing = np.nonzero(wrong / np.arange(1, len(ordered) + 1) <= target)[0]
    return ordered[passing[-1]][0] if len(passing) else 1.0


threshold = threshold_for(TARGET_WRONG)
final = lgb.LGBMClassifier(n_estimators=TREES, **params).fit(X, y, sample_weight=weights)


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


print(f"train: {len(train)} words, {len(X)} candidate rows, {X.shape[1]} features; "
      f"threshold {threshold:.3f} for <= {TARGET_WRONG * 100:.1f}% wrong out-of-fold")
print(report("out-of-fold", [word for word in train if word["tunes"]], trusted, threshold))
picked = {}
for label, words in tests.items():
    picked[label] = choices(words, final.predict_proba(flatten_rows(words)[0])[:, 1])
    print(report(label, words, picked[label], threshold))
for target in (0.01, 0.02, 0.03, 0.04, 0.05):
    cut = threshold_for(target)
    auto = [choice for choice in picked["in sentences"] if choice[0] >= cut]
    print(f"  target {target * 100:3.0f}% → cut {cut:.3f}: in sentences {len(auto) / len(picked['in sentences']) * 100:5.1f}% fixed, "
          f"{sum(1 - c[1] for c in auto) / max(len(auto), 1) * 100:4.1f}% wrong; "
          f"correct words edited {sum(c[0] >= cut for c in picked['clean words'])}")
if os.environ.get("SHOW_WRONG"):
    for label in ("in sentences", "holbrook", "wikipedia", "aspell", "clean words"):
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


dump = final.booster_.dump_model()
with open(out_path, "w") as f:
    json.dump({"features": names, "threshold": round(threshold, 4),
               "trees": [flatten(tree) for tree in dump["tree_info"]]}, f, separators=(",", ":"))
print(f"wrote {out_path} ({os.path.getsize(out_path) // 1024} KB, {len(dump['tree_info'])} trees)")
# Reference outputs so the Swift evaluator can be checked against LightGBM (cotabby-spell --check-model).
if os.environ.get("CHECK"):
    sample = flatten_rows(tests["in sentences"][:60])[0]
    with open(os.environ["CHECK"], "w") as f:
        json.dump([{"x": list(map(float, x)), "p": float(p)} for x, p in zip(sample, final.predict_proba(sample)[:, 1])], f)
