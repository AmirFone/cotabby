# Sentence model

A small language model fine-tuned to do one thing: take the sentence as typed and write it back with
the spelling fixed. A confidence bar on each changed word decides what is applied without asking.
Results and the reasoning are in `FORK.md` under "Sentence model".

The app loads `~/Library/Application Support/Cotabby Dev/SentenceModel/spelling-qwen3-0.6b-q8_0.gguf`
when it exists. The trained adapter it was made from (40 MB, for `Qwen/Qwen3-0.6B`) is next to it in
`qwen3-0.6b-spelling/`. Neither is in the repo.

## Rebuild and re-score

Needs `uv`, a built `cotabby-spell`, the corpora from `Tools/ngram/build_context_table.sh` (`<corpus>`)
and a work folder from `Tools/autofix/run.sh` (`<work>`).

```bash
uv venv --python 3.12 venv && uv pip install --python venv/bin/python mlx-lm torch transformers

# 160,000 (typed -> correct) pairs, then the fine-tune (about 35 minutes on an M3 Max)
python3 build_training_pairs.py <corpus>/chunks <work>/birkbeck ../.. data 160000
venv/bin/python -m mlx_lm lora -c lora.yaml --model Qwen/Qwen3-0.6B --train --data data --mask-prompt \
  --batch-size 16 --iters 4000 --num-layers -1 --max-seq-length 160 --adapter-path adapter

# The 1,040-sentence test, the model's answers, and the report per confidence bar
python3 build_test_set.py <work>/lines <work>/birkbeck set.tsv
FAST=1 venv/bin/python run_model.py set.tsv Qwen/Qwen3-0.6B adapter model.tsv
python3 gate_report.py model.tsv

# The app's own sentence pass on the same sentences, for comparison
python3 run_current_pipeline.py set.tsv ../../build/DerivedData/Build/Products/Release/cotabby-spell current
python3 score_sentences.py "current pipeline" current-auto.tsv
```

## Into the app

```bash
# Merge the adapter into the base model, then convert with llama.cpp's script at the tag the app's
# llama framework was built from (see CotabbyInference's Package.swift, b9310 at the time of writing).
venv/bin/python -m mlx_lm fuse --model Qwen/Qwen3-0.6B --adapter-path adapter --save-path fused
git clone --depth 1 --branch b9310 https://github.com/ggml-org/llama.cpp && uv pip install --python venv/bin/python llama.cpp/gguf-py sentencepiece
venv/bin/python llama.cpp/convert_hf_to_gguf.py fused --outtype q8_0 \
  --outfile ~/Library/Application\ Support/Cotabby\ Dev/SentenceModel/spelling-qwen3-0.6b-q8_0.gguf

# Score the installed file through the app's own runtime and gate (from the repo root)
TEST_RUNNER_SENTENCE_MODEL_SET=$PWD/set.tsv TEST_RUNNER_SENTENCE_MODEL_OUT=$PWD/app.tsv \
TEST_RUNNER_SENTENCE_MODEL_FILE="$HOME/Library/Application Support/Cotabby Dev/SentenceModel/spelling-qwen3-0.6b-q8_0.gguf" \
  xcodebuild test -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/CotabbyFork-Check CODE_SIGNING_ALLOWED=NO \
  -only-testing:CotabbyTests/SentenceModelEvalTests
python3 Tools/sentence-model/app_gate_report.py app.tsv     # the app's exact bars
E2E_ONLY=model Tools/e2e/live-smoke.sh                      # typed live into the test window
```

`run_chat_model.py` runs an untuned chat model as a rewriter (the baseline that showed why tuning is
needed). `score_word_judge.py` scores the wrong-word training rows with a small masked model, the
other idea that was measured.

The shipped fine-tune was trained in two legs: 1,000 steps on a first set of pairs, then 3,000 more
on pairs where half the corrupted sentences carry a misspelled name or long technical word. One run
of 4,000 steps on the current `build_training_pairs.py` output should match or beat it.
