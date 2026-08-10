#!/bin/bash
# build.sh - compile the native Zaatar apps and install the app bundles.
# ZaatarCap.app and ZaatarBar.app are installed to ~/Applications so each
# bundle can hold its own TCC grants (mic / system audio). Ad-hoc signing:
# every rebuild invalidates the grants, macOS re-prompts once.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/native"

echo "[1/5] zaatarcap"
(cd zaatarcap && swiftc -O main.swift -o zaatarcap -framework AVFoundation)
echo "[2/5] zaatarprompt"
(cd zaatarprompt && swiftc -O main.swift -o zaatarprompt -framework AppKit)
echo "[3/5] zaatarviewer"
(cd zaatarviewer && swiftc -O main.swift -o zaatarviewer -framework AppKit)
echo "[4/5] zaatarbar"
(cd zaatarbar && swiftc -O main.swift -o zaatarbar -framework AppKit -framework AVFoundation -framework ServiceManagement)

echo "[5/5] app bundles -> ~/Applications"
mkdir -p "$HOME/Applications"

for APP in ZaatarCap:zaatarcap ZaatarBar:zaatarbar; do
  NAME="${APP%%:*}"; BIN="${APP##*:}"
  BUNDLE="$HOME/Applications/$NAME.app"
  mkdir -p "$BUNDLE/Contents/MacOS"
  cp "$BIN/$BIN" "$BUNDLE/Contents/MacOS/$BIN"
  cp "$BIN/Info.plist" "$BUNDLE/Contents/Info.plist"
  codesign --force -s - "$BUNDLE"
  echo "  $BUNDLE"
done

echo
echo "Done. First recording will prompt for Microphone and System Audio"
echo "Recording permissions (System Settings > Privacy & Security)."
