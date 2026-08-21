# lib/config.sh - Zaatar configuration loader (sourced by every script)
#
# Config file: plain KEY="value" lines (valid bash, also parsed by the native
# apps). Copy config.example.sh to ~/.config/zaatar/config and edit.
# Every value has a working default; the config file is optional.

ZAATAR_CONFIG="${ZAATAR_CONFIG:-$HOME/.config/zaatar/config}"
# shellcheck disable=SC1090
[ -f "$ZAATAR_CONFIG" ] && . "$ZAATAR_CONFIG"

# Where recordings (wav) are stored
: "${ZAATAR_REC_DIR:=$HOME/Recordings/meetings}"
# Where finished transcripts (md) are stored
: "${ZAATAR_TRANSCRIPTS_DIR:=$HOME/Documents/zaatar/transcripts}"
# Runtime state (pid files, logs, live transcripts, prompt markers)
: "${ZAATAR_STATE_DIR:=$HOME/.local/state/zaatar}"

# whisper.cpp models (https://huggingface.co/ggerganov/whisper.cpp)
: "${ZAATAR_MODEL:=$HOME/.local/share/whisper-models/ggml-large-v3.bin}"
: "${ZAATAR_LIVE_MODEL:=$HOME/.local/share/whisper-models/ggml-base.bin}"

# Native capture app (owns the mic + system-audio TCC grants)
: "${ZAATAR_CAP_BIN:=$HOME/Applications/ZaatarCap.app/Contents/MacOS/zaatarcap}"

# Languages spoken in your meetings; used in the cleanup prompt.
# Examples: "English", "Hinglish (mixed Hindi/English)", "German and English"
: "${ZAATAR_LANGS:=English}"

# Claude CLI model for transcript cleanup (used by the default LLM provider)
: "${ZAATAR_CLEANUP_MODEL:=sonnet}"

# LLM provider override: a shell command template run via `bash -c`. It
# receives the instruction prompt in $ZAATAR_PROMPT, the content on stdin,
# and must print the result to stdout (nonzero exit = failure). Empty =
# use the Claude CLI. Examples in config.example.sh (ollama, llm, etc).
: "${ZAATAR_LLM_CMD:=}"

# zaatar_llm "<prompt>" < content > result  - the single LLM entry point.
zaatar_llm() {
  if [ -n "$ZAATAR_LLM_CMD" ]; then
    ZAATAR_PROMPT="$1" bash -c "$ZAATAR_LLM_CMD"
  else
    # env -u: a nested claude call inside a Claude Code session misbehaves
    env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude -p --model "$ZAATAR_CLEANUP_MODEL" "$1"
  fi
}

# True when an LLM is usable (custom command configured, or claude on PATH)
zaatar_llm_available() {
  if [ -n "$ZAATAR_LLM_CMD" ]; then return 0; fi
  command -v claude >/dev/null 2>&1
}

# Live question suggestions: while recording, periodically ask claude for 1-3
# sharp questions based on the rough live transcript (shown in the viewer's
# live view). Seconds between calls; 0 disables.
: "${ZAATAR_QUESTIONS_INTERVAL:=90}"

# Command that prints today's calendar events as a Google-Calendar-style JSON
# array (fields used: id, summary, start.dateTime, end.dateTime, hangoutLink,
# conferenceData.conferenceSolution.key.type, attendees[]). Leave empty to
# disable calendar prompts entirely.
: "${ZAATAR_CALENDAR_CMD:=}"

# Hugging Face token file (enables pyannote speaker diarization via whisperx)
: "${ZAATAR_HF_TOKEN_FILE:=$HOME/.cache/huggingface/token}"

# Mic input-volume floor re-asserted every 30s while recording (0 = disable).
# Browser AGC (e.g. Meet in Chrome) silently drags the macOS input volume
# down, which makes your own voice too quiet for whisper.
: "${ZAATAR_MIC_GAIN_FLOOR:=65}"

# VAD junk guard: skip transcription when a recording has fewer than this
# many seconds of detected speech (0 = disable). Needs vad/.venv installed.
: "${ZAATAR_VAD_MIN_SPEECH:=10}"

# Behavioral Read: include per-speaker behavioral evidence + scorecard in
# transcript cleanup (text-only analysis from the transcript itself).
# The full emotional eval (prosody + acoustic analysis) runs separately via
# zaatar analyze and requires the prosody venv.
: "${ZAATAR_BEHAVIORAL_READ:=true}"

# Prosody/emotion venv: python with parselmouth + audeering wav2vec2.
# Used by analyze.sh for acoustic arousal/valence/dominance scoring.
# Set up via: zaatar setup --prosody (or manually create the venv).
: "${ZAATAR_PROSODY_VENV:=}"

# Delete wavs older than this many days once their transcript exists (0 = keep forever)
: "${ZAATAR_WAV_RETENTION_DAYS:=14}"

# Pre-meeting brief: seconds before a meeting to generate a digest of prior
# transcripts with the same attendees (0 = disable). Needs calendar prompts.
: "${ZAATAR_BRIEF_LEAD:=900}"

# Your own name/email words (lowercase, space-separated) so prior-meeting
# matching never matches on you. Example: "jane doe jdoe"
: "${ZAATAR_SELF_NAMES:=}"

export ZAATAR_REC_DIR ZAATAR_TRANSCRIPTS_DIR ZAATAR_STATE_DIR \
       ZAATAR_MODEL ZAATAR_LIVE_MODEL ZAATAR_CAP_BIN ZAATAR_LANGS \
       ZAATAR_CLEANUP_MODEL ZAATAR_QUESTIONS_INTERVAL ZAATAR_CALENDAR_CMD \
       ZAATAR_HF_TOKEN_FILE ZAATAR_MIC_GAIN_FLOOR ZAATAR_VAD_MIN_SPEECH \
       ZAATAR_BEHAVIORAL_READ ZAATAR_PROSODY_VENV \
       ZAATAR_WAV_RETENTION_DAYS ZAATAR_BRIEF_LEAD ZAATAR_SELF_NAMES \
       ZAATAR_LLM_CMD
