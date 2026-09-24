#!/bin/bash
# Live end-to-end smoke test against the INSTALLED "Cotabby Dev". Relaunches it with debug logs,
# types into the dedicated test host (Tools/e2e/TestHost: one text view, macOS autocorrect off on
# that view only, nothing saved) with synthesized keystrokes, then checks the text and the app's
# pipeline logs. It never touches your own apps, documents, or macOS settings. Takes keyboard focus
# for about two minutes. The writer's correction history and the Low Power setting are restored.
#   E2E_FORCE_GENERATION=1  run ghost text even in Low Power Mode (to test the model path on battery)
#   E2E_ONLY=review         repeat only the review-card scenario
set -uo pipefail
DOMAIN=com.jacobfu.tabby.dev
HOST_APP=$("$(dirname "$0")/build-host.sh")
HOST=CotabbyE2EHost
# The test picks and keeps words like a writer would; snapshot the writer's history and restore it
# afterwards so a test run never teaches Cotabby anything.
SNAPSHOT=$(mktemp -t cotabby-e2e-prefs)
defaults export "$DOMAIN" "$SNAPSHOT"
restore_history() {
  pkill -f "Cotabby Dev.app/Contents/MacOS"; sleep 1
  for key in cotabbyPersonalCorrections cotabbyKeptWords cotabbyLowPowerModeAutoDisableEnabled; do
    defaults delete "$DOMAIN" "$key" 2>/dev/null
    /usr/libexec/PlistBuddy -x -c "Print :$key" "$SNAPSHOT" > "$SNAPSHOT.$key" 2>/dev/null \
      && defaults write "$DOMAIN" "$key" "$(sed -n '/<plist/,/<\/plist>/p' "$SNAPSHOT.$key")"
  done
  open "/Applications/Cotabby Dev.app"
}
pkill -f "Cotabby Dev.app/Contents/MacOS"; sleep 1
if [ "${E2E_FORCE_GENERATION:-0}" = 1 ]; then defaults write "$DOMAIN" cotabbyLowPowerModeAutoDisableEnabled -bool false; fi
open "/Applications/Cotabby Dev.app" --args -cotabby-debug true
pkill -x "$HOST" 2>/dev/null
open -n "$HOST_APP"
sleep 14
LOG=$(mktemp -t cotabby-e2e)
log stream --level debug --predicate 'process == "Cotabby Dev" && subsystem BEGINSWITH "com.cotabby"' --style compact > "$LOG" 2>&1 &
STREAM=$!
trap 'kill $STREAM 2>/dev/null; pkill -x "$HOST"; restore_history' EXIT

pass=0; fail=0
host_ax() { osascript -e "tell application \"System Events\" to tell process \"$HOST\" to $1"; }
focus_doc() { host_ax "set frontmost to true" >/dev/null; }
doc() { host_ax "get value of text area 1 of scroll area 1 of window 1"; }
# Clears the field the way a person would (Select All, Delete), so Cotabby sees real keystrokes.
clear_doc() {
  focus_doc
  osascript -e 'tell application "System Events" to keystroke "a" using command down' -e 'tell application "System Events" to key code 51'
  sleep 1.2
}
# Types word by word with a short pause after each space, like a person, so per-word features
# (capitalization, word-level fixes) get a chance to run at every boundary.
type_text() {
  focus_doc
  local rest="$1" word
  while [ -n "$rest" ]; do
    if [[ "$rest" == *" "* ]]; then word="${rest%% *} "; rest="${rest#* }"; else word="$rest"; rest=""; fi
    osascript -e "tell application \"System Events\" to keystroke \"$word\""
    sleep 0.35
  done
}
press() { osascript -e "tell application \"System Events\" to key code $1"; }
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1: expected [$2] got [$3]"; fail=$((fail+1)); fi
}
log_has() { grep -q "$1" "$LOG"; }
# `log stream` owns the file offset, so markers are line counts rather than written lines.
MARK=0
mark() { MARK=$(wc -l < "$LOG"); }
since_mark() { tail -n +"$((MARK + 1))" "$LOG"; }

case_type() { # name, text to type, expected document text after 1.5s
  clear_doc; mark "$1"; type_text "$2"; sleep 1.5
  check "$1" "$3" "$(doc)"
}

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

clear_doc; mark realword; type_text "I went their "; sleep 1.2
if since_mark realword | grep -q "Offered [0-9]* spelling fix"; then echo "PASS  real-word bar shown"; pass=$((pass+1)); else echo "FAIL  real-word bar not shown"; fail=$((fail+1)); fi
press 48; sleep 1
check "real-word bar Tab applies" "I went there " "$(doc)"

clear_doc; mark keep; type_text "ask Kubernets"; sleep 1.2
press 126; sleep 0.2; press 48; sleep 1
check "keep typed word via bar" "Ask Kubernets " "$(doc)"

# Ghost text: the model may reasonably decline one prompt, so try a few and require that at least one
# produces a suggestion that Tab inserts.
ghost_result="none"
for prompt in "Thanks for the update, I will " "Can we move the meeting to " "I am writing to let you know that "; do
  clear_doc; type_text "$prompt"; sleep 3
  if tail -n 400 "$LOG" | grep -q "low-power-paused"; then ghost_result="paused"; break; fi
  before=$(doc); press 48; sleep 1; after=$(doc)
  if [ ${#after} -gt $((${#before} + 1)) ]; then ghost_result="accepted"; break; fi
done
case "$ghost_result" in
  accepted) echo "PASS  ghost text accepted with Tab"; pass=$((pass+1)) ;;
  paused) echo "INFO  ghost text paused by Low Power Mode (on-device model)" ;;
  *) echo "FAIL  no ghost text accepted in three prompts"; fail=$((fail+1)) ;;
esac

echo "$pass passed, $fail failed  (log: $LOG)"
[ $fail -eq 0 ]
