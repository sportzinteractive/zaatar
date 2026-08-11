#!/bin/bash
# live-questions.sh <recording.wav> - AI-suggested questions during a live meeting
# Every ~ZAATAR_QUESTIONS_INTERVAL seconds (when enough new transcript has
# accumulated), feeds the tail of the rough live transcript to claude and writes
# 1-3 first-principles questions to $ZAATAR_STATE_DIR/questions-<base>.txt for
# the Zaatar viewer's live view.
# Spawned by `rec start` alongside live-transcribe.sh; exits when the recorder dies.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_PATH="$0"; [ -L "$SCRIPT_PATH" ] && SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH")"
BIN_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
. "$BIN_DIR/../lib/config.sh"

WAV="${1:?usage: live-questions.sh <recording.wav>}"
STATE_DIR="$ZAATAR_STATE_DIR"
BASE="$(basename "$WAV" .wav)"
LIVE="$STATE_DIR/live-${BASE}.txt"
QFILE="$STATE_DIR/questions-${BASE}.txt"
ATT_FILE="${WAV%.wav}.attendees"
MODEL="$ZAATAR_CLEANUP_MODEL"
INTERVAL="${ZAATAR_QUESTIONS_INTERVAL:-90}"   # min seconds between claude calls; 0 disables
MIN_NEW=400      # min new live-transcript bytes before another call
CTX_BYTES=8000   # transcript tail sent as context

[ "$INTERVAL" -gt 0 ] || exit 0
command -v claude >/dev/null || exit 0

recorder_alive() { pgrep -f "zaatarcap .*${BASE}\.wav" >/dev/null 2>&1; }

QPROMPT="$(cat <<'EOF'
You are listening in on a LIVE meeting through a rough, error-prone speech-to-text feed (expect mis-transcriptions and mixed languages). The listener wants questions they could naturally ask RIGHT NOW, out loud.

Reason from first principles about what is actually being discussed:
- What claim is being made, and what evidence would confirm or kill it?
- What assumption is everyone silently making?
- What constraint, number, or owner is missing from the discussion?
- What second-order effect or failure mode has nobody raised?

Rules:
- Anchor every question to the CURRENT topic (the most recent segments), not something long past.
- Never ask something already answered in the transcript.
- Each question must sound natural spoken aloud: short, conversational, plain language, no jargon, no preamble.
- Quality bar is high: only questions a sharp operator would genuinely ask. If nothing clears the bar, output exactly NONE.
- Output ONLY the questions, one per line, no numbering, no bullets, no commentary. Maximum 3.
EOF
)"

LAST_SIZE=0
while recorder_alive; do
  sleep "$INTERVAL"
  [ -s "$LIVE" ] || continue
  SIZE="$(stat -f %z "$LIVE" 2>/dev/null || echo 0)"
  [ $(( SIZE - LAST_SIZE )) -lt "$MIN_NEW" ] && continue
  LAST_SIZE="$SIZE"
  ROSTER=""
  [ -s "$ATT_FILE" ] && ROSTER="Meeting participants: $(head -1 "$ATT_FILE")"$'\n\n'
  OUT="$( { printf '%s' "$ROSTER"; tail -c "$CTX_BYTES" "$LIVE"; } \
    | env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude -p --model "$MODEL" "$QPROMPT" \
      2>>"$STATE_DIR/live-questions.err" || true)"
  # keep the previous suggestions on NONE/empty (still the freshest good set)
  if [ -n "$OUT" ] && ! printf '%s\n' "$OUT" | head -1 | grep -qix 'none'; then
    printf '%s\n' "$OUT" > "$QFILE.tmp" && mv "$QFILE.tmp" "$QFILE"
  fi
done
