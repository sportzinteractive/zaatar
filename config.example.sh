# Zaatar configuration - copy to ~/.config/zaatar/config and edit.
# Plain KEY="value" lines only (this file is sourced by bash AND parsed by
# the native menu bar / viewer apps; no command substitution).
# Everything is optional; defaults are in lib/config.sh.

# ZAATAR_REC_DIR="$HOME/Recordings/meetings"
# ZAATAR_TRANSCRIPTS_DIR="$HOME/Documents/zaatar/transcripts"
# ZAATAR_STATE_DIR="$HOME/.local/state/zaatar"

# ZAATAR_MODEL="$HOME/.local/share/whisper-models/ggml-large-v3.bin"
# ZAATAR_LIVE_MODEL="$HOME/.local/share/whisper-models/ggml-base.bin"

# Languages spoken in your meetings (shapes the cleanup prompt):
# ZAATAR_LANGS="Hinglish (mixed Hindi/English)"

# Calendar integration (optional): a command printing today's events as a
# Google-Calendar-style JSON array (see README "Calendar integration" for the
# contract). Meet/Zoom/Teams/Webex links are all detected. Examples:
# Google Calendar via gogcli:
# ZAATAR_CALENDAR_CMD="gog calendar events --today --max 50 -j --results-only"
# Outlook / Microsoft 365 via the bundled Graph adapter:
# ZAATAR_CALENDAR_CMD="$HOME/path/to/zaatar/scripts/outlook-calendar.sh"

# ZAATAR_CLEANUP_MODEL="sonnet"

# Bring your own LLM (default: Claude CLI). A shell command template that
# gets the instruction prompt in $ZAATAR_PROMPT, the content on stdin, and
# prints the result to stdout. Examples:
# fully local via ollama:
# ZAATAR_LLM_CMD='{ printf "%s\n\n" "$ZAATAR_PROMPT"; cat; } | ollama run qwen2.5:14b'
# any provider via simonw/llm:
# ZAATAR_LLM_CMD='llm -s "$ZAATAR_PROMPT" -m gpt-4.1'
# ZAATAR_LLM_CMD=""
# Live question suggestions in the viewer (seconds between claude calls, 0 = off):
# ZAATAR_QUESTIONS_INTERVAL="90"
# ZAATAR_MIC_GAIN_FLOOR="65"
# ZAATAR_VAD_MIN_SPEECH="10"
# ZAATAR_WAV_RETENTION_DAYS="14"

# Pre-meeting brief: seconds before a meeting to generate a digest of prior
# transcripts with the same attendees (0 = off). Your own name words
# (lowercase) are excluded from attendee matching:
# ZAATAR_BRIEF_LEAD="900"
# ZAATAR_SELF_NAMES="jane doe jdoe"
