#!/bin/bash
# brief.sh --title "<event title>" --attendees "<comma-separated names/emails>" [--out <md>] [--no-prompt]
# Pre-meeting brief: digs prior transcripts with the same people out of
# $ZAATAR_TRANSCRIPTS_DIR, pulls their open commitments from the ledger, and
# has claude write a 60-second digest. Surfaces it via a zaatarprompt panel
# ("Open brief" opens the md) with a notification fallback.
# Spawned in the background by meet-watch.sh ~15 min before a meeting.
# Set ZAATAR_SELF_NAMES so your own name never counts as a match.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

SCRIPT_PATH="$0"; [ -L "$SCRIPT_PATH" ] && SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH")"
BIN_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
. "$BIN_DIR/../lib/config.sh"

OUT_DIR="$ZAATAR_TRANSCRIPTS_DIR"
LEDGER="$OUT_DIR/ledger/commitments.md"
BRIEF_DIR="$OUT_DIR/briefs"
ZPROMPT="$BIN_DIR/../native/zaatarprompt/zaatarprompt"
SELF_NAMES="$(printf '%s' "${ZAATAR_SELF_NAMES:-}" | tr '[:upper:]' '[:lower:]')"

TITLE=""; ATTENDEES=""; OUT=""; SHOW_PROMPT=true; ATTACH_JSON="[]"
while [ $# -gt 0 ]; do
  case "$1" in
    --title)     TITLE="${2:-}"; shift 2 ;;
    --attendees) ATTENDEES="${2:-}"; shift 2 ;;
    --out)       OUT="${2:-}"; shift 2 ;;
    --attachments-json) ATTACH_JSON="${2:-[]}"; shift 2 ;;
    --no-prompt) SHOW_PROMPT=false; shift ;;
    *) echo "brief: unknown arg $1"; exit 1 ;;
  esac
done
[ -n "$TITLE" ] || { echo "brief: --title required"; exit 1; }
[ -n "$ATTENDEES" ] || { echo "brief: no attendees, nothing to brief on"; exit 0; }

notify() {
  osascript -e 'on run argv
display notification (item 1 of argv) with title "Zaatar"
end run' -- "$1" >/dev/null 2>&1 || true
}

SLUG="$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g' | cut -c1-40)"
mkdir -p "$BRIEF_DIR"
[ -n "$OUT" ] || OUT="$BRIEF_DIR/$(date +%F)-${SLUG:-meeting}-brief.md"

# --- attendee -> lowercase name tokens (words of display names, email
# localparts split on dots), self excluded ---
TOKENS=()
NTOK=0
while IFS= read -r A; do
  A="$(printf '%s' "$A" | sed -E 's/^ +| +$//g' | tr '[:upper:]' '[:lower:]')"
  [ -z "$A" ] && continue
  case "$A" in *@*) A="$(printf '%s' "$A" | cut -d@ -f1 | tr '._-' '  ')" ;; esac
  for W in $A; do
    [ ${#W} -lt 3 ] && continue
    case "$SELF_NAMES" in *"$W"*) continue ;; esac
    TOKENS+=("$W"); NTOK=$((NTOK + 1))
  done
# %s\n (not %s): without the trailing newline `read` drops the LAST attendee,
# which for a 1:1 meant zero tokens and a silently skipped brief
done < <(printf '%s\n' "$ATTENDEES" | tr ',' '\n')
if [ "$NTOK" -eq 0 ]; then
  echo "brief: no usable attendee tokens (self-only meeting?)"; exit 0
fi

# --- candidate transcripts: filename slug match OR participants-header match
# in the raw md; newest first, top 4 ---
MATCHES=""
for MD in $(ls -t "$OUT_DIR"/*.md 2>/dev/null); do
  B="$(basename "$MD" .md)"
  case "$B" in *-raw) continue ;; esac
  HIT=false
  for T in ${TOKENS[@]+"${TOKENS[@]}"}; do
    case "$B" in *"$T"*) HIT=true; break ;; esac
  done
  if [ "$HIT" = false ] && [ -f "$OUT_DIR/${B}-raw.md" ]; then
    PLINE="$(grep -m1 -i '^- Participants (from calendar invite):' "$OUT_DIR/${B}-raw.md" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
    if [ -n "$PLINE" ]; then
      for T in ${TOKENS[@]+"${TOKENS[@]}"}; do
        case "$PLINE" in *"$T"*) HIT=true; break ;; esac
      done
    fi
  fi
  [ "$HIT" = true ] && MATCHES="$MATCHES$MD"$'\n'
  [ "$(printf '%s' "$MATCHES" | grep -c .)" -ge 4 ] && break
done
MATCHES="$(printf '%s' "$MATCHES" | grep . || true)"

# --- open commitments from the ledger involving these people ---
OPEN_COMMITS=""
if [ -s "$LEDGER" ]; then
  for T in ${TOKENS[@]+"${TOKENS[@]}"}; do
    L="$(grep -i '^- \[ \]' "$LEDGER" | grep -i "$T" || true)"
    [ -n "$L" ] && OPEN_COMMITS="$OPEN_COMMITS$L"$'\n'
  done
  OPEN_COMMITS="$(printf '%s' "$OPEN_COMMITS" | sort -u || true)"
fi

# --- event attachments (agenda docs, candidate resumes): download, extract
# text (Google Docs -> txt export, PDFs -> pdftotext), cap 6KB each, max 3 ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ATTACH_TEXT=""
AN=0
while IFS=$'\t' read -r AT_ID AT_TITLE AT_MIME; do
  [ -z "$AT_ID" ] && continue
  AN=$((AN+1)); [ "$AN" -gt 3 ] && break
  AF="$TMP/att$AN"
  TXT=""
  case "$AT_MIME" in
    application/vnd.google-apps.*)
      gog drive download "$AT_ID" --out "$AF.txt" --format txt >/dev/null 2>&1 || true
      [ -s "$AF.txt" ] && TXT="$(head -c 6144 "$AF.txt")" ;;
    application/pdf)
      gog drive download "$AT_ID" --out "$AF.pdf" >/dev/null 2>&1 || true
      [ -s "$AF.pdf" ] && TXT="$(pdftotext -l 5 "$AF.pdf" - 2>/dev/null | head -c 6144 || true)" ;;
  esac
  if [ -n "$TXT" ]; then
    ATTACH_TEXT="$ATTACH_TEXT
=== ATTACHMENT: $AT_TITLE ===
$TXT
"
    echo "brief: attachment scanned: $AT_TITLE"
  fi
done < <(printf '%s' "$ATTACH_JSON" | jq -r '.[]? | [.fileId, .title, .mimeType] | @tsv' 2>/dev/null || true)

if [ -z "$MATCHES" ] && [ -z "$OPEN_COMMITS" ] && [ -z "$ATTACH_TEXT" ]; then
  echo "brief: no prior transcripts, commitments, or attachments for: ${TOKENS[*]}"; exit 0
fi

# --- assemble claude input: Summary+Key Points of each match (transcript
# sections cut, 8KB cap each) + open ledger lines + attachment text ---
{
  echo "UPCOMING MEETING: ${TITLE}"
  echo "ATTENDEES: ${ATTENDEES}"
  echo "TODAY: $(date +%F)"
  echo
  if [ -n "$OPEN_COMMITS" ]; then
    echo "OPEN COMMITMENTS LEDGER (unticked = not yet verified done):"
    printf '%s\n' "$OPEN_COMMITS"
    echo
  fi
  if [ -n "$ATTACH_TEXT" ]; then
    echo "MEETING ATTACHMENTS (agenda, resume, docs attached to the invite):"
    printf '%s\n' "$ATTACH_TEXT"
    echo
  fi
  if [ -n "$MATCHES" ]; then
    echo "PRIOR MEETING NOTES (newest first):"
    while read -r MD; do
      echo
      echo "=== $(basename "$MD" .md) ==="
      # SIGPIPE from head under pipefail is fatal; the {..} || true guard absorbs it
      { awk '/^## (Transcript|Detailed Notes|Behavioral Read)/{exit} {print}' "$MD" | head -c 8192; } || true
    done <<< "$MATCHES"
  fi
} > "$TMP/input.md"

PROMPT="$(cat <<'PROMPT'
You are writing a 60-second PRE-MEETING BRIEF for the user before the upcoming meeting described in the input. You have their prior meeting notes with these attendees and an open-commitments ledger.

Produce a markdown document with exactly these sections (omit a section entirely if there is nothing real to put in it):

# Pre-meeting brief: <meeting title>

## Last time with these people
2-4 sentences: what was discussed and decided in the most recent prior meeting(s). Include the date(s).

## Open commitments
Bulleted list from the ledger and the notes: who owes what, since when, due when. Flag overdue ones with **OVERDUE**. If a prior transcript shows a commitment was already delivered, mark it (done, per <date> meeting) instead of listing it as open.

## Unanswered questions
Questions raised in prior meetings that never got answered, or threads left hanging.

## Suggested opening move
One sentence: the single sharpest thing the user could open with.

If the input includes MEETING ATTACHMENTS, add:

## From the attachments
3-5 bullets of what matters from the attached docs. For a candidate resume: current role, relevant experience, notable gaps or claims worth probing in the interview.

Rules: total under 250 words (300 if attachments present). Only state what the input supports; never invent. Use names. No preamble, output only the markdown document.
PROMPT
)"

RC=0
for BATTEMPT in 1 2 3 4 5; do
  RC=0
  zaatar_llm "$PROMPT" \
    < "$TMP/input.md" > "$TMP/brief.md" 2>"$TMP/claude.err" || RC=$?
  [ "$RC" -eq 0 ] && [ -s "$TMP/brief.md" ] && break
  echo "brief: LLM attempt $BATTEMPT failed (exit $RC)"
  # Rate limit: retry inside the pre-meeting window; the start prompt picks
  # the brief up whenever it lands (BRIEF_FILE re-checked each cycle)
  if cat "$TMP/brief.md" "$TMP/claude.err" 2>/dev/null | grep -q 'hit your limit'; then
    sleep 120
  else
    sleep 15
  fi
done
if [ "$RC" -ne 0 ] || [ ! -s "$TMP/brief.md" ]; then
  echo "brief: LLM failed (exit $RC)"; cat "$TMP/claude.err" 2>/dev/null || true; exit 1
fi

{
  cat "$TMP/brief.md"
  echo
  echo "---"
  echo "- Generated: $(date '+%Y-%m-%d %H:%M') for: ${TITLE}"
  [ -n "$MATCHES" ] && printf '%s\n' "$MATCHES" | sed 's|^|- Source: |'
} > "$OUT"
echo "brief: $OUT"

if [ "$SHOW_PROMPT" = true ] && [ -x "$ZPROMPT" ]; then
  BTN="$("$ZPROMPT" --title "Brief ready: $TITLE" --subtitle "60-second read before you join" \
    --primary "Open brief" --url "file://$OUT" --button "Dismiss" --timeout 45 2>/dev/null || echo timeout)"
  if [ "$BTN" = "timeout" ]; then notify "Pre-meeting brief ready: $OUT"; fi
elif [ "$SHOW_PROMPT" = true ]; then
  notify "Pre-meeting brief ready: $OUT"
fi
exit 0
