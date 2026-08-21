#!/bin/bash
# One-line install: curl -fsSL https://raw.githubusercontent.com/sportzinteractive/zaatar/main/scripts/install.sh | bash
#
# Installs Zaatar to ~/.local/share/zaatar, compiles the native apps, downloads
# whisper models, and walks through an interactive setup. Re-run to update.
set -euo pipefail

ZAATAR_DIR="${ZAATAR_DIR:-$HOME/.local/share/zaatar}"
REPO="https://github.com/sportzinteractive/zaatar.git"

say()  { printf '\n\033[1;32m==> %s\033[0m\n' "$1"; }
err()  { printf '\033[1;31merror: %s\033[0m\n' "$1" >&2; exit 1; }
note() { printf '    %s\n' "$1"; }

# ---- pre-flight ---------------------------------------------------------------
say "Checking requirements"

SW_VER="$(sw_vers -productVersion 2>/dev/null || true)"
MAJOR="${SW_VER%%.*}"
REST="${SW_VER#*.}"; MINOR="${REST%%.*}"
if [ -z "$MAJOR" ] || [ "$MAJOR" -lt 14 ] || { [ "$MAJOR" -eq 14 ] && [ "${MINOR:-0}" -lt 2 ]; }; then
  err "Zaatar requires macOS 14.2+ (you have ${SW_VER:-unknown})"
fi
note "macOS $SW_VER"

if ! xcode-select -p >/dev/null 2>&1; then
  say "Installing Xcode Command Line Tools (this may take a few minutes)..."
  xcode-select --install 2>/dev/null || true
  # Wait for the install to finish (the GUI installer runs async)
  until xcode-select -p >/dev/null 2>&1; do sleep 5; done
fi
note "Xcode CLT ready"

# ---- Homebrew ------------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  say "Installing Homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # shellcheck disable=SC2046
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"
fi

say "Installing dependencies"
brew install ffmpeg jq whisper-cpp 2>/dev/null || brew upgrade ffmpeg jq whisper-cpp 2>/dev/null || true
for DEP in ffmpeg jq whisper-cli; do
  command -v "$DEP" >/dev/null 2>&1 || err "$DEP not found after brew install"
done
note "ffmpeg, jq, whisper-cpp"

# ---- clone / update ------------------------------------------------------------
if [ -d "$ZAATAR_DIR/.git" ]; then
  say "Updating Zaatar"
  git -C "$ZAATAR_DIR" pull --ff-only 2>/dev/null || git -C "$ZAATAR_DIR" fetch
else
  say "Downloading Zaatar"
  rm -rf "$ZAATAR_DIR"
  git clone --depth 1 --branch v0.1.0 "$REPO" "$ZAATAR_DIR"
fi
note "$ZAATAR_DIR"

# ---- VAD (optional, best-effort) -----------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  say "Setting up voice-activity detection"
  (cd "$ZAATAR_DIR" && python3 -m venv vad/.venv && vad/.venv/bin/pip install -q -r vad/requirements.txt) \
    || note "VAD setup skipped (non-fatal)"
fi

# ---- Speaker diarization (optional) -------------------------------------------
say "Setting up speaker diarization (optional, GPU-accelerated)"
note "Adds speaker names to transcripts. Requires a free Hugging Face account"
note "and accepting the pyannote model terms."
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "from pyannote.audio import Pipeline" 2>/dev/null; then
    note "pyannote already available in system python"
  else
    (cd "$ZAATAR_DIR" && python3 -m venv diarize/.venv \
      && diarize/.venv/bin/pip install -q pyannote.audio torch) \
      || note "Diarization setup skipped (non-fatal). Install later: pip install pyannote.audio torch"
  fi
else
  note "python3 not found, skipping diarization setup"
fi

# ---- interactive setup (compiles, downloads models, configures) -----------------
say "Running interactive setup"
"$ZAATAR_DIR/scripts/setup.sh"

# ---- shell integration ---------------------------------------------------------
say "Shell integration"
SHELL_NAME="$(basename "$SHELL")"
BIN_LINK="$HOME/.local/bin/zaatar"
mkdir -p "$HOME/.local/bin"
ln -sf "$ZAATAR_DIR/bin/zaatar" "$BIN_LINK"

PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
ADDED=false
for RC in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
  if [ -f "$RC" ] && ! grep -qF '.local/bin' "$RC"; then
    printf '\n# Zaatar\n%s\n' "$PATH_LINE" >> "$RC"
    ADDED=true
    note "added PATH to $RC"
  fi
done
if [ "$ADDED" = false ]; then
  note "PATH already includes ~/.local/bin (or no shell RC found)"
fi

say "Zaatar is ready"
note ""
note "  zaatar start my-meeting    # start recording (mic will prompt once)"
note "  zaatar stop                # stop + transcribe"
note "  zaatar setup               # change settings anytime"
note ""
note "The leaf icon in your menu bar is your recording control."
note "Transcripts land in: $(grep ZAATAR_TRANSCRIPTS_DIR "$HOME/.config/zaatar/config" 2>/dev/null | cut -d= -f2 | tr -d \"\')"
note ""
