#!/usr/bin/env python3
"""Trains the wrong-word model from `cotabby-spell --wrong-features` rows and writes
Cotabby/Resources/wrong_word_en.json (same tree format as the auto-fix model).

One row is one (typed real word, alternative) pair in a sentence, in one of two views: as the
sentence pass sees it (words on both sides) or as the caret sees it right after the word is typed
(nothing to the right yet). The label is 1 only for the intended word at the place where a real word
was swapped in; every alternative of every other word is a negative, so the model learns mostly from
correct text, as it will see in use. One model serves both views; each gets its own threshold.

A word is flagged when its best alternative's probability clears the threshold. The threshold is
picked on out-of-fold predictions so that at most TARGET_ALARMS of *correct sentences* get any flag,
because an interruption on a correct sentence costs more than a missed slip. A second, stricter
threshold marks fixes safe to apply without asking: at most TARGET_AUTO_WRONG of those are wrong.

Usage: train_wrong_word.py <rows-dir> <out.json> [--report-only]
Env: TARGET_ALARMS (0.003, sentence view), TARGET_CARET_ALARMS (0.003, caret view), TARGET_AUTO_WRONG
(0.02), TREES (300), LEAVES (31), SHOW=1, CHECK=<file>
"""
import collections, glob, json, os, sys, zlib
import numpy as np
import lightgbm as lgb
from sklearn.model_selection import GroupKFold

rows_dir, out_path = sys.argv[1:3]
TARGET_ALARMS = float(os.environ.get("TARGET_ALARMS", 0.003))
TARGET_CARET_ALARMS = float(os.environ.get("TARGET_CARET_ALARMS", 0.003))
TARGET_AUTO_WRONG = float(os.environ.get("TARGET_AUTO_WRONG", 0.02))
TREES = int(os.environ.get("TREES", 300))
LEAVES = int(os.environ.get("LEAVES", 31))
META = 7  # sentence, word, label, swapped, view, typed, candidate
SENTENCE, CARET = 0, 1


def load(split):
    """Rows of both the swapped and the correct sentences of one split, with sentence keys made unique."""
    names, features, labels, keys, words, swapped_word, kinds, views = None, [], [], [], [], [], [], []
    rule = {}
    for path in sorted(glob.glob(f"{rows_dir}/wrongword-{split}.*.csv") + glob.glob(f"{rows_dir}/wrongword-clean-{split}.*.csv")):
        kind = "clean" if "-clean-" in path else "swapped"
        shard = os.path.basename(path)
        with open(path, encoding="utf-8") as f:
            header = f.readline().rstrip("\n").split(",")
            names = header[META:]
            for line in f:
                parts = line.rstrip("\n").split(",")
                keys.append((shard, int(parts[0]), int(parts[1])))
                labels.append(int(parts[2]))
                swapped_word.append(int(parts[3]))
                views.append(int(parts[4]))
                words.append((parts[5], parts[6]))
                kinds.append(kind)
                features.append(parts[META:])
        for line in open(path + ".rule").read().split("\n")[1:]:
            sentence, is_swapped, caught, false_flags, caret_caught, caret_false_flags = map(int, line.split(","))
            rule[(shard, sentence)] = (kind, caught, false_flags, caret_caught, caret_false_flags)
    return dict(names=names, X=np.array(features, dtype=np.float32), y=np.array(labels), keys=keys, words=words,
                swapped=np.array(swapped_word), kinds=kinds, rule=rule, views=np.array(views))


def decisions(data, probabilities, view):
    """Per word in one view: its best alternative. Returns {(shard, sentence): [(probability, is right, typed, candidate, is swapped word)]}."""
    best = {}
    for key, p, label, pair, swapped, row_view in zip(data["keys"], probabilities, data["y"], data["words"], data["swapped"], data["views"]):
        if row_view != view:
            continue
        if key not in best or p > best[key][0]:
            best[key] = (float(p), int(label), pair[0], pair[1], int(swapped))
    by_sentence = collections.defaultdict(list)
    for (shard, sentence, _), value in best.items():
        by_sentence[(shard, sentence)].append(value)
    return by_sentence


def measure(data, by_sentence, cut):
    """Recall on swapped sentences and false alarms on correct ones, at one threshold."""
    swapped = [key for key, value in data["rule"].items() if value[0] == "swapped"]
    clean = [key for key, value in data["rule"].items() if value[0] == "clean"]
    caught = sum(any(p >= cut and right for p, right, *_ in by_sentence.get(key, [])) for key in swapped)
    alarmed = sum(any(p >= cut for p, *_ in by_sentence.get(key, [])) for key in clean)
    flags = [(p, right) for key in swapped + clean for p, right, *_ in by_sentence.get(key, []) if p >= cut]
    return caught / max(len(swapped), 1), alarmed / max(len(clean), 1), len(flags), sum(1 - right for _, right in flags)


def threshold_for_alarms(data, by_sentence, target):
    clean = [key for key, value in data["rule"].items() if value[0] == "clean"]
    worst = sorted((max((p for p, *_ in by_sentence.get(key, [])), default=0.0) for key in clean), reverse=True)
    allowed = int(target * len(clean))
    return worst[allowed] + 1e-9 if allowed < len(worst) else 0.0


def threshold_for_auto(by_sentence, target):
    """Lowest probability above which at most `target` of all flags (on any sentence) are wrong."""
    flags = sorted(((p, right) for values in by_sentence.values() for p, right, *_ in values), reverse=True)
    wrong = np.cumsum([1 - right for _, right in flags])
    passing = np.nonzero(wrong / np.arange(1, len(flags) + 1) <= target)[0]
    return flags[passing[-1]][0] if len(passing) else 1.0


train, test = load("train"), load("test")
names = train["names"]
params = dict(objective="binary", learning_rate=0.05, num_leaves=LEAVES, min_child_samples=30, subsample=0.8,
              subsample_freq=1, colsample_bytree=0.8, reg_lambda=5.0, verbose=-1, n_jobs=32, seed=7)
groups = np.array([zlib.crc32(f"{key[0]}/{key[1]}".encode()) % 1000 for key in train["keys"]])
oof = np.zeros(len(train["y"]))
for fit, held in GroupKFold(5).split(train["X"], train["y"], groups):
    fold = lgb.LGBMClassifier(n_estimators=TREES, **params).fit(train["X"][fit], train["y"][fit])
    oof[held] = fold.predict_proba(train["X"][held])[:, 1]
oof_views = {view: decisions(train, oof, view) for view in (SENTENCE, CARET)}
threshold = threshold_for_alarms(train, oof_views[SENTENCE], TARGET_ALARMS)
caret_threshold = threshold_for_alarms(train, oof_views[CARET], TARGET_CARET_ALARMS)
auto_threshold = max(threshold, threshold_for_auto(oof_views[SENTENCE], TARGET_AUTO_WRONG))
final = lgb.LGBMClassifier(n_estimators=TREES, **params).fit(train["X"], train["y"])
test_probabilities = final.predict_proba(test["X"])[:, 1]
test_views = {view: decisions(test, test_probabilities, view) for view in (SENTENCE, CARET)}


def rule_report(data, view):
    """The hand rule's (caught, correct sentences flagged) in one view."""
    offset = 1 if view == SENTENCE else 3
    swapped = [v for v in data["rule"].values() if v[0] == "swapped"]
    clean = [v for v in data["rule"].values() if v[0] == "clean"]
    return (sum(v[offset] for v in swapped) / max(len(swapped), 1), sum(v[offset + 1] > 0 for v in clean) / max(len(clean), 1),
            len(swapped), len(clean))


print(f"train: {len(train['y'])} rows ({int(train['y'].sum())} positive), {len(names)} features; "
      f"sentence pass flags from {threshold:.3f}, caret from {caret_threshold:.3f} "
      f"(<= {TARGET_ALARMS * 100:.1f}% / {TARGET_CARET_ALARMS * 100:.1f}% of correct sentences flagged, out-of-fold); "
      f"safe-to-apply would be {auto_threshold:.3f} (not used)")
for label, data, views in (("out-of-fold", train, oof_views), ("test", test, test_views)):
    for view, name, cut in ((SENTENCE, "sentence pass", threshold), (CARET, "at the caret", caret_threshold)):
        rule_recall, rule_alarms, swapped_count, clean_count = rule_report(data, view)
        recall, alarms, flags, wrong = measure(data, views[view], cut)
        print(f"{label:12s} {name:13s} ({swapped_count} swapped / {clean_count} correct sentences)  "
              f"hand rule: caught {rule_recall * 100:5.1f}%, correct sentences flagged {rule_alarms * 100:5.2f}%   "
              f"model: caught {recall * 100:5.1f}%, flagged {alarms * 100:5.2f}% ({wrong} of {flags} flags wrong)")
for view, name in ((SENTENCE, "sentence pass"), (CARET, "at the caret")):
    for target in (0.002, 0.005, 0.01, 0.02):
        cut = threshold_for_alarms(train, oof_views[view], target)
        recall, alarms, flags, wrong = measure(test, test_views[view], cut)
        print(f"  {name}: alarms target {target * 100:4.1f}% → cut {cut:.3f}: test caught {recall * 100:5.1f}%, correct sentences flagged {alarms * 100:5.2f}%")
if os.environ.get("SHOW"):
    shown = collections.Counter()
    for key, value in test["rule"].items():
        for p, right, typed, candidate, swapped in test_views[CARET].get(key, []):
            if p >= caret_threshold and not right and shown["alarm"] < 50:
                shown["alarm"] += 1
                print(f"  WRONG CARET FLAG {p:.2f} [{value[0]}] {typed} → {candidate}")
gains = sorted(zip(final.booster_.feature_importance("gain"), names), reverse=True)
print("top features: " + ", ".join(f"{name} {gain / sum(g for g, _ in gains) * 100:.0f}%" for gain, name in gains[:12]))

if "--report-only" in sys.argv:
    sys.exit(0)


def flatten(tree):
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
    json.dump({"features": names, "threshold": round(threshold, 4), "caretThreshold": round(caret_threshold, 4),
               "trees": [flatten(tree) for tree in dump["tree_info"]]}, f, separators=(",", ":"))
print(f"wrote {out_path} ({os.path.getsize(out_path) // 1024} KB, {len(dump['tree_info'])} trees)")
if os.environ.get("CHECK"):
    sample = test["X"][:500].astype(float)
    with open(os.environ["CHECK"], "w") as f:
        json.dump([{"x": list(map(float, x)), "p": float(p)} for x, p in zip(sample, final.predict_proba(sample)[:, 1])], f)
