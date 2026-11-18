#!/bin/bash
# Live end-to-end smoke test against the INSTALLED "Cotabby Dev". Relaunches it with debug logs,
# types into the dedicated test host (Tools/e2e/TestHost: one text view, macOS autocorrect off on
# that view only, nothing saved) with real key events, then checks the text and the app's pipeline
# logs. The keys are posted by Cotabby Dev itself (E2EKeyDriver, on only for this run and only while
# the test host is the frontmost app), so whatever runs this script needs no Accessibility grant.
# Ends with the measured time from the key that finished a misspelled word to its fix. It never touches your own apps, documents, or macOS settings. Takes keyboard focus
# for about two minutes. The writer's correction history and the Low Power setting are restored.
#   E2E_FORCE_GENERATION=1  run ghost text even in Low Power Mode (to test the model path on battery)
#   E2E_ONLY=review         repeat only the review-card scenario
#   E2E_ONLY=model          the sentence model's cases only
#   E2E_ONLY=tense          the word strip's verb forms (needs the language model and the CLI)
#   E2E_ONLY=fieldprobe     who types into the one-line field on Tab: this build, or something else
#   E2E_PAUSE_OTHER=1       quit the released Cotabby app for the run and start it again after
#   E2E_ONLY=toggle         the on/off shortcut only
#   E2E_ONLY=training       the opt-in training record (switched on for this run only)
#   E2E_ONLY=settings       picture of Settings at one setting (E2E_SETTING=<id> E2E_SHOT=<file.png>,
#                           E2E_SETTINGS_HEIGHT=<points> makes the window that tall for a long pane)
#   E2E_ONLY=flow           typing on past a sentence the model fixes (E2E_PACE=<ms per key>)
#   E2E_ONLY=shot           screenshot of the word strip with the highlight moved (E2E_SHOT=<file.png>)
#   E2E_ONLY=speed          only time fixes: misspelled words typed at E2E_PACE ms per key (default 45)
#   E2E_ONLY=tornread       Backspace through long lines and count torn reads of the field (E2E_ROUNDS, default 4)
set -uo pipefail
DOMAIN=com.jacobfu.tabby.dev
# Synthesized keys go nowhere on a locked screen; every check would fail as empty text. Checked at
# the start and before each case, since the screen can lock mid-run.
screen_locked() {
  ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked | grep -q "<true/>"
}
if screen_locked; then echo "SKIP  screen is locked; unlock it and run again"; exit 2; fi
# The released Cotabby is a second typing assistant: its ghost text takes Tab and types words into
# the test window, which reads as this build typing something it must not. E2E_PAUSE_OTHER=1 quits
# it for the run and starts it again afterwards; without that the run goes on with a warning.
OTHER_COTABBY=0
# The repository the suite belongs to. Set by a runner that executes a copy of this script from
# somewhere else (Tools/e2e/run-when-idle.sh), so the tool still finds the app's resources.
REPO_ROOT="${COTABBY_REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
HOST_APP=$("$(dirname "$0")/build-host.sh")
HOST=CotabbyE2EHost
HOST_FILES="$HOME/Library/Caches/CotabbyE2E"
KEYS="$HOST_FILES/keys.txt"
: > "$KEYS"; : > "$KEYS.ack"
# The test picks and keeps words like a writer would; snapshot the writer's history and restore it
# afterwards so a test run never teaches Cotabby anything.
SNAPSHOT=$(mktemp -t cotabby-e2e-prefs)
defaults export "$DOMAIN" "$SNAPSHOT"
# The app learns while it runs, so the writer's files are restored with the app stopped, then it is
# relaunched; relaunching first would reload (and later re-save) what the test taught it.
PHRASES="$HOME/Library/Application Support/Cotabby/personal_phrases.json"
JOURNAL="$HOME/Library/Application Support/Cotabby/correction-journal.jsonl"
TRAINING="$HOME/Library/Application Support/Cotabby/training-log.jsonl"
# The writer's learned words too: a test that keeps a misspelling (`teh`, `Tyoda`) teaches it as one
# of their own words, and it stayed in their file after the run.
WORDS="$HOME/Library/Application Support/Cotabby/personal_words.json"
[ -f "$WORDS" ] && cp "$WORDS" "$SNAPSHOT.words"
[ -f "$PHRASES" ] && cp "$PHRASES" "$SNAPSHOT.phrases"
[ -f "$JOURNAL" ] && cp "$JOURNAL" "$SNAPSHOT.journal"
[ -f "$TRAINING" ] && cp "$TRAINING" "$SNAPSHOT.training"
restore_file() { # live, snapshot
  if [ -f "$2" ]; then cp "$2" "$1"; elif [ -f "$1" ]; then mv "$1" ~/.Trash/; fi
}
restore_history() {
  pkill -f "Cotabby Dev.app/Contents/MacOS"; sleep 1.5
  for key in cotabbyPersonalCorrections cotabbyKeptWords cotabbyLowPowerModeAutoDisableEnabled cotabbyQualityMetricsCounters cotabbyGloballyEnabled cotabbyTrainingLogEnabled; do
    defaults delete "$DOMAIN" "$key" 2>/dev/null
    /usr/libexec/PlistBuddy -x -c "Print :$key" "$SNAPSHOT" > "$SNAPSHOT.$key" 2>/dev/null \
      && defaults write "$DOMAIN" "$key" "$(sed -n '/<plist/,/<\/plist>/p' "$SNAPSHOT.$key")"
  done
  restore_file "$PHRASES" "$SNAPSHOT.phrases"
  restore_file "$WORDS" "$SNAPSHOT.words"
  restore_file "$JOURNAL" "$SNAPSHOT.journal"
  restore_file "$TRAINING" "$SNAPSHOT.training"
  open "/Applications/Cotabby Dev.app"
  if [ "$OTHER_COTABBY" = 1 ] && ! pgrep -x Cotabby >/dev/null; then open -g -j /Applications/Cotabby.app; fi
}
# Armed before anything of the writer's is changed: a run stopped during the launch below used to
# leave the app in test mode, the training switch on and the released Cotabby quit, because the
# clean-up was only set up after the launch.
STREAM=""
trap '[ -n "$STREAM" ] && kill "$STREAM" 2>/dev/null; pkill -x "$HOST" 2>/dev/null; restore_history' EXIT
if pgrep -x Cotabby >/dev/null; then
  if [ "${E2E_PAUSE_OTHER:-0}" = 1 ]; then
    OTHER_COTABBY=1; pkill -x Cotabby; sleep 1
  else
    echo "WARN  the released Cotabby app is also running and may type into the test window (E2E_PAUSE_OTHER=1 pauses it for the run)"
  fi
fi
pkill -f "Cotabby Dev.app/Contents/MacOS"; sleep 1
# The training record is opt-in; the test switches it on for its own run only (the writer's switch
# and file are restored afterwards) and starts from an empty file so it checks only what it typed.
if [ "${E2E_ONLY:-}" = training ]; then
  defaults write "$DOMAIN" cotabbyTrainingLogEnabled -bool true
  [ -f "$TRAINING" ] && mv "$TRAINING" "$HOME/.Trash/training-log-e2e-$(date +%s).jsonl"
fi
if [ "${E2E_FORCE_GENERATION:-0}" = 1 ]; then defaults write "$DOMAIN" cotabbyLowPowerModeAutoDisableEnabled -bool false; fi
LOG=$(mktemp -t cotabby-e2e)
log stream --level debug --predicate 'process == "Cotabby Dev" && subsystem BEGINSWITH "com.cotabby"' --style compact > "$LOG" 2>&1 &
STREAM=$!
sleep 0.6
if [ "${E2E_ONLY:-}" = speed ] || [ -n "${E2E_NO_OVERLAY:-}" ]; then
  # Timing run (E2E_NO_OVERLAY=1 gives any other mode the same launch): the debug flag also draws a developer overlay on every keystroke, which costs more
  # main-thread time than the whole spelling pipeline. Trace logging alone gives the timeline.
  open --env COTABBY_LOG_LEVEL=trace "/Applications/Cotabby Dev.app" --args -cotabby-e2e-commands "$KEYS"
else
  open ${E2E_APP_ENV:+--env "$E2E_APP_ENV"} "/Applications/Cotabby Dev.app" --args -cotabby-debug true -cotabby-e2e-commands "$KEYS"
fi
pkill -x "$HOST" 2>/dev/null
open -n "$HOST_APP"
# Ready when the app says its services are up and both language models have loaded, or after 14 s
# (what this used to wait every time; a Mac without those models never logs the lines). With the
# models already in the file cache this is three or four seconds.
ready_waited=0
while [ $ready_waited -lt 140 ]; do
  if grep -q "All services started" "$LOG" && grep -q "Sentence model: loaded" "$LOG" \
    && grep -Eq "Word language model: loaded|Word language model: no model" "$LOG"; then break; fi
  sleep 0.1; ready_waited=$((ready_waited + 1))
done
sleep 1.0

pass=0; fail=0
host_command() { echo "$1" >> "$HOST_FILES/host-commands.txt"; sleep 0.1; }
# Brings the test host to the front and waits until macOS reports it there (the key driver refuses
# to type into anything else).
focus_doc() {
  local tries=0
  open "$HOST_APP"
  while [ $tries -lt 40 ] && ! lsappinfo info -only bundleid "$(lsappinfo front)" | grep -q "com.cotabby.e2e-host"; do
    sleep 0.1; tries=$((tries + 1))
    if [ $((tries % 10)) -eq 0 ]; then open "$HOST_APP"; fi
  done
  sleep 0.15
}
doc() { cat "$HOST_FILES/doc.txt"; }
# Hands one command to the key driver inside Cotabby Dev and waits for its answer. The driver
# refuses to type unless the test host is in front, so a person using the Mac is never typed over.
send() {
  local before; before=$(wc -l < "$KEYS.ack")
  printf '%s\n' "$1" >> "$KEYS"
  local waited=0
  while [ "$(wc -l < "$KEYS.ack")" -le "$before" ]; do
    sleep 0.02; waited=$((waited + 1))
    if [ $waited -gt 1500 ]; then echo "SKIP  the key driver did not answer (is this build of Cotabby Dev running?)"; exit 2; fi
  done
  if tail -n 1 "$KEYS.ack" | grep -q "^refused"; then
    echo "SKIP  another app came to the front ($(tail -n 1 "$KEYS.ack")) after $pass passed, $fail failed"; exit 2
  fi
}
# Clears the field the way a person would (Select All, Delete), so Cotabby sees real keystrokes.
clear_doc() {
  if screen_locked; then echo "SKIP  screen locked mid-run after $pass passed, $fail failed"; exit 2; fi
  focus_doc
  host_command focus-text
  send "$(printf 'key\t0\tcmd')"; send "$(printf 'key\t51')"
  sleep 1.2
}
# Types word by word with a short pause after each space, like a person, so per-word features
# (capitalization, word-level fixes) get a chance to run at every boundary.
type_text() {
  local rest="$1" word
  while [ -n "$rest" ]; do
    if screen_locked; then echo "SKIP  screen locked mid-run after $pass passed, $fail failed"; exit 2; fi
    if [[ "$rest" == *" "* ]]; then word="${rest%% *} "; rest="${rest#* }"; else word="$rest"; rest=""; fi
    send "$(printf 'type\t%s' "$word")"
    sleep 0.35
  done
}
press() { send "$(printf 'key\t%s' "$1")"; }
press_option() { send "$(printf 'key\t%s\toption' "$1")"; }
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1: expected [$2] got [$3]"; fail=$((fail+1)); fi
}
log_has() { grep -q "$1" "$LOG"; }
# `log stream` owns the file offset, so markers are line counts rather than written lines.
MARK=0
mark() { MARK=$(wc -l < "$LOG"); }
since_mark() { tail -n +"$((MARK + 1))" "$LOG"; }

# Waits until the document reads as expected, for at most the given tenths of a second. A fix lands
# within tens of milliseconds, so a fixed pause was mostly waiting; a slow Mac gets longer than the
# old pause, a fast one moves on at once.
wait_doc() { # expected text, tenths of a second to wait at most
  local tenths=0
  while [ "$(doc)" != "$1" ] && [ $tenths -lt "${2:-30}" ]; do sleep 0.1; tenths=$((tenths + 1)); done
}
case_type() { # name, text to type, expected document text
  clear_doc; mark "$1"; type_text "$2"
  # "Nothing may change" can only be shown by giving a change time to happen.
  if [ "$2" = "$3" ]; then sleep 1.5; else wait_doc "$3" 30; sleep 0.3; fi
  check "$1" "$3" "$(doc)"
}


# Next-word strip: Tab types word 1 (and predicts the next), Option+digit types that slot, and
# Return always reaches the app as a new line.
# The strip's words for a text, from the same engine and resources the app uses (the CLI). Used
# where the word does not depend on the writer (a word begun after a slash, and whether the tool is
# there at all); the key checks read the words off the strip itself (`strip_shown`).
SPELL_CLI="${COTABBY_SPELL:-$REPO_ROOT/build/DerivedData/Build/Products/Release/cotabby-spell}"
# The language model the app orders the strip with: the same choice as
# `WordLanguageModelService.defaultModelURL` (best installed ghost-text model that fits in memory,
# otherwise the sentence model's file), so the CLI below predicts what the app shows.
STRIP_LM=""
RUNTIME_MODELS="$HOME/Library/Application Support/Cotabby Dev/LlamaRuntime"
SENTENCE_MODEL_FILE="spelling-qwen3-0.6b-q8_0.gguf"
if [ -f "$RUNTIME_MODELS/gemma-4-E2B.i1-Q6_K.gguf" ] && [ "$(sysctl -n hw.memsize)" -ge $((16 * 1024 * 1024 * 1024)) ]; then
  STRIP_LM="$RUNTIME_MODELS/gemma-4-E2B.i1-Q6_K.gguf"
elif [ -f "$RUNTIME_MODELS/Qwen3.5-2B-Base.i1-Q4_K_M.gguf" ] && [ "$(sysctl -n hw.memsize)" -ge $((12 * 1024 * 1024 * 1024)) ]; then
  STRIP_LM="$RUNTIME_MODELS/Qwen3.5-2B-Base.i1-Q4_K_M.gguf"
elif [ -f "$RUNTIME_MODELS/Qwen3.5-0.8B-Base.i1-Q6_K.gguf" ]; then
  STRIP_LM="$RUNTIME_MODELS/Qwen3.5-0.8B-Base.i1-Q6_K.gguf"
elif [ -f "$HOME/Library/Application Support/Cotabby Dev/SentenceModel/$SENTENCE_MODEL_FILE" ]; then
  STRIP_LM="$HOME/Library/Application Support/Cotabby Dev/SentenceModel/$SENTENCE_MODEL_FILE"
elif [ -f "/Applications/Cotabby Dev.app/Contents/Resources/$SENTENCE_MODEL_FILE" ]; then
  STRIP_LM="/Applications/Cotabby Dev.app/Contents/Resources/$SENTENCE_MODEL_FILE"
fi
# Every text the cases below ask the tool about, fixed in advance. They are answered by ONE run of
# the tool the first time any of them is asked for: each run loads the language model, and a run
# per question cost the suite about half a minute.
STRIP_TEXTS=(
  "I would like " "Yesterday we walk" "She is still walk" "He has already finish" "Every morning she walk"
  "Last week I bou" "They were eat" "It is read/wri"
)
STRIP_CACHE=$(mktemp -d -t cotabby-strip)
strip_key() { printf '%s' "$1" | md5; }
strip_words_of() { sed -E 's/.*→ +//; s/ +\[.*//'; }
strip_line() { # text: the tool's word list for it
  local key text arguments=() index=0
  key=$(strip_key "$1")
  if [ ! -f "$STRIP_CACHE/$key" ]; then
    if [ ! -f "$STRIP_CACHE/asked" ] && printf '%s\n' "${STRIP_TEXTS[@]}" | grep -qxF -- "$1"; then
      : > "$STRIP_CACHE/asked"
      for text in "${STRIP_TEXTS[@]}"; do arguments+=(--predict "$text|"); done
      (cd "$REPO_ROOT" && "$SPELL_CLI" "${arguments[@]}" ${STRIP_LM:+--lm "$STRIP_LM"}) 2>/dev/null | grep -F "→" > "$STRIP_CACHE/all"
      for text in "${STRIP_TEXTS[@]}"; do
        index=$((index + 1))
        sed -n "${index}p" "$STRIP_CACHE/all" | strip_words_of > "$STRIP_CACHE/$(strip_key "$text")"
      done
    fi
    # A text that is only known once an earlier answer is (the word after the first pick).
    [ -f "$STRIP_CACHE/$key" ] || (cd "$REPO_ROOT" && "$SPELL_CLI" --predict "$1|" ${STRIP_LM:+--lm "$STRIP_LM"}) 2>/dev/null \
      | head -n 1 | strip_words_of > "$STRIP_CACHE/$key"
  fi
  cat "$STRIP_CACHE/$key"
}
strip_word() { # text, slot (1-based)
  strip_line "$1" | awk -F ' · ' -v slot="$2" '{ print $slot }'
}

# The words on the strip now, from the app's own trace of the last strip it drew since `mark`.
# The key checks below use these and not the tool's prediction: the strip learns the writer (their
# counted phrases, and the sentences this run typed a moment ago), and the tool knows neither, so
# its words stopped being the app's the day the strip started learning.
strip_shown() { # slot (1-based)
  since_mark | grep -F "Word strip words: " | tail -n 1 | sed -E 's/.*Word strip words: //' \
    | awk -F ' · ' -v slot="$1" '{ print $slot }'
}

predict_cases() {
  local first second third after_first
  clear_doc; mark; type_text "I would like "; sleep 1.2
  first=$(strip_shown 1)
  if [ -z "$first" ]; then
    echo "FAIL  strip: no words were shown after [I would like ]"; fail=$((fail+1)); return
  fi
  mark; press 48; sleep 1.0
  check "strip: Tab types the top word" "I would like $first " "$(doc)"
  after_first=$(strip_shown 1)
  press 48; sleep 1.0
  check "strip: Tab again builds the sentence" "I would like $first $after_first " "$(doc)"
  clear_doc; mark; type_text "I would like "; sleep 1.2
  third=$(strip_shown 3)
  press_option 20; sleep 1.0
  check "strip: Option-3 types the third word" "I would like $third " "$(doc)"
  clear_doc; type_text "Can you send me the rep"; sleep 1.2
  press 48; sleep 1.0
  check "strip: Tab completes a partial word" "Can you send me the report " "$(doc)"
  clear_doc; mark; type_text "I would like "; sleep 1.2
  second=$(strip_shown 2)
  press_option 19; sleep 1.0
  check "strip: Option-2 picks the second word" "I would like $second " "$(doc)"
  # Arrow keys: Right steps along the strip (the caret is at the end of the line, so it has nowhere
  # to go), Left steps back, and Return or Tab types the highlighted word.
  clear_doc; mark; type_text "I would like "; sleep 1.2
  second=$(strip_shown 2)
  press 124; sleep 0.3; press 36; sleep 1.0
  check "strip: Right then Return types the second word" "I would like $second " "$(doc)"
  clear_doc; mark; type_text "I would like "; sleep 1.2
  second=$(strip_shown 2)
  press 124; sleep 0.3; press 124; sleep 0.3; press 123; sleep 0.3; press 48; sleep 1.0
  check "strip: Right, Right, Left then Tab types the second word" "I would like $second " "$(doc)"
  clear_doc; type_text "See you soon "; sleep 1.2
  press 36; sleep 0.6; type_text "Bye"; sleep 1.0
  check "strip: Return is always a new line" "See you soon "$'\n'"Bye" "$(doc)"
  clear_doc; type_text "See you "; sleep 1.2
  press 48; sleep 0.8; type_text "."; sleep 1.0
  check "strip: a period after a pick sits against the word" "$(printf 'See you %s. ' "$(doc | sed -E 's/^See you ([a-z]+).*/\1/')")" "$(doc)"
  clear_doc; mark; type_text "I would like "; sleep 1.2
  first=$(strip_shown 1)
  press 48; sleep 0.6; press 49; sleep 1.0
  check "strip: Space right after a pick adds no second space" "I would like $first " "$(doc)"
  clear_doc; type_text "It is necc"; sleep 1.2
  press 48; sleep 1.0
  check "strip: a misspelled start still offers the word" "It is necessary " "$(doc)"
  # One-line field: Tab keeps moving focus instead of typing a word.
  host_command focus-field; sleep 0.4
  type_text "I would like "; sleep 1.2
  press 48; sleep 1.0
  check "strip: Tab in a one-line field moves focus, types nothing" "I would like " \
    "$(cat "$HOST_FILES/field.txt")"
  host_command clear-field
}

# Self-learning: undoing an auto-fix (deleting it and retyping the word) sticks, and the same word is
# left alone afterwards. The writer's kept-word list is restored when the run ends.
learn_cases() {
  clear_doc; type_text "I saw teh "; sleep 1.5
  check "learn: teh is auto-fixed" "I saw the " "$(doc)"
  for _ in 1 2 3 4; do press 51; sleep 0.1; done
  type_text "teh "; sleep 1.5
  check "learn: retyping the original keeps it" "I saw teh " "$(doc)"
  clear_doc; type_text "we like teh "; sleep 1.5
  check "learn: the kept word is not fixed again" "We like teh " "$(doc)"
  # The same undo with a torn read of the field in the middle of it: a Backspace that lands between
  # Cotabby's read of the selection and its read of the text makes the caret seem to lie past the
  # end. Taken at its word that ended the focus session and the watch on the fix with it, so the
  # undo taught nothing and the word was fixed again. The host serves one such read on request
  # (`tear-read`); the app must read the field again, and the undo must count as before.
  clear_doc; mark; type_text "it broke becuase "; sleep 1.5
  check "learn: becuase is auto-fixed" "It broke because " "$(doc)"
  host_command tear-read; sleep 0.5
  for _ in 1 2 3 4 5 6 7 8; do press 51; sleep 0.1; done
  type_text "becuase "; sleep 1.5
  check "learn: an undo is kept across a torn read of the field" "It broke becuase " "$(doc)"
  check "learn: the torn read was read again" "1" "$(since_mark | grep -c "Torn read")"
  check "learn: the torn read ended no focus session" "0" "$(since_mark | grep -c "detail=Selection range exceeds")"
  clear_doc; type_text "the monkee "; sleep 1.5
  press 53; sleep 0.3
  for _ in 1 2 3 4 5 6 7; do press 51; sleep 0.08; done
  type_text "monkey "; sleep 1.5
  check "learn: retyping a word yourself keeps your fix" "The monkey " "$(doc)"
  if grep -q '"typed":"monkee"' "$JOURNAL" 2>/dev/null && grep -q selfCorrected "$JOURNAL"; then
    echo "PASS  learn: the self-correction is in the journal"; pass=$((pass+1))
  else
    echo "FAIL  learn: no selfCorrected monkee entry in the journal"; fail=$((fail+1))
  fi
}

# Speed, from the app's own clock: the key that finished the word → the fix handed to the host
# (or the bar shown). Includes the wait for the host to publish the keystroke.
latency() { # label, step name in the app's typing timeline
  grep -E "typing \+[0-9]+ ms: $2" "$LOG" | sed -E 's/.*typing \+([0-9]+) ms.*/\1/' | sort -n | awk -v label="$1" '
    { v[NR] = $1 } END { if (NR) printf "TIME  %s: median %d ms, 90%% within %d ms, slowest %d ms (%d samples)\n",
      label, v[int((NR + 1) / 2)], v[int(NR * 0.9 + 0.5)], v[NR], NR }'
}
report_latency() {
  latency "key to automatic fix" "fix typed"
  latency "key to spelling bar" "bar shown"
}

if [ "${E2E_ONLY:-}" = speed ]; then
  send "$(printf 'pace\t%s' "${E2E_PACE:-45}")"
  # E2E_SAMPLE=<file>: also record where Cotabby Dev's threads spend the run (1 ms stack samples).
  if [ -n "${E2E_SAMPLE:-}" ]; then sample "Cotabby Dev" 40 1 -file "$E2E_SAMPLE" > /dev/null 2>&1 & fi
  for line in "it broke becuase " "I think teh " "we went to teh store and it was definately closed " \
      "my freind said she recieved it yesterday " "tomorow we will go untill it is dark " \
      "I beleive that thier house is diffrent " "we realy want to acheive somthing " \
      "she was suprised by the wierd noise " "it is neccessary to seperate them " "wich one do you want "; do
    clear_doc; type_text "$line"; sleep 0.8
    echo "TYPED $line→ $(doc)"
  done
  report_latency
  # Where the time went for each automatic fix: the app's own timeline since the finishing key.
  grep -E "typing \+[0-9]+ ms" "$LOG" | sed -E 's/^.*typing \+//' \
    | awk '/host published/ { line = "" } { line = line " | " $0 } /fix typed/ { print "STEPS" line; line = "" }'
  echo "$pass passed, $fail failed  (log: $LOG)"; exit 0
fi

# E2E_ONLY=shot E2E_SHOT=<file.png>: type a line, move the strip's highlight with Right, and save
# a picture of the screen for a visual check (needs Screen Recording for whatever runs this).
if [ "${E2E_ONLY:-}" = shot ]; then
  clear_doc
  # E2E_HOST_LOOK=light|dark sets the test window's appearance for the picture.
  if [ -n "${E2E_HOST_LOOK:-}" ]; then host_command "$E2E_HOST_LOOK"; sleep 0.5; fi
  # E2E_SHOT_TEXT=<text> shows whatever that text brings up (a misspelling for the spelling bar)
  # instead of the word strip. E2E_HOLD=<seconds> keeps it on screen first, for a picture taken by
  # another tool when this shell is not allowed to capture the screen.
  if [ -n "${E2E_SHOT_TEXT:-}" ]; then
    type_text "$E2E_SHOT_TEXT"; sleep 1.2
  else
    type_text "I would like "; sleep 1.2
    press 124; sleep 0.6
  fi
  # E2E_SHOT_KEY="<key code><TAB><modifiers>" presses one more key just before the picture, e.g.
  # $'8\tctrl,option' for the on/off notice (press it twice in a row with E2E_SHOT_KEY_TWICE=1).
  if [ -n "${E2E_SHOT_KEY:-}" ]; then
    send "$(printf 'key\t%s' "$E2E_SHOT_KEY")"; sleep 0.4
    if [ -n "${E2E_SHOT_KEY_TWICE:-}" ]; then sleep 2.2; send "$(printf 'key\t%s' "$E2E_SHOT_KEY")"; sleep 0.4; fi
  fi
  sleep "${E2E_HOLD:-0}"
  # The app takes the picture (it holds the Screen Recording grant); the shell's own attempt is the
  # fallback for a build without that command.
  send "shot	${E2E_SHOT:-/tmp/cotabby-strip.png}"; sleep 0.5
  [ -s "${E2E_SHOT:-/tmp/cotabby-strip.png}" ] || screencapture -x "${E2E_SHOT:-/tmp/cotabby-strip.png}"
  echo "SHOT  ${E2E_SHOT:-/tmp/cotabby-strip.png}"; exit 0
fi

# The sentence model (only when its file is installed): a finished sentence is reread by the model
# and the words it is sure of are retyped in place. The word-level check only offers a bar for these
# (a capitalized unknown word is never fixed unasked), so what lands in the document is the model's.
SENTENCE_MODEL="$HOME/Library/Application Support/Cotabby Dev/SentenceModel/spelling-qwen3-0.6b-q8_0.gguf"
model_cases() {
  if [ ! -f "$SENTENCE_MODEL" ] && [ ! -f "/Applications/Cotabby Dev.app/Contents/Resources/$(basename "$SENTENCE_MODEL")" ]; then
    echo "INFO  sentence model not installed; its cases are skipped"; return
  fi
  mark model
  case_type "sentence model: misspelled names" "I drive a Tyoda Corola to work. " "I drive a Toyota Corolla to work. "
  # A fix the model is less sure of is offered on the review card instead; Tab takes it.
  clear_doc; type_text "We deployed the Kubernetis cluster on Tuesday. "; sleep 1.5
  if [ "$(doc)" != "We deployed the Kubernetes cluster on Tuesday. " ]; then press 48; sleep 1.2; fi
  check "sentence model: technical term, applied or offered" "We deployed the Kubernetes cluster on Tuesday. " "$(doc)"
  case_type "sentence model: place name" "She studied at the Massachusets Institute of Technology. " "She studied at the Massachusetts Institute of Technology. "
  case_type "sentence model: correct names untouched" "Nguyen and Okafor reviewed the Kubernetes manifests. " "Nguyen and Okafor reviewed the Kubernetes manifests. "
  case_type "sentence model: correct sentence untouched" "The meeting starts at noon on Friday. " "The meeting starts at noon on Friday. "
  # How long the model took for each sentence it fixed, from the app's own log.
  grep -oE "Sentence model: fixes to type.*\(([0-9]+) ms\)" "$LOG" | grep -oE "[0-9]+ ms" | tr '\n' ' ' | sed 's/^/TIME  sentence model, finished sentence to fix decided: /; s/$/\n/'
}

# The on/off shortcut (Control+Option+C unless the writer rebound it, in which case this is skipped):
# off leaves a misspelling alone and takes down a spelling bar that was up, on brings fixes back.
toggle_cases() {
  if [ "$(defaults read "$DOMAIN" cotabbyGlobalToggleKeyChosen 2>/dev/null)" = 1 ] \
    && [ "$(defaults read "$DOMAIN" cotabbyGlobalToggleKeyCode 2>/dev/null):$(defaults read "$DOMAIN" cotabbyGlobalToggleKeyModifiers 2>/dev/null)" != "8:12" ]; then
    echo "INFO  the toggle shortcut was changed from its default; its cases are skipped"; return
  fi
  local toggle; toggle="$(printf 'key\t8\tctrl,option')"
  clear_doc; type_text "I have a questoi"; sleep 1.0
  mark toggle; send "$toggle"; sleep 0.8
  if since_mark | grep -q "Toggle tap consumed"; then
    echo "PASS  toggle: the shortcut reached Cotabby"; pass=$((pass+1))
  else echo "FAIL  toggle: no sign of the shortcut in the log"; fail=$((fail+1)); fi
  check "toggle: the shortcut itself types nothing" "I have a questoi" "$(doc)"
  # Not `teh`: the learning cases above keep it on purpose, and a kept word is left alone by every
  # stage from then on, the sentence model included.
  case_type "toggle: off leaves a misspelling alone" "Did you recieve it. " "Did you recieve it. "
  send "$toggle"; sleep 2.0
  # What was written with Cotabby off stays as written when it comes back on. (It used to be
  # "fixed" at that instant, by an edit whose deletes were lost: `recieve it. eive it. `.)
  check "toggle: switching back on leaves what was typed while off" "Did you recieve it. " "$(doc)"
  case_type "toggle: on fixes it again" "Did you recieve mine. " "Did you receive mine. "
}

# Tense in the word strip: with the letters that several forms of a verb share typed, Tab takes
# the form the sentence calls for. Needs the language model; each case is only required when the
# engine (the CLI, same model) also puts that form first, so a weaker installed model reports
# what it prefers instead of failing.
tense_case() { # typed text, the form expected first, the document after Tab
  local preferred; preferred=$(strip_word "$1" 1)
  if [ "$preferred" != "$2" ]; then echo "INFO  tense: after [$1] this model prefers [$preferred], not [$2]"; return; fi
  clear_doc; type_text "$1"; sleep 1.4
  press 48; sleep 1.0
  check "tense: [$1] + Tab types [$2]" "$3" "$(doc)"
}
tense_cases() {
  if [ -z "$STRIP_LM" ] || [ -z "$(strip_word "I would like " 1)" ]; then
    echo "INFO  tense checks skipped: no language model or no cotabby-spell CLI"; return
  fi
  tense_case "Yesterday we walk" "walked" "Yesterday we walked "
  tense_case "She is still walk" "walking" "She is still walking "
  tense_case "He has already finish" "finished" "He has already finished "
  tense_case "Every morning she walk" "walks" "Every morning she walks "
  tense_case "Last week I bou" "bought" "Last week I bought "
  tense_case "They were eat" "eating" "They were eating "
  # How long the model took, from the app's own log.
  grep -oE "Word language model: (answer|refinement|look-ahead|ready ahead) in [0-9.]+ ms" "$LOG" | sed 's/ready ahead/ready-ahead/' | awk '{ print $4, $6 }' | sort -k1,1 -k2,2n \
    | awk '{ n[$1]++; v[$1, n[$1]] = $2 } END { for (k in n) printf "TIME  word language model, %s: median %.1f ms over %d\n", k, v[k, int((n[k] + 1) / 2)], n[k] }'
}

# Typing straight on into the next sentence, without the per-word pauses: the model's fix either
# lands whole or is dropped, and what the writer typed after the sentence is never damaged.
# E2E_ONLY=flow E2E_PACE=<ms per key>
flow_case() { # name, text typed in one go, text when the fix landed, text when it was dropped
  clear_doc
  send "$(printf 'pace\t%s' "${E2E_PACE:-120}")"; send "$(printf 'type\t%s' "$2")"; send "$(printf 'pace\t45')"
  sleep 2
  local got; got="$(doc)"
  if [ "$got" = "$3" ]; then echo "PASS  $1 (fix landed)"; pass=$((pass+1))
  elif [ "$got" = "$4" ]; then echo "PASS  $1 (fix dropped, text intact)"; pass=$((pass+1))
  else echo "FAIL  $1: got [$got]"; fail=$((fail+1)); fi
}
flow_cases() {
  if [ ! -f "$SENTENCE_MODEL" ]; then echo "INFO  sentence model not installed; its cases are skipped"; return; fi
  # A different sentence every round: typing the same misspelled sentence again looks like the
  # writer undoing the fix, after which it is left alone on purpose.
  local typed=("I drive a Tyoda Corola to work. It is fast and cheap to run. "
               "She studied at the Massachusets Institute. Then she moved to Boston. "
               "My sister bought a Tyoda last week. She likes it a lot. "
               "We flew to Massachusets in the spring. The weather was mild. "
               "He sold the old Corola to a friend. Nobody was surprised. "
               "They opened an office in Massachusets today. Everyone was there. ")
  local fixed=("I drive a Toyota Corolla to work. It is fast and cheap to run. "
               "She studied at the Massachusetts Institute. Then she moved to Boston. "
               "My sister bought a Toyota last week. She likes it a lot. "
               "We flew to Massachusetts in the spring. The weather was mild. "
               "He sold the old Corolla to a friend. Nobody was surprised. "
               "They opened an office in Massachusetts today. Everyone was there. ")
  local index
  for index in "${!typed[@]}"; do
    flow_case "typing on past sentence $((index + 1)), ${E2E_PACE:-120} ms a key" "${typed[$index]}" "${fixed[$index]}" "${typed[$index]}"
  done
}

if [ "${E2E_ONLY:-}" = flow ]; then
  flow_cases
  echo "$pass passed, $fail failed  (log: $LOG)"; [ $fail -eq 0 ]; exit
fi

# E2E_ONLY=settings E2E_SETTING=<SettingsItem id> E2E_SHOT=<file.png>
if [ "${E2E_ONLY:-}" = settings ]; then
  send "$(printf 'settings\t%s\t%s\t%s' "${E2E_SETTING:-trainingData}" "${E2E_SHOT:-/tmp/cotabby-settings.png}" "${E2E_SETTINGS_HEIGHT:-}")"
  sleep 1; echo "SHOT  ${E2E_SHOT:-/tmp/cotabby-settings.png}  (log: $LOG)"; exit 0
fi

# The training record, switched on for this run: a finished sentence and the fix made in it are
# written to the file, and nothing is written about a sentence typed while Cotabby is off.
training_cases() {
  clear_doc; type_text "I saw teh cat today. "; sleep 2.5
  if grep -q '"event":"sentence".*"text":"I saw the cat today."' "$TRAINING" 2>/dev/null; then
    echo "PASS  training: the finished sentence is saved"; pass=$((pass+1))
  else echo "FAIL  training: sentence not in the file: $(cat "$TRAINING" 2>/dev/null)"; fail=$((fail+1)); fi
  clear_doc; type_text "It was a nice day. "; sleep 2.0
  if grep -q '"final":"the".*"typed":"teh"' "$TRAINING" 2>/dev/null; then
    echo "PASS  training: the kept fix is saved with what was typed"; pass=$((pass+1))
  else echo "FAIL  training: fix not in the file: $(cat "$TRAINING" 2>/dev/null)"; fail=$((fail+1)); fi
  # A sentence the sentence model fixes: the fix is saved with both whole sentences, and the
  # sentence that is saved is the corrected one, character for character (the export joins on it).
  clear_doc; type_text "I drive a Tyoda Corola to work. "; sleep 2.0; type_text "It runs well. "; sleep 2.0
  if grep -q '"corrected":"I drive a Toyota Corolla to work.".*"kept":true.*"original":"I drive a Tyoda Corola to work."' "$TRAINING" 2>/dev/null \
    && grep -q '"event":"sentence".*"text":"I drive a Toyota Corolla to work."' "$TRAINING"; then
    echo "PASS  training: a kept sentence fix is saved with the sentence before and after"; pass=$((pass+1))
  else echo "FAIL  training: sentence fix not in the file: $(cat "$TRAINING" 2>/dev/null)"; fail=$((fail+1)); fi
  # The record of how it got there: which build wrote it, what the engine decided about the word
  # before the writer reacted, what the strip showed for the words, what the sentence model made of
  # each word it changed, and where each line stood in the launch.
  if head -1 "$TRAINING" | grep -q '"event":"session".*"version":"'; then
    echo "PASS  training: the first line says which build and models wrote the rest"; pass=$((pass+1))
  else echo "FAIL  training: no session line first: $(head -1 "$TRAINING" 2>/dev/null)"; fail=$((fail+1)); fi
  if grep -q '"action":"fixed".*"candidates":\[{[^]]*"term":"the".*"event":"decision".*"typed":"teh"' "$TRAINING" 2>/dev/null; then
    echo "PASS  training: the engine's decision is saved with its candidates"; pass=$((pass+1))
  else echo "FAIL  training: no decision line for teh: $(grep decision "$TRAINING" 2>/dev/null)"; fail=$((fail+1)); fi
  if grep -q '"event":"strip".*"last":\["' "$TRAINING" 2>/dev/null; then
    echo "PASS  training: what the strip showed for a word is saved"; pass=$((pass+1))
  else echo "FAIL  training: no strip line: $(cat "$TRAINING" 2>/dev/null)"; fail=$((fail+1)); fi
  if grep -q '"event":"sentencePass".*"text":"I drive a Tyoda Corola to work.".*"action":"fixed".*"typed":"Tyoda".*"written":"Toyota"' "$TRAINING" 2>/dev/null; then
    echo "PASS  training: the sentence model's confidence in each changed word is saved"; pass=$((pass+1))
  else echo "FAIL  training: no sentence pass line: $(grep sentencePass "$TRAINING" 2>/dev/null)"; fail=$((fail+1)); fi
  if [ "$(grep -c '"ms":[0-9]*,"n":[0-9]*' "$TRAINING")" = "$(wc -l < "$TRAINING" | tr -d ' ')" ]; then
    echo "PASS  training: every line has its place and time within the launch"; pass=$((pass+1))
  else echo "FAIL  training: a line without a stamp: $(grep -v '"ms":' "$TRAINING" 2>/dev/null)"; fail=$((fail+1)); fi
  if grep -Eq '"(time|date|timestamp)":' "$TRAINING" 2>/dev/null; then
    echo "FAIL  training: a clock time was saved"; fail=$((fail+1))
  else echo "PASS  training: no clock time is saved"; pass=$((pass+1)); fi
  send "$(printf 'key\t8\tctrl,option')"; sleep 0.8
  clear_doc; type_text "This one stays private. "; sleep 2.5
  send "$(printf 'key\t8\tctrl,option')"; sleep 0.8
  if grep -q "stays private" "$TRAINING" 2>/dev/null; then
    echo "FAIL  training: a sentence typed while Cotabby was off was saved"; fail=$((fail+1))
  else echo "PASS  training: nothing is saved while Cotabby is off"; pass=$((pass+1)); fi
  echo "INFO  training log: $(wc -l < "$TRAINING" | tr -d ' ') lines"
}

if [ "${E2E_ONLY:-}" = training ]; then
  training_cases
  cp "$TRAINING" "${E2E_TRAINING_COPY:-/dev/null}" 2>/dev/null
  if [ -n "${E2E_SHOT:-}" ]; then
    send "$(printf 'settings\ttrainingData\t%s\t%s' "$E2E_SHOT" "${E2E_SETTINGS_HEIGHT:-}")"; echo "SHOT  $E2E_SHOT"
  fi
  echo "$pass passed, $fail failed  (log: $LOG)"; [ $fail -eq 0 ]; exit
fi

# E2E_ONLY=fieldprobe: the one-line-field Tab case several times with Cotabby Dev off, then on. A
# word that appears while it is off was typed by something else (another typing assistant, or
# macOS), which is how a failing strip check is told apart from a real one.
if [ "${E2E_ONLY:-}" = fieldprobe ]; then
  for state in off on; do
    clear_doc
    if [ "$state" = off ]; then send "$(printf 'key\t8\tctrl,option')"; sleep 0.8; fi
    for round in 1 2 3 4 5; do
      host_command focus-field; sleep 0.4
      type_text "I would like "; sleep 1.2
      press 48; sleep 1.0
      echo "PROBE  Cotabby $state, round $round: [$(cat "$HOST_FILES/field.txt")]"
      host_command clear-field; sleep 0.3
    done
    if [ "$state" = off ]; then focus_doc; host_command focus-text; send "$(printf 'key\t8\tctrl,option')"; sleep 0.8; fi
  done
  exit 0
fi

if [ "${E2E_ONLY:-}" = tense ]; then
  tense_cases
  echo "$pass passed, $fail failed  (log: $LOG)"; [ $fail -eq 0 ]; exit
fi

if [ "${E2E_ONLY:-}" = toggle ]; then
  toggle_cases
  echo "$pass passed, $fail failed  (log: $LOG)"; [ $fail -eq 0 ]; exit
fi

if [ "${E2E_ONLY:-}" = model ]; then
  model_cases
  echo "$pass passed, $fail failed  (log: $LOG)"; [ $fail -eq 0 ]; exit
fi

# E2E_ONLY=tornread: a Backspace can land between the app's read of the field's selection and its
# read of the text, and the selection then seems to lie past the end. The app reads such a field
# once more (`FocusSnapshotResolver.resolveSnapshot`); believed as it stood, it ended the focus
# session and with it the watch on a fix just made. This deletes a few hundred characters key by
# key and reports how often a read came back torn and whether any was still torn the second time.
if [ "${E2E_ONLY:-}" = tornread ]; then
  for _ in $(seq 1 "${E2E_ROUNDS:-4}"); do
    clear_doc; type_text "one two three four five six seven eight nine ten eleven twelve thirteen "
    for _ in $(seq 1 70); do press 51; done
  done
  sleep 0.5
  torn=$(grep -c "Torn read" "$LOG"); believed=$(grep -c "detail=Selection range exceeds" "$LOG")
  echo "INFO  reads that came back torn and were read again: $torn"
  check "torn read: none is taken for a field that went away" "0" "$believed"
  echo "$pass passed, $fail failed  (log: $LOG)"; [ $fail -eq 0 ]; exit
fi

if [ "${E2E_ONLY:-}" = learn ]; then
  learn_cases
  echo "$pass passed, $fail failed  (log: $LOG)"; [ $fail -eq 0 ]; exit
fi

if [ "${E2E_ONLY:-}" = predict ]; then
  predict_cases
  echo "$pass passed, $fail failed  (log: $LOG)"; [ $fail -eq 0 ]; exit
fi

if [ "${E2E_ONLY:-}" = review ]; then
  for attempt in 1 2 3 4 5; do
    clear_doc; type_text "Honestly I went their yesterday. "; sleep 1.5
    press 48; sleep 1.2
    check "review card attempt $attempt" "Honestly I went there yesterday. " "$(doc)"
  done
  echo "$pass passed, $fail failed  (log: $LOG)"; [ $fail -eq 0 ]; exit
fi

case_type "auto-fix transposition" "I think teh " "I think the "
case_type "auto-fix mid-sentence" "it broke becuase " "It broke because "
case_type "apostrophe repair" "I dont " "I don't "
case_type "correct text untouched" "over there " "Over there "
case_type "case preserved" "Teh " "The "

case_type "capitalize sentence starts" "hello there. how are you " "Hello there. How are you "
case_type "capitalize pronoun" "so i think " "So I think "
case_type "sentence pass: doubled word" "We went to the the store today. " "We went to the store today. "
case_type "sentence pass: comma spacing" "Hello ,world is here. " "Hello, world is here. "

clear_doc; mark review; type_text "Honestly I went their yesterday. "; sleep 1.5
press 48; sleep 1.2
check "review card: Tab applies the wrong-word fix" "Honestly I went there yesterday. " "$(doc)"

# At the caret only the words before it are known, so the case is one where they already settle it
# (`went their` could still become `went their way`; the sentence pass above covers that one).
clear_doc; mark realword; type_text "I want to go their "; sleep 1.2
if since_mark realword | grep -q "Offered [0-9]* spelling fix"; then echo "PASS  real-word bar shown"; pass=$((pass+1)); else echo "FAIL  real-word bar not shown"; fail=$((fail+1)); fi
press 48; sleep 1
check "real-word bar Tab applies" "I want to go there " "$(doc)"

clear_doc; mark keep; type_text "ask Kubernets"; sleep 1.2
press 126; sleep 0.2; press 48; sleep 1
check "keep typed word via bar" "Ask Kubernets " "$(doc)"

# Mid-word, so the bar is certain to be up (a finished `recipt` may be fixed without asking). Slot 1
# is the word as typed, slot 2 the first fix (recipe), slot 3 the second (receipt).
clear_doc; type_text "we need a recipt"; sleep 1.2
press_option 20; sleep 1.2
check "bar: Option-3 picks the third slot" "We need a receipt " "$(doc)"

clear_doc; type_text "I will meat "; sleep 1.2
press 48; sleep 1.2
check "homophone bar: meat to meet with Tab" "I will meet " "$(doc)"

# Words joined by a dot or a slash (a table name, `read/write`): the word after the mark is helped
# like any other, but nothing there is changed without asking.
clear_doc; type_text "The table name is users.nmae"; sleep 1.2
press 48; sleep 1.2
check "joined words: Tab takes the offered fix after a dot" "The table name is users.name " "$(doc)"
case_type "joined words: a slip after a dot is not changed unasked" "The table name is users.nmae and " "The table name is users.nmae and "
if [ -n "$(strip_word "It is read/wri" 1)" ]; then
  joined_first=$(strip_word "It is read/wri" 1)
  clear_doc; type_text "It is read/wri"; sleep 1.2
  press 48; sleep 1.0
  check "joined words: the strip completes a word begun after a slash" "It is read/$joined_first " "$(doc)"
fi

clear_doc; type_text "I have a questoi"; sleep 1.2
press 48; sleep 0.8; type_text "."; sleep 1.0
got=$(doc)
if [[ "$got" == *". " && "$got" != *" ." ]]; then echo "PASS  bar: a period after a mid-word pick sits against the word"; pass=$((pass+1));
else echo "FAIL  bar: period after a mid-word pick: got [$got]"; fail=$((fail+1)); fi

# Ghost text: the model may reasonably decline one prompt, so try a few and require that at least one
# produces a suggestion that Tab inserts.
ghost_result="none"
for prompt in "Thanks for the update, I will " "Can we move the meeting to " "I am writing to let you know that "; do
  clear_doc; type_text "$prompt"; sleep 3
  if tail -n 400 "$LOG" | grep -qiE "replace ghost text|low power"; then ghost_result="paused"; break; fi
  before=$(doc); press 48; sleep 1; after=$(doc)
  if [ ${#after} -gt $((${#before} + 1)) ]; then ghost_result="accepted"; break; fi
done
case "$ghost_result" in
  accepted) echo "PASS  ghost text accepted with Tab"; pass=$((pass+1)) ;;
  paused) echo "INFO  ghost text paused (word strip on, or Low Power Mode with the on-device model)" ;;
  *) echo "FAIL  no ghost text accepted in three prompts"; fail=$((fail+1)) ;;
esac

learn_cases
predict_cases
tense_cases
model_cases
toggle_cases
report_latency
echo "$pass passed, $fail failed  (log: $LOG)"
[ $fail -eq 0 ]
