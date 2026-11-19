#!/bin/bash
# Rebuilds both trained spelling models end to end: the auto-fix judge and the wrong-word check. Run
# from the repo root after any change to the ranker, AutoFixFeatures, or WrongWordDetector (each
# model file names its features and is rejected when they differ).
#
#   Tools/autofix/run.sh <work-dir> [train.py options, e.g. --report-only]
#
# <work-dir> keeps the downloads and intermediate rows (about 600 MB); reuse it between runs.
# COTABBY_RESOURCES=<dir> reads the engine's resources from, and writes both models to, another
# folder than Cotabby/Resources: the way to try a candidate dictionary or context table (a copy of
# the folder with one file swapped) and compare its report before shipping anything.
# AUTOFIX_ONLY=1 skips the wrong-word rows and model (a retrain of the auto-fix judge alone).
# Needs: uv (for the Python environment), a built cotabby-spell (see FORK.md).
set -euo pipefail
WORK="$1"; shift
SCRIPTS="$(dirname "$0")"
CLI="${COTABBY_SPELL:-build/DerivedData/Build/Products/Release/cotabby-spell}"
RESOURCES="${COTABBY_RESOURCES:-Cotabby/Resources}"
DICTIONARY="$RESOURCES/frequency_dictionary_en_82_765.txt"
mkdir -p "$WORK/tatoeba" "$WORK/birkbeck" "$WORK/lines" "$WORK/rows"

if [ ! -d "$WORK/venv" ]; then
  uv venv --python 3.12 "$WORK/venv" > /dev/null
  uv pip install --python "$WORK/venv/bin/python" numpy scikit-learn lightgbm > /dev/null
fi
if [ ! -f "$WORK/tatoeba/eng_sentences.tsv.bz2" ]; then
  curl -sSL -o "$WORK/tatoeba/eng_sentences.tsv.bz2" https://downloads.tatoeba.org/exports/per_language/eng/eng_sentences.tsv.bz2
fi
if [ ! -f "$WORK/tatoeba/heldout.txt" ]; then
  python3 Tools/ngram/build_model.py "$WORK/tatoeba/eng_sentences.tsv.bz2" "$DICTIONARY" "$WORK/tatoeba/model.txt" "$WORK/tatoeba/heldout.txt"
fi
[ -f "$WORK/birkbeck/aspell-realword-dev.txt" ] || python3 Tools/cotabby-spell/fetch-birkbeck.py "$WORK/birkbeck"
[ -f "$WORK/lines/keys-train.txt" ] || python3 "$SCRIPTS/build_dataset.py" \
  "$WORK/tatoeba/eng_sentences.tsv.bz2" "$WORK/tatoeba/heldout.txt" "$WORK/birkbeck" "$WORK/lines"

# One engine process per file; they share nothing, so all of them run at once.
for file in "$WORK"/lines/*.txt; do
  case "$(basename "$file")" in wrongword-*) continue ;; esac
  "$CLI" --resources "$RESOURCES" --no-model --features "$file" "$WORK/rows/$(basename "$file" .txt).jsonl" > /dev/null &
done
for name in holbrook-missp wikipedia aspell missp; do
  for split in dev test; do
    "$CLI" --resources "$RESOURCES" --no-model --features "$WORK/birkbeck/$name-$split.txt" "$WORK/rows/iso-$name-$split.jsonl" > /dev/null &
  done
done
if [ -z "${AUTOFIX_ONLY:-}" ]; then
  # Wrong-word rows, in shards of 2,100 sentences.
  mkdir -p "$WORK/wrong"
  for name in wrongword-train wrongword-clean-train wrongword-test wrongword-clean-test; do
    (cd "$WORK/wrong" && split -l 2100 -a 2 "$WORK/lines/$name.txt" "$name.")
  done
  for shard in "$WORK"/wrong/wrongword-*.??; do
    "$CLI" --resources "$RESOURCES" --no-model --wrong-features "$shard" "$shard.csv" > /dev/null &
  done
fi
wait

"$WORK/venv/bin/python" "$SCRIPTS/train.py" "$WORK/rows" "$DICTIONARY" "$WORK/birkbeck" \
  "$RESOURCES/autofix_confidence_en.json" "$@"
[ -n "${AUTOFIX_ONLY:-}" ] || "$WORK/venv/bin/python" "$SCRIPTS/train_wrong_word.py" "$WORK/wrong" "$RESOURCES/wrong_word_en.json" "$@"
