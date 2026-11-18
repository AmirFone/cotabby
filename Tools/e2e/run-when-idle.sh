#!/bin/bash
# Runs the on-screen typing suite when nobody is using the Mac, and again if it is interrupted.
#
#   Tools/e2e/run-when-idle.sh <folder for the results>
#
# The suite (live-smoke.sh) types into its own test window for about ten minutes and gives up the
# moment another app comes to the front, so it never types into yours. Started by hand that means it
# only finishes if the Mac is left alone. This waits until the screen is unlocked and the keyboard
# and mouse have been still for IDLE_SECONDS (default 300: a shorter wait starts runs that the person then walks into), runs the full suite and the training
# cases, and when either one was cut short (someone came back, the screen locked) waits for the Mac
# to be idle again and starts that part over, up to ATTEMPTS times (default 6).
#
# It tests the installed /Applications/Cotabby Dev.app. The sentence model is taken from inside the
# app (a copy in Application Support is moved aside for the run and put back), the released Cotabby
# is paused for the run, and the suite is run from a copy made at the start, so editing the scripts
# while this waits changes nothing about the run. Results: <folder>/summary.txt, full.log,
# training.log. Exit status 0 when both parts ran to the end with no failure.
set -uo pipefail
OUT="${1:?usage: run-when-idle.sh <folder for the results>}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
IDLE_SECONDS="${IDLE_SECONDS:-300}"
ATTEMPTS="${ATTEMPTS:-6}"
MODEL="$HOME/Library/Application Support/Cotabby Dev/SentenceModel/spelling-qwen3-0.6b-q8_0.gguf"
mkdir -p "$OUT/pinned"
cp "$REPO/Tools/e2e/live-smoke.sh" "$REPO/Tools/e2e/build-host.sh" "$OUT/pinned/"
cp -R "$REPO/Tools/e2e/TestHost" "$OUT/pinned/TestHost"

locked() { ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked | grep -q "<true/>"; }
idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'; }
restore() { [ -f "$MODEL.aside" ] && mv "$MODEL.aside" "$MODEL"; }
trap restore EXIT
installed() {
  echo "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '/Applications/Cotabby Dev.app/Contents/Info.plist') $(shasum '/Applications/Cotabby Dev.app/Contents/MacOS/Cotabby Dev' | cut -c1-12)"
}
wait_for_idle() {
  local waited=0
  while locked || [ "$(idle)" -lt "$IDLE_SECONDS" ]; do
    sleep 15; waited=$((waited + 15))
    if [ $waited -gt 86400 ]; then echo "gave up: the Mac stayed locked or busy for a day" >> "$OUT/summary.txt"; exit 3; fi
  done
  echo "$waited"
}

# part <name> <log> [environment assignments...]: runs one part of the suite until it finishes
# (exit 0 or 1) or the attempts are used up. Exit 2 is the suite saying it was cut short.
part() {
  local name="$1" log="$2"; shift 2
  local attempt=1 status waited
  while :; do
    waited=$(wait_for_idle)
    echo "$name: attempt $attempt started $(date '+%H:%M:%S') after waiting $waited s" >> "$OUT/summary.txt"
    [ -f "$MODEL" ] && mv "$MODEL" "$MODEL.aside"
    (cd "$REPO" && env E2E_PAUSE_OTHER=1 COTABBY_REPO="$REPO" "$@" caffeinate -d -u -t 1500 bash "$OUT/pinned/live-smoke.sh") > "$log" 2>&1
    status=$?
    restore
    if [ $status -ne 2 ] || [ $attempt -ge "$ATTEMPTS" ]; then break; fi
    echo "$name: cut short ($(grep -E '^SKIP' "$log" | tail -n 1))" >> "$OUT/summary.txt"
    attempt=$((attempt + 1))
  done
  echo "$name: exit $status: $(grep -E 'passed,|^SKIP' "$log" | tail -n 1)" >> "$OUT/summary.txt"
  grep -E "^(FAIL|WARN|TIME)" "$log" >> "$OUT/summary.txt"
  return $status
}

export COTABBY_SPELL="${COTABBY_SPELL:-$HOME/Library/Developer/Xcode/DerivedData/CotabbyFork-CLI/Build/Products/Release/cotabby-spell}"
BUILD="$(installed)"
echo "installed build: $BUILD" > "$OUT/summary.txt"
part "full suite" "$OUT/full.log"; full=$?
part "training cases" "$OUT/training.log" E2E_ONLY=training; training=$?
echo "finished $(date '+%Y-%m-%d %H:%M:%S'); installed build at the end: $(installed)" >> "$OUT/summary.txt"
[ "$(installed)" = "$BUILD" ] || echo "WARNING: the installed app changed during the run; the result is not for one build" >> "$OUT/summary.txt"
cat "$OUT/summary.txt"
[ $full -eq 0 ] && [ $training -eq 0 ]
