#!/bin/bash
# Makes the disk image people download: "Cotabby Dev.app" built for release, with the sentence
# model inside it, next to a shortcut to /Applications.
#
#   Tools/release/package-dmg.sh <version>            e.g. 0.1.0
#
# The model file (640 MB) is not in the repo; it is taken from where the app looks for it on a
# development Mac, or from COTABBY_SENTENCE_MODEL. Tools/sentence-model/README.md builds it.
#
# Everything is staged outside the repo: a folder synced by iCloud (Desktop, Documents) adds
# attributes to files that make codesign refuse the bundle.
#
# The app is signed with the same local identity as Tools/install-dev.sh, not with an Apple
# Developer ID, so it is not notarized: on first launch macOS asks the person to confirm in
# System Settings > Privacy & Security ("Open Anyway"). One stable identity still matters: the
# Accessibility and Input Monitoring grants are tied to it, so they survive an update.
set -euo pipefail
cd "$(dirname "$0")/../.."
VERSION="${1:?usage: package-dmg.sh <version>}"
IDENTITY="${COTABBY_SIGN_IDENTITY:-Whisper Scribe Dev}"
MODEL="${COTABBY_SENTENCE_MODEL:-$HOME/Library/Application Support/Cotabby Dev/SentenceModel/spelling-qwen3-0.6b-q8_0.gguf}"
OUT="${COTABBY_RELEASE_DIR:-$HOME/Library/Developer/Xcode/DerivedData/CotabbyFork-Release}"
[ -f "$MODEL" ] || { echo "sentence model not found: $MODEL"; exit 1; }

BUILT=$(COTABBY_VERSION="$VERSION" Tools/install-dev.sh --build-only | tail -n 1)
STAGE="$OUT/stage"
mkdir -p "$OUT"
if [ -d "$STAGE" ]; then mv "$STAGE" "$HOME/.Trash/cotabby-release-stage-$(date +%s)"; fi
mkdir -p "$STAGE"
APP="$STAGE/Cotabby Dev.app"
ditto "$BUILT" "$APP"
cp "$MODEL" "$APP/Contents/Resources/"
xattr -cr "$APP"
# Adding a file changes the bundle's seal, so the outer bundle is signed again; the frameworks
# inside keep the signatures the build gave them. Signing without the build's entitlements drops
# `get-task-allow`, which lets a debugger attach and has no place in a build other people run.
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
ln -s /Applications "$STAGE/Applications"

DMG="$OUT/Cotabby-Dev-$VERSION.dmg"
if [ -f "$DMG" ]; then mv "$DMG" "$HOME/.Trash/Cotabby-Dev-$VERSION-$(date +%s).dmg"; fi
hdiutil create -volname "Cotabby Dev $VERSION" -srcfolder "$STAGE" -format UDZO -quiet "$DMG"
echo "$DMG"
echo "sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
