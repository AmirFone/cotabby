#!/bin/bash
# Builds the E2E test host app outside the (iCloud-synced) repo and prints its path.
set -euo pipefail
OUT="$HOME/Library/Caches/CotabbyE2E/CotabbyE2EHost.app"
mkdir -p "$OUT/Contents/MacOS"
swiftc -O "$(dirname "$0")/TestHost/main.swift" -o "$OUT/Contents/MacOS/CotabbyE2EHost" -framework AppKit
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.cotabby.e2e-host</string>
<key>CFBundleName</key><string>CotabbyE2EHost</string>
<key>CFBundleExecutable</key><string>CotabbyE2EHost</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$OUT" >/dev/null 2>&1
echo "$OUT"
