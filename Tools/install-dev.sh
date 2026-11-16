#!/bin/bash
# Builds the Release "Cotabby Dev" app with the local self-signed identity and installs it in
# /Applications, replacing the previous copy (moved to Trash). Pass --debug-logs to relaunch with
# per-stage debug logging, or --build-only to build, verify, print the app's path and stop (what
# Tools/release/package-dmg.sh uses). COTABBY_VERSION=<x.y.z> sets the version the app reports.
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/CotabbyFork-Dev"
IDENTITY="${COTABBY_SIGN_IDENTITY:-Whisper Scribe Dev}"
xcodebuild -project Cotabby.xcodeproj -scheme "Cotabby Dev" -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" ENABLE_HARDENED_RUNTIME=NO ENABLE_DEBUG_DYLIB=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp=none" ${COTABBY_VERSION:+MARKETING_VERSION="$COTABBY_VERSION"} -jobs "$(sysctl -n hw.ncpu)" build > /tmp/cotabby-dev-build.log 2>&1 \
  || { grep -E "error:|failed|While running pass" /tmp/cotabby-dev-build.log | head -20; echo "BUILD FAILED (full log: /tmp/cotabby-dev-build.log)"; exit 1; }
APP="$DERIVED/Build/Products/Release/Cotabby Dev.app"
codesign --verify --deep --strict "$APP"
if [ "${1:-}" = "--build-only" ]; then echo "$APP"; exit 0; fi
pkill -f "Cotabby Dev.app/Contents/MacOS" || true
sleep 1
if [ -d "/Applications/Cotabby Dev.app" ]; then mv "/Applications/Cotabby Dev.app" "$HOME/.Trash/Cotabby Dev $(date +%s).app"; fi
ditto "$APP" "/Applications/Cotabby Dev.app"
xattr -cr "/Applications/Cotabby Dev.app"
if [ "${1:-}" = "--debug-logs" ]; then open "/Applications/Cotabby Dev.app" --args -cotabby-debug true; else open "/Applications/Cotabby Dev.app"; fi
echo "installed $(shasum "/Applications/Cotabby Dev.app/Contents/MacOS/Cotabby Dev" | cut -c1-12)"
