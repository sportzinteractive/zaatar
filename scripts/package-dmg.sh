#!/bin/bash
# package-dmg.sh - build a distributable Zaatar.dmg
#
# Creates a self-contained Zaatar.app (the menu bar app with all scripts and
# pre-compiled universal binaries bundled inside) and packages it in a .dmg.
# Users drag to /Applications, launch, and get guided through first-run setup.
#
# Output: dist/Zaatar.dmg (and dist/Zaatar.app for testing)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Zaatar.app"
DMG="$DIST/Zaatar.dmg"
RESOURCES="$APP/Contents/Resources/zaatar"

rm -rf "$DIST"
mkdir -p "$DIST"

# ---- 1. compile universal binaries (arm64 + x86_64) ---------------------------
say() { printf '\033[1m[%s]\033[0m %s\n' "$1" "$2"; }

compile() {
  local dir="$1" bin="$2"; shift 2
  say "compile" "$bin (universal)"
  (cd "$ROOT/native/$dir"
    swiftc -O main.swift -o "${bin}-arm64" -target arm64-apple-macos14.2 "$@"
    swiftc -O main.swift -o "${bin}-x86"   -target x86_64-apple-macos14.2 "$@"
    lipo -create "${bin}-arm64" "${bin}-x86" -output "$bin"
    rm -f "${bin}-arm64" "${bin}-x86")
}

compile zaatarcap    zaatarcap    -framework AVFoundation
compile zaatarprompt zaatarprompt -framework AppKit
compile zaatarviewer zaatarviewer -framework AppKit
compile zaatarbar    zaatarbar    -framework AppKit -framework AVFoundation -framework ServiceManagement
compile zaatarcal    zaatarcal    -framework EventKit

# ---- 2. assemble Zaatar.app bundle ---------------------------------------------
say "bundle" "Zaatar.app"

mkdir -p "$APP/Contents/MacOS"
mkdir -p "$RESOURCES"

# Main executable = zaatarbar
cp "$ROOT/native/zaatarbar/zaatarbar"  "$APP/Contents/MacOS/zaatarbar"

# Info.plist: reuse zaatarbar's, override bundle name + add NSMicrophoneUsageDescription
# (ZaatarBar spawns ZaatarCap which needs its own grant, but the parent app should
# declare usage too for a clean permission prompt)
cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>org.zaatar.app</string>
    <key>CFBundleName</key>
    <string>Zaatar</string>
    <key>CFBundleDisplayName</key>
    <string>Zaatar</string>
    <key>CFBundleExecutable</key>
    <string>zaatarbar</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.2</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Zaatar records meeting audio from your microphone.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Zaatar captures system audio so remote participants are transcribed clearly.</string>
</dict>
</plist>
PLIST

# Bundle the repo (scripts, native binaries, config, vad, launchd templates)
for DIR in bin lib scripts vad launchd; do
  [ -d "$ROOT/$DIR" ] && cp -R "$ROOT/$DIR" "$RESOURCES/"
done
cp "$ROOT/config.example.sh" "$RESOURCES/"
cp "$ROOT/README.md" "$RESOURCES/" 2>/dev/null || true
cp "$ROOT/LICENSE" "$RESOURCES/" 2>/dev/null || true

# Pre-compiled universal binaries into the bundle
for APP_BIN in zaatarcap zaatarprompt zaatarviewer zaatarbar zaatarcal; do
  mkdir -p "$RESOURCES/native/$APP_BIN"
  cp "$ROOT/native/$APP_BIN/$APP_BIN" "$RESOURCES/native/$APP_BIN/"
  [ -f "$ROOT/native/$APP_BIN/Info.plist" ] && cp "$ROOT/native/$APP_BIN/Info.plist" "$RESOURCES/native/$APP_BIN/"
done

# Remove build artifacts and venv from the bundle
rm -rf "$RESOURCES/vad/.venv" "$RESOURCES/native"/*/*.{o,d}

# Make scripts executable
chmod -R +x "$RESOURCES/bin" "$RESOURCES/scripts" "$RESOURCES/native"/*/zaatar* 2>/dev/null || true

# ---- 3. ad-hoc sign the whole bundle -------------------------------------------
say "sign" "Zaatar.app"
codesign --force --deep -s - "$APP"

# ---- 4. create .dmg ------------------------------------------------------------
say "dmg" "Zaatar.dmg"

# Create a temporary folder with the app + Applications symlink
STAGE="$DIST/dmg-stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# hdiutil: create a compressed DMG
hdiutil create -volname "Zaatar" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG"

rm -rf "$STAGE"

# ---- summary -------------------------------------------------------------------
SIZE="$(du -sh "$DMG" | cut -f1)"
echo ""
say "done" "$DMG ($SIZE)"
echo ""
echo "  Test: open '$APP'"
echo "  Distribute: upload $DMG to GitHub Releases"
echo ""
