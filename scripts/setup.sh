#!/bin/bash
# setup.sh - interactive first-run setup for Zaatar.
# Run as `zaatar setup` (brew install) or `scripts/setup.sh` (git checkout).
# Safe to re-run: existing config values are updated in place.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Under Homebrew, prefer the version-stable opt path so launchd plists and
# config values survive upgrades.
case "$ROOT" in
  */Cellar/zaatar/*)
    if command -v brew >/dev/null 2>&1; then
      OPT="$(brew --prefix)/opt/zaatar/libexec"
      [ -d "$OPT" ] && ROOT="$OPT"
    fi
    ;;
esac

CFG_DIR="$HOME/.config/zaatar"
CFG="$CFG_DIR/config"
MODELS_DIR="$HOME/.local/share/whisper-models"

say()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
note() { printf '  %s\n' "$1"; }

# ask "prompt" "default" -> REPLY
ask() {
  local prompt="$1" def="${2:-}"
  if [ -n "$def" ]; then
    read -r -p "  $prompt [$def]: " REPLY || REPLY=""
    REPLY="${REPLY:-$def}"
  else
    read -r -p "  $prompt: " REPLY || REPLY=""
  fi
}

yesno() { # yesno "prompt" "y|n" -> returns 0 for yes
  local def="${2:-y}"
  ask "$1 (y/n)" "$def"
  case "$REPLY" in y|Y|yes) return 0 ;; *) return 1 ;; esac
}

# set_config KEY VALUE - replace or append a config line. Values are written
# single-quoted so command templates with double quotes survive sourcing.
set_config() {
  local key="$1" val="$2"
  sed -i '' "/^[# ]*${key}=/d" "$CFG"
  printf "%s='%s'\n" "$key" "$val" >> "$CFG"
}

echo "Zaatar setup - everything runs locally; re-run anytime with 'zaatar setup'."

# ---- 0. config file ---------------------------------------------------------
mkdir -p "$CFG_DIR"
if [ ! -f "$CFG" ]; then
  cp "$ROOT/config.example.sh" "$CFG"
  note "created $CFG"
else
  note "using existing $CFG"
fi

# ---- 1. LLM provider --------------------------------------------------------
say "1/5  LLM for meeting notes, briefs, and commitments"
note "Transcription is always local. The LLM only sees transcript text."
HAVE_CLAUDE=""; command -v claude >/dev/null 2>&1 && HAVE_CLAUDE=" (installed)"
HAVE_OLLAMA=""; command -v ollama >/dev/null 2>&1 && HAVE_OLLAMA=" (installed)"
HAVE_LLM="";    command -v llm    >/dev/null 2>&1 && HAVE_LLM=" (installed)"
note "1) Claude CLI$HAVE_CLAUDE  - default, best quality"
note "2) Ollama$HAVE_OLLAMA  - fully local, nothing leaves the machine"
note "3) llm CLI$HAVE_LLM  - any provider via simonw/llm"
note "4) Custom command template"
note "5) None - keep raw timestamped transcripts only"
ask "Choice" "1"
case "$REPLY" in
  1)
    set_config ZAATAR_LLM_CMD ""
    command -v claude >/dev/null 2>&1 || note "NOTE: claude not found on PATH yet - install from https://docs.anthropic.com/en/docs/claude-code"
    ;;
  2)
    ask "Ollama model" "qwen2.5:14b"
    set_config ZAATAR_LLM_CMD '{ printf "%s\n\n" "$ZAATAR_PROMPT"; cat; } | ollama run '"$REPLY"
    command -v ollama >/dev/null 2>&1 || note "NOTE: install ollama first (brew install ollama) and pull the model"
    ;;
  3)
    ask "llm model id" "gpt-4.1"
    set_config ZAATAR_LLM_CMD 'llm -s "$ZAATAR_PROMPT" -m '"$REPLY"
    ;;
  4)
    note "Template gets the instruction in \$ZAATAR_PROMPT, content on stdin, result on stdout."
    ask "Command template"
    set_config ZAATAR_LLM_CMD "$REPLY"
    ;;
  *)
    set_config ZAATAR_LLM_CMD ""
    note "Skipped. Raw transcripts only (Claude CLI will be used if installed later)."
    ;;
esac

# ---- 2. calendar / meeting software -----------------------------------------
say "2/5  Calendar (meeting prompts + auto-stop; Meet/Zoom/Teams/Webex links all detected)"
note "1) Google Calendar (via gogcli)"
note "2) Outlook / Microsoft 365 (via Microsoft Graph CLI)"
note "3) None - start/stop recordings manually"
ask "Choice" "3"
CAL_SET=""
case "$REPLY" in
  1)
    set_config ZAATAR_CALENDAR_CMD "gog calendar events --today --max 50 -j --results-only"
    CAL_SET=1
    if command -v gog >/dev/null 2>&1; then
      note "gogcli found. If not authenticated yet: gog auth login"
    else
      note "NOTE: install gogcli (https://github.com/steipete/gogcli) then run: gog auth login"
    fi
    ;;
  2)
    set_config ZAATAR_CALENDAR_CMD "$ROOT/scripts/outlook-calendar.sh"
    CAL_SET=1
    if command -v mgc >/dev/null 2>&1; then
      note "Graph CLI found. If not authenticated yet: mgc login --scopes Calendars.Read"
    else
      note "NOTE: install the Microsoft Graph CLI (mgc) then run: mgc login --scopes Calendars.Read"
    fi
    ;;
  *)
    note "Skipped. Use 'zaatar start' / 'zaatar stop'."
    ;;
esac

# ---- 3. whisper models -------------------------------------------------------
say "3/5  Whisper models (local transcription)"
mkdir -p "$MODELS_DIR"
HF_BASE="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
if [ -f "$MODELS_DIR/ggml-large-v3.bin" ]; then
  note "ggml-large-v3.bin already present"
elif yesno "Download ggml-large-v3.bin (~3.1 GB, final transcription quality)?" "y"; then
  curl -L -C - -o "$MODELS_DIR/ggml-large-v3.bin" "$HF_BASE/ggml-large-v3.bin"
fi
if [ -f "$MODELS_DIR/ggml-base.bin" ]; then
  note "ggml-base.bin already present"
elif yesno "Download ggml-base.bin (~148 MB, live rough transcript)?" "y"; then
  curl -L -C - -o "$MODELS_DIR/ggml-base.bin" "$HF_BASE/ggml-base.bin"
fi

# ---- 4. native apps ----------------------------------------------------------
say "4/5  Native apps (recorder + menu bar)"
if [ ! -x "$ROOT/native/zaatarcap/zaatarcap" ]; then
  note "Compiling native apps (requires Xcode Command Line Tools)..."
  (cd "$ROOT/native/zaatarcap"    && swiftc -O main.swift -o zaatarcap    -framework AVFoundation)
  (cd "$ROOT/native/zaatarprompt" && swiftc -O main.swift -o zaatarprompt -framework AppKit)
  (cd "$ROOT/native/zaatarviewer" && swiftc -O main.swift -o zaatarviewer -framework AppKit)
  (cd "$ROOT/native/zaatarbar"    && swiftc -O main.swift -o zaatarbar    -framework AppKit -framework AVFoundation -framework ServiceManagement)
fi
mkdir -p "$HOME/Applications"
for APP in ZaatarCap:zaatarcap ZaatarBar:zaatarbar; do
  NAME="${APP%%:*}"; BIN="${APP##*:}"
  BUNDLE="$HOME/Applications/$NAME.app"
  mkdir -p "$BUNDLE/Contents/MacOS"
  cp "$ROOT/native/$BIN/$BIN" "$BUNDLE/Contents/MacOS/$BIN"
  cp "$ROOT/native/$BIN/Info.plist" "$BUNDLE/Contents/Info.plist"
  codesign --force -s - "$BUNDLE" 2>/dev/null
  note "installed $BUNDLE"
done
note "First recording will prompt for Microphone + System Audio Recording permissions."

# ---- 5. background watcher + menu bar ----------------------------------------
say "5/5  Background services"
if [ -n "$CAL_SET" ]; then
  if yesno "Install the calendar watcher (prompts at meeting start, auto-stops after)?" "y"; then
    PLIST="$HOME/Library/LaunchAgents/org.zaatar.meet-watch.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    sed "s|__ZAATAR_DIR__|$ROOT|" "$ROOT/launchd/org.zaatar.meet-watch.plist" > "$PLIST"
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    note "watcher loaded ($PLIST)"
  fi
fi
if yesno "Start the menu bar app (record/stop from the leaf icon, auto-starts at login)?" "y"; then
  open "$HOME/Applications/ZaatarBar.app"
fi

say "Done."
note "Try it: zaatar start test-meeting   (talk for ~30s)   zaatar stop"
note "Config: $CFG    Transcripts: see ZAATAR_TRANSCRIPTS_DIR in config"
exit 0
