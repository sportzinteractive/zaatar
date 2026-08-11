#!/bin/bash
# commitments.sh <final-transcript.md>
# Post-meeting commitment extraction: pulls "who promised what by when" out of
# a cleaned transcript and appends it to a running ledger
# ($ZAATAR_TRANSCRIPTS_DIR/ledger/commitments.md). The pre-meeting brief
# (brief.sh) reads this ledger to flag unfulfilled commitments.
# Append-only; tick checkboxes by hand once a commitment is delivered.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

SCRIPT_PATH="$0"; [ -L "$SCRIPT_PATH" ] && SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH")"
BIN_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
. "$BIN_DIR/../lib/config.sh"

MD="${1:?usage: commitments.sh <final-transcript.md>}"
OUT_DIR="$ZAATAR_TRANSCRIPTS_DIR"
LEDGER_DIR="$OUT_DIR/ledger"
LEDGER="$LEDGER_DIR/commitments.md"
mkdir -p "$LEDGER_DIR"

[ -s "$MD" ] || { echo "commitments: missing/empty $MD"; exit 0; }
BASE="$(basename "$MD" .md)"

# Junk-note guard output has no content worth mining
if head -3 "$MD" | grep -q "no speech detected"; then
  echo "commitments: junk-note, skipping"; exit 0
fi

# Already ledgered (retry runs, manual re-runs)
if [ -f "$LEDGER" ] && grep -q "src: ${BASE}\$" "$LEDGER"; then
  echo "commitments: $BASE already in ledger, skipping"; exit 0
fi

# Meeting date from the filename (YYYY-MM-DD-HHMM-slug), fallback today
MDATE="$(printf '%s' "$BASE" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || date +%F)"

# NOTE: apostrophes inside $(<<HEREDOC) break bash 3.2 parsing - keep the
# prompt apostrophe-free and inject the date via placeholder.
PROMPT="$(cat <<'PROMPT'
You are extracting COMMITMENTS from a meeting transcript (summary, key points, transcript below). The meeting happened on __MDATE__.

A commitment = a specific person agreed to do a specific thing (optionally by a specific time). Include commitments made BY anyone in the meeting. Do NOT include vague intentions (we should look into X), decisions that are not owned actions, or things already completed during the meeting itself.

Output ONLY lines in exactly this format, one per commitment:
- [ ] __MDATE__ | <person first name or full name> | <commitment, max 12 words> | due: <YYYY-MM-DD or stated timeframe or unspecified>

If the transcript contains no commitments, output exactly: NONE
No other text, no headers, no explanations.
PROMPT
)"
PROMPT="${PROMPT//__MDATE__/$MDATE}"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
RC=0
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude -p --model "$ZAATAR_CLEANUP_MODEL" "$PROMPT" \
  < "$MD" > "$TMP" 2>/dev/null || RC=$?
if [ "$RC" -ne 0 ] || [ ! -s "$TMP" ]; then
  echo "commitments: claude extraction failed (exit $RC)"; exit 0
fi

# Keep only well-formed ledger lines (model chatter / NONE filtered out)
LINES="$(grep -E '^- \[ \] [0-9]{4}-[0-9]{2}-[0-9]{2} \|' "$TMP" || true)"
if [ -z "$LINES" ]; then
  echo "commitments: none found in $BASE"; exit 0
fi

{
  echo
  echo "## ${MDATE} ${BASE}"
  printf '%s\n' "$LINES" | sed "s|\$| \| src: ${BASE}|"
} >> "$LEDGER"
echo "commitments: $(printf '%s\n' "$LINES" | wc -l | tr -d ' ') added to ledger from $BASE"
