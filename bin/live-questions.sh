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
TITLE_FILE="${WAV%.wav}.title"
MODEL="$ZAATAR_CLEANUP_MODEL"
INTERVAL="${ZAATAR_QUESTIONS_INTERVAL:-90}"   # min seconds between claude calls; 0 disables
MIN_NEW=400      # min new live-transcript bytes before another call
CTX_BYTES=8000   # transcript tail sent as context

[ "$INTERVAL" -gt 0 ] || exit 0
zaatar_llm_available || exit 0

recorder_alive() { pgrep -f "zaatarcap .*${BASE}\.wav" >/dev/null 2>&1; }

# Build meeting context: title + attendees + pre-meeting brief (if it exists)
MEETING_CTX=""
if [ -s "$TITLE_FILE" ]; then
  MEETING_CTX="MEETING TITLE: $(cat "$TITLE_FILE")"$'\n'
fi
if [ -s "$ATT_FILE" ]; then
  MEETING_CTX="${MEETING_CTX}PARTICIPANTS: $(head -1 "$ATT_FILE")"$'\n'
fi
BRIEF_FILE="$ZAATAR_TRANSCRIPTS_DIR/briefs/brief-${BASE}.md"
if [ -s "$BRIEF_FILE" ]; then
  MEETING_CTX="${MEETING_CTX}"$'\nPRE-MEETING BRIEF (prior context with these attendees):\n'"$(head -60 "$BRIEF_FILE")"$'\n'
fi

QPROMPT="$(cat <<'EOF'
You are a strategic advisor listening to a LIVE meeting through a rough, error-prone speech-to-text feed (expect mis-transcriptions and mixed languages).

You are given MEETING CONTEXT above the transcript: the meeting title, participants, and a pre-meeting brief with history from prior meetings with these people. Use this to understand the BIG PICTURE: what is this meeting trying to achieve? What decisions need to be made? What outcomes matter?

Your job: suggest questions the listener could ask RIGHT NOW, out loud, that would help this meeting effectively reach its objectives. Think about:
- Are we drifting from the meeting goal? What question steers back?
- What decision is this meeting supposed to produce, and are we converging or going in circles?
- What commitment, owner, or deadline should be nailed down before time runs out?
- What risk or blocker is everyone avoiding or assuming away?
- Is there context from prior meetings (open commitments, unresolved items) that should be raised now?

Do NOT:
- Ask narrow, dissecting questions about whatever micro-topic is being discussed right now
- Ask for evidence or data that nobody in the room would have
- Ask something already answered in the transcript
- Suggest questions that sound like an interviewer or auditor, not a peer in the meeting

Each question must sound natural spoken aloud: short, conversational, plain language. The questions should reflect strategic thinking, not operational detail.

Quality bar is high: only questions that would genuinely move the meeting forward. If nothing clears the bar, output exactly NONE.
Output ONLY the questions, one per line, no numbering, no bullets, no commentary. Maximum 3.
EOF
)"

LAST_SIZE=0
while recorder_alive; do
  sleep "$INTERVAL"
  [ -s "$LIVE" ] || continue
  SIZE="$(stat -f %z "$LIVE" 2>/dev/null || echo 0)"
  [ $(( SIZE - LAST_SIZE )) -lt "$MIN_NEW" ] && continue
  LAST_SIZE="$SIZE"
  OUT="$( { printf '%s\n' "$MEETING_CTX"; echo "---LIVE TRANSCRIPT (rough, most recent)---"; tail -c "$CTX_BYTES" "$LIVE"; } \
    | zaatar_llm "$QPROMPT" \
      2>>"$STATE_DIR/live-questions.err" || true)"
  # keep the previous suggestions on NONE/empty (still the freshest good set)
  if [ -n "$OUT" ] && ! printf '%s\n' "$OUT" | head -1 | grep -qix 'none'; then
    printf '%s\n' "$OUT" > "$QFILE.tmp" && mv "$QFILE.tmp" "$QFILE"
  fi
done
