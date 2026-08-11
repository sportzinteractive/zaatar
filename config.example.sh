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
# Google-Calendar-style JSON array. Example using gogcli:
# ZAATAR_CALENDAR_CMD="gog calendar events --today -j --results-only"

# ZAATAR_CLEANUP_MODEL="sonnet"
# Live question suggestions in the viewer (seconds between claude calls, 0 = off):
# ZAATAR_QUESTIONS_INTERVAL="90"
# ZAATAR_MIC_GAIN_FLOOR="65"
# ZAATAR_VAD_MIN_SPEECH="10"
# ZAATAR_WAV_RETENTION_DAYS="14"
