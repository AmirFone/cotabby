#!/bin/bash
# Everything that can be checked without the screen, at once.
#
#   Tools/check.sh                 lint, unit tests, regression suites, generated lists
#   FAST=1 Tools/check.sh          the same without the tests that load a real language model
#   REPLAY=~/Downloads/export.jsonl Tools/check.sh
#                                  also types that training export again through the engine
#
# The stages run side by side and each writes its own log, so a full pass costs about as long as
# the slowest one (the unit suite, two to three minutes) and not their sum. The last lines are one
# row per stage and the exit status is non-zero if any failed. Run it before every commit; the
# on-screen suite (Tools/e2e/live-smoke.sh) is the only thing it leaves out.
#
# It builds in its own derived-data folders, so it can run while an on-screen test is using the
# installed app and the tool that suite calls.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${CHECK_OUT:-$(mktemp -d -t cotabby-check)}"
mkdir -p "$OUT"
TESTS_DERIVED="$HOME/Library/Developer/Xcode/DerivedData/CotabbyFork-Check"
TOOL_DERIVED="$HOME/Library/Developer/Xcode/DerivedData/CotabbyFork-CheckTool"
MODEL="$HOME/Library/Application Support/Cotabby Dev/LlamaRuntime/gemma-4-E2B.i1-Q6_K.gguf"
# The sentence model for the replay: the copy inside a released app, else the one the app downloads
# or a source build installs. A build made by Tools/install-dev.sh has none inside.
SENTENCE_MODEL=""
for candidate in "/Applications/Cotabby Dev.app/Contents/Resources/spelling-qwen3-0.6b-q8_0.gguf" \
  "$HOME/Library/Application Support/Cotabby Dev/SentenceModel/spelling-qwen3-0.6b-q8_0.gguf"; do
  if [ -z "$SENTENCE_MODEL" ] && [ -f "$candidate" ]; then SENTENCE_MODEL="$candidate"; fi
done
STARTED=$(date +%s)

# stage <name> <command...>: runs it in the background, logs to $OUT/<name>.log, records the status
# and the seconds it took.
stage() {
  local name="$1"; shift
  (
    local began; began=$(date +%s)
    if "$@" > "$OUT/$name.log" 2>&1; then echo "PASS $(( $(date +%s) - began ))" > "$OUT/$name.status"
    else echo "FAIL $(( $(date +%s) - began ))" > "$OUT/$name.status"; fi
  ) &
}

lint() {
  local output; output=$(swiftlint lint --quiet 2>&1)
  echo "$output"
  [ -z "$output" ]
}

unit_tests() {
  local with_model=()
  if [ -z "${FAST:-}" ] && [ -f "$MODEL" ]; then with_model=(env "TEST_RUNNER_WORD_LM_FILE=$MODEL"); fi
  # (`${array[@]+...}`: the system bash calls an empty array unset.)
  ${with_model[@]+"${with_model[@]}"} xcodebuild test -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' \
    -derivedDataPath "$TESTS_DERIVED" CODE_SIGNING_ALLOWED=NO > "$OUT/unit-full.log" 2>&1
  local status=$?
  grep -E "error: -\[|: error:|Executed [0-9]+ tests|\*\* TEST" "$OUT/unit-full.log" | grep -v linkd | tail -40
  return $status
}

# The command-line tool, then every suite that runs on it. One stage, because they all need the build.
tool_suites() {
  xcodebuild -project Cotabby.xcodeproj -scheme cotabby-spell -configuration Release \
    -derivedDataPath "$TOOL_DERIVED" build > "$OUT/tool-build.log" 2>&1 \
    || { grep -E "error:" "$OUT/tool-build.log" | head -20; echo "the tool did not build"; return 1; }
  local cli="$TOOL_DERIVED/Build/Products/Release/cotabby-spell" failed=0
  "$cli" --suite Tools/cotabby-spell/cases.txt > "$OUT/cases.log" 2>&1 || failed=1
  SECOND_JUDGE=1 "$cli" --suite Tools/cotabby-spell/cases-second-judge.txt > "$OUT/cases-second-judge.log" 2>&1 || failed=1
  tail -n 1 "$OUT/cases.log"; grep -E "^FAIL" "$OUT/cases.log" | head -20
  "$cli" --sentences Tools/cotabby-spell/sentences.txt > "$OUT/sentences.log" 2>&1 || failed=1
  tail -n 1 "$OUT/sentences.log"; grep -E "^FAIL" "$OUT/sentences.log" | head -20
  # Speed is reported, not judged: it depends on what else the Mac is doing.
  "$cli" --suite Tools/cotabby-spell/cases.txt --bench 2>/dev/null | grep -E "keystrokes" | head -1
  if [ -n "${REPLAY:-}" ]; then
    # Without the model the replay would still run, on the local rules alone, and print lower
    # numbers that look like a regression; that is a failed check, not a quiet pass.
    if [ -z "$SENTENCE_MODEL" ]; then echo "replay: no sentence model found, so its numbers would not be comparable"; return 1; fi
    local model_arguments=(--sentence-model "$SENTENCE_MODEL")
    "$cli" --american --replay "$REPLAY" --adapt ${model_arguments[@]+"${model_arguments[@]}"} 2>/dev/null \
      | grep -E "replayed|fixed without|made or shown first|changed to another|changed without" || failed=1
  fi
  return $failed
}

# The word lists in Resources are written by scripts; a list edited by hand, or a script changed
# without running it, shows up here as a difference.
generated_lists() {
  local scratch failed=0; scratch=$(mktemp -d -t cotabby-lists)
  python3 -I Tools/prediction/build_technical_words.py Cotabby/Resources/frequency_dictionary_en_82_765.txt \
    "$scratch/technical_words_en.txt" "$scratch/technical_spelling_en.txt" || return 1
  local list script
  for list in technical_words_en.txt technical_spelling_en.txt; do
    if cmp -s "$scratch/$list" "Cotabby/Resources/$list"; then echo "$list is up to date"
    else echo "$list differs from what its script writes: run Tools/prediction/build_technical_words.py"; failed=1; fi
  done
  for script in Tools/prediction/*.py Tools/training/*.py Tools/sentence-model/*.py; do
    # Parsed, not compiled: compiling would leave __pycache__ folders in the repository.
    python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1])' "$script" 2>&1 || failed=1
  done
  bash -n Tools/e2e/live-smoke.sh && bash -n Tools/release/package-dmg.sh || failed=1
  return $failed
}

stage lint lint
stage unit-tests unit_tests
stage tool-suites tool_suites
stage generated-lists generated_lists
wait

failed=0
printf '\n%-18s %-6s %s\n' "stage" "result" "seconds"
for name in lint unit-tests tool-suites generated-lists; do
  read -r result seconds < "$OUT/$name.status"
  printf '%-18s %-6s %s\n' "$name" "$result" "$seconds"
  [ "$result" = PASS ] || failed=1
done
echo
for name in unit-tests tool-suites; do
  echo "--- $name"; tail -n 12 "$OUT/$name.log"
done
for name in lint generated-lists; do
  read -r result _ < "$OUT/$name.status"
  [ "$result" = PASS ] || { echo "--- $name"; cat "$OUT/$name.log"; }
done
echo
echo "$([ $failed -eq 0 ] && echo "ALL PASS" || echo "FAILED") in $(( $(date +%s) - STARTED )) s  (logs: $OUT)"
exit $failed
