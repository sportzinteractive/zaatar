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
You are extracting COMMITMENTS from a meeting transcript for the user (the person running Zaatar). The meeting happened on __MDATE__.

Extract ONLY these two categories:
1. THINGS THE USER COMMITTED TO DO (they said they would, they took an action item, they volunteered)
2. THINGS OTHERS COMMITTED TO THE USER (promised a deliverable, owe an answer, took an action the user asked for or needs to follow up on)

Do NOT extract:
- Team members committing to each other (X told Y they will do Z) unless the user is the requester or recipient
- General action items that are just people doing their jobs (implement feature X, fix bug Y, test Z)
- Vague intentions, decisions without owners, things completed during the meeting
- Routine logistics: scheduling meetings, sending invites, sharing links/decks
- Anything where non-delivery would not require the user to act or follow up

The user is typically the person chairing or directing the discussion.

Max 3 items. If more qualify, keep the 3 most consequential.

Output ONLY lines in exactly this format, one per commitment:
- [ ] __MDATE__ | <owner name> -> <recipient or "self"> | <commitment, max 12 words> | due: <YYYY-MM-DD or stated timeframe or unspecified>

If nothing qualifies, output exactly: NONE
No other text, no headers, no explanations.
PROMPT
)"
PROMPT="${PROMPT//__MDATE__/$MDATE}"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
RC=0
zaatar_llm "$PROMPT" < "$MD" > "$TMP" 2>/dev/null || RC=$?
if [ "$RC" -ne 0 ] || [ ! -s "$TMP" ]; then
  echo "commitments: LLM extraction failed (exit $RC)"; exit 0
fi

# Keep only well-formed ledger lines (model chatter / NONE filtered out)
LINES="$(grep -E '^- \[ \] [0-9]{4}-[0-9]{2}-[0-9]{2} \|' "$TMP" || true)"
if [ -z "$LINES" ]; then
  echo "commitments: none found in $BASE"; exit 0
fi

# Prepend (newest meeting first): the viewer shows the ledger top-down, so
# appending buried fresh items under weeks of old sections.
{
  echo "## ${MDATE} ${BASE}"
  printf '%s\n' "$LINES" | sed "s|\$| \| src: ${BASE}|"
  echo
  [ -f "$LEDGER" ] && cat "$LEDGER"
} > "${LEDGER}.new"
mv "${LEDGER}.new" "$LEDGER"
echo "commitments: $(printf '%s\n' "$LINES" | wc -l | tr -d ' ') added to ledger from $BASE"

# Auto-expire: archive checked items and unchecked items older than 14 days
ARCHIVE="$LEDGER_DIR/commitments-archive.md"
CUTOFF="$(date -v-14d +%F 2>/dev/null || date -d '14 days ago' +%F 2>/dev/null || true)"
if [ -n "$CUTOFF" ] && [ -f "$LEDGER" ]; then
  EXPIRED=""
  KEPT=""
  while IFS= read -r line; do
    if printf '%s' "$line" | grep -qE '^\- \[x\]'; then
      EXPIRED="${EXPIRED}${line}"$'\n'
    elif printf '%s' "$line" | grep -qE '^\- \[ \] [0-9]{4}-[0-9]{2}-[0-9]{2}'; then
      ITEM_DATE="$(printf '%s' "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)"
      if [ "$ITEM_DATE" \< "$CUTOFF" ]; then
        EXPIRED="${EXPIRED}${line}"$'\n'
      else
        KEPT="${KEPT}${line}"$'\n'
      fi
    else
      KEPT="${KEPT}${line}"$'\n'
    fi
  done < "$LEDGER"
  if [ -n "$EXPIRED" ]; then
    { echo "## Archived $(date +%F)"; printf '%s' "$EXPIRED"; echo; [ -f "$ARCHIVE" ] && cat "$ARCHIVE"; } > "${ARCHIVE}.new"
    mv "${ARCHIVE}.new" "$ARCHIVE"
    printf '%s' "$KEPT" > "${LEDGER}.new"
    mv "${LEDGER}.new" "$LEDGER"
    echo "commitments: expired items archived to $ARCHIVE"
  fi
fi

# Strip orphaned section headers (header with no items before next header or EOF)
if [ -f "$LEDGER" ]; then
  awk '
    /^## / { if (length(hdr) > 0 && items == 0) hdr=""; hdr=$0; items=0; next }
    /^- \[/ { if (length(hdr) > 0) { print hdr; hdr="" }; items++; print; print ""; next }
    /^[[:space:]]*$/ { next }
    { print }
  ' "$LEDGER" > "${LEDGER}.new"
  mv "${LEDGER}.new" "$LEDGER"
fi
