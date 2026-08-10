#!/bin/bash
# transcribe.sh [--fast] <audio.wav>
# Pipeline: whisper.cpp original-language transcript
#           -> optional speaker diarization (whisperx + pyannote)
#           -> Claude cleanup: coherent transcript + summary
# --fast: skip diarization
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

SCRIPT_PATH="$0"; [ -L "$SCRIPT_PATH" ] && SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH")"
BIN_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
. "$BIN_DIR/../lib/config.sh"

FAST=false
if [ "${1:-}" = "--fast" ]; then FAST=true; shift; fi
AUDIO="$1"
MODEL="$ZAATAR_MODEL"
OUT_DIR="$ZAATAR_TRANSCRIPTS_DIR"
STATE_DIR="$ZAATAR_STATE_DIR"
HF_TOKEN="$(cat "$ZAATAR_HF_TOKEN_FILE" 2>/dev/null || true)"
mkdir -p "$OUT_DIR" "$STATE_DIR"

BASE="$(basename "$AUDIO" .wav)"
WHISPER="$(command -v whisper-cli)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -f "$MODEL" ] || { echo "ERROR: model missing at $MODEL"; exit 1; }
[ -f "$AUDIO" ] || { echo "ERROR: audio missing at $AUDIO"; exit 1; }

# --- VAD junk guard: a recording with no real speech makes whisper hallucinate
# an entire fake transcript. Skip the pipeline instead.
VAD_PY="$BIN_DIR/../vad/.venv/bin/python"
VAD_SCRIPT="$BIN_DIR/../vad/vad_check.py"
if [ "${ZAATAR_VAD_MIN_SPEECH:-0}" -gt 0 ] && [ -x "$VAD_PY" ] && [ -f "$VAD_SCRIPT" ]; then
  SPEECH_SECS="$("$VAD_PY" "$VAD_SCRIPT" "$AUDIO" 2>/dev/null || echo "")"
  if [ -n "$SPEECH_SECS" ] && [ "$SPEECH_SECS" -lt "$ZAATAR_VAD_MIN_SPEECH" ]; then
    MD="$OUT_DIR/${BASE}.md"
    {
      echo "# ${BASE} - no speech detected"
      echo
      echo "VAD found ${SPEECH_SECS}s of speech in this recording; transcription skipped (empty-room audio would produce a hallucinated transcript)."
      echo
      echo "- Source audio: ${AUDIO}"
      echo "- Checked: $(date '+%Y-%m-%d %H:%M')"
    } > "$MD"
    echo "Done: $MD (junk guard: ${SPEECH_SECS}s speech, pipeline skipped)"
    osascript -e "display notification \"No speech detected: ${BASE} - transcription skipped\" with title \"Zaatar\"" 2>/dev/null || true
    exit 0
  fi
fi

# Participant sidecar (written by meet-watch from the calendar invite):
# biases whisper toward correct name spellings + grounds claude's speaker mapping
ATT_FILE="$(dirname "$AUDIO")/${BASE}.attendees"
ATTENDEES=""
[ -s "$ATT_FILE" ] && ATTENDEES="$(head -1 "$ATT_FILE")"

echo "[1/3] Original-language transcript (whisper.cpp)..."
WPROMPT=()
[ -n "$ATTENDEES" ] && WPROMPT=(--prompt "Meeting participants: ${ATTENDEES}." --carry-initial-prompt)
"$WHISPER" -m "$MODEL" -f "$AUDIO" -l auto -mc 0 "${WPROMPT[@]}" -osrt -of "$TMP/orig" 2>&1 | tail -1

DIARIZED_OK=false
if [ "$FAST" = false ] && [ -n "$HF_TOKEN" ] && command -v whisperx >/dev/null; then
  echo "[2/3] Speaker diarization (whisperx + pyannote)..."
  # medium model: speaker labels come from pyannote, not whisper;
  # canonical text comes from the step-1 model
  if whisperx "$AUDIO" --model medium --device cpu --compute_type int8 \
      --threads 8 --diarize --hf_token "$HF_TOKEN" \
      --output_dir "$TMP/wx" --output_format srt >"$TMP/whisperx.log" 2>&1; then
    DIARIZED_OK=true
  else
    echo "WARN: diarization failed, continuing without speaker labels (see log)"
    tail -5 "$TMP/whisperx.log" || true
  fi
else
  echo "[2/3] Skipping diarization."
fi

# Raw output (always kept, audit trail)
RAW_MD="$OUT_DIR/${BASE}-raw.md"
{
  echo "# Raw Transcript: ${BASE}"
  echo
  echo "- Source audio: ${AUDIO}"
  echo "- Transcribed: $(date '+%Y-%m-%d %H:%M') (local; diarized: ${DIARIZED_OK})"
  [ -n "$ATTENDEES" ] && { echo "- Participants (from calendar invite): ${ATTENDEES}"; }
  echo
  echo "## Original (timestamped, as spoken)"
  echo
  echo '```'
  cat "$TMP/orig.srt" 2>/dev/null || echo "(transcript failed)"
  echo '```'
  if [ "$DIARIZED_OK" = true ]; then
    echo
    echo "## Diarized (speaker-labeled)"
    echo
    echo '```'
    cat "$TMP"/wx/*.srt 2>/dev/null || echo "(diarization output missing)"
    echo '```'
  fi
} > "$RAW_MD"

echo "[3/3] Claude cleanup (transcript + summary)..."
MD="$OUT_DIR/${BASE}.md"
CLEANUP_PROMPT="$(cat <<PROMPT
You are cleaning up a raw Whisper transcript of a meeting. The conversation is in ${ZAATAR_LANGS}. The input below contains a timestamped original-language transcript, and possibly a speaker-diarized version of the same audio.

Produce a markdown document with exactly these sections:

# Meeting Transcript (Cleaned)

## Summary
5-10 sentences covering what the meeting was about and what was discussed.

## Key Points
Bulleted list: decisions, facts stated, action items, notable opinions.

## Transcript (Original)
The conversation as spoken, cleaned up: merge fragments into coherent dialogue turns, keep any code-switching between languages EXACTLY as spoken (do not translate this section), fix obvious mis-transcriptions of names/terms and keep them consistent throughout. If the input header lists Participants (from calendar invite), treat those as the authoritative name spellings and use them to identify speakers, and REMOVE hallucination artifacts (repeated loops, "Subtitles by the Amara.org community", nonsense repetitions). If speaker labels are available, use them; in a 2-person conversation infer speakers from context and label them by name if names are evident. Keep approximate timestamps every few turns.

## Transcript (English)
Faithful, natural English translation of the same cleaned dialogue, same speaker labels. Translate non-English portions properly; keep technical terms as-is. If the original is already entirely in English, write "Same as above." instead of repeating it.

Rules: do not invent content that is not in the input. If a passage is unintelligible, mark it [unclear]. Output only the markdown document, nothing else.
PROMPT
)"

# Long meetings: two full transcripts exceed the model's max output tokens
# (observed on 75-min meetings: truncated/tail-only output). Swap the two
# transcript sections for condensed detailed notes; the raw file keeps the full record.
RAW_BYTES="$(wc -c < "$RAW_MD")"
if [ "$RAW_BYTES" -gt 60000 ]; then
  echo "Long transcript ($RAW_BYTES bytes): using condensed cleanup prompt (no full transcripts)."
  CLEANUP_PROMPT="$(cat <<PROMPT
You are cleaning up a raw Whisper transcript of a LONG meeting. The conversation is in ${ZAATAR_LANGS}. The input below contains a timestamped original-language transcript, and possibly a speaker-diarized version of the same audio. The input is too long to reproduce as a full cleaned transcript, so produce condensed notes instead.

Produce a markdown document with exactly these sections:

# Meeting Notes (Long Meeting, Condensed)

## Summary
5-10 sentences covering what the meeting was about and what was discussed.

## Key Points
Bulleted list: decisions, facts stated, action items, notable opinions.

## Detailed Notes
Topic-by-topic narrative of the whole meeting in English, in chronological order, with approximate timestamps per topic. Attribute statements to speakers (infer speakers from context if no labels; use names if evident). Include every substantive exchange, but paraphrase; quote verbatim (in the original language) only where wording matters (commitments, disagreements, numbers, dates). Fix obvious mis-transcriptions of names/terms and keep them consistent. If the input header lists Participants (from calendar invite), treat those as the authoritative name spellings and use them to identify speakers. IGNORE hallucination artifacts (repeated loops, "Subtitles by the Amara.org community", nonsense repetitions).

Rules: do not invent content that is not in the input. If a passage is unintelligible, mark it [unclear]. Output only the markdown document, nothing else. Note at the end: "Full verbatim transcript: see the raw transcript file."
PROMPT
)"
fi

CLEAN_OK=false
RC=0
if command -v claude >/dev/null; then
  for ATTEMPT in 1 2; do
    RC=0
    env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude -p --model "$ZAATAR_CLEANUP_MODEL" "$CLEANUP_PROMPT" \
      < "$RAW_MD" > "$TMP/clean.md" 2>"$TMP/claude.err" || RC=$?
    if [ "$RC" -eq 0 ] && [ -s "$TMP/clean.md" ]; then CLEAN_OK=true; break; fi
    echo "WARN: Claude cleanup attempt $ATTEMPT failed (exit $RC)"
  done
fi

if [ "$CLEAN_OK" = true ]; then
  {
    cat "$TMP/clean.md"
    echo
    echo "---"
    echo "- Source audio: ${AUDIO}"
    echo "- Raw transcript: ${RAW_MD}"
    echo "- Processed: $(date '+%Y-%m-%d %H:%M') (local; diarized: ${DIARIZED_OK}; cleaned: claude ${ZAATAR_CLEANUP_MODEL})"
  } > "$MD"
else
  echo "WARN: Claude cleanup failed, using raw transcript as final output"
  ERR_KEEP="$STATE_DIR/claude-${BASE}.err"
  {
    echo "exit code: $RC"
    echo "--- stderr ---"
    cat "$TMP/claude.err" 2>/dev/null || true
    echo "--- stdout (first 2KB) ---"
    head -c 2048 "$TMP/clean.md" 2>/dev/null || true
  } > "$ERR_KEEP"
  echo "Error log kept: $ERR_KEEP"
  cp "$RAW_MD" "$MD"
fi

# Generic name ("meeting"): derive a real name from the transcript summary and rename
if [[ "$BASE" =~ -meeting$ ]] && [ "$CLEAN_OK" = true ]; then
  SLUG="$(head -40 "$MD" | env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude -p --model haiku \
    'Output ONLY a 2-5 word lowercase hyphenated slug naming this meeting based on the summary below. No other text.' \
    2>/dev/null | tail -1 | tr -cd 'a-z0-9-' | cut -c1-40 || true)"
  if [ -n "$SLUG" ] && [ "$SLUG" != "meeting" ]; then
    NEWBASE="${BASE%meeting}${SLUG}"
    mv "$MD" "$OUT_DIR/${NEWBASE}.md" && mv "$RAW_MD" "$OUT_DIR/${NEWBASE}-raw.md"
    [ -f "$AUDIO" ] && mv "$AUDIO" "$(dirname "$AUDIO")/${NEWBASE}.wav"
    [ -f "$ATT_FILE" ] && mv "$ATT_FILE" "$(dirname "$AUDIO")/${NEWBASE}.attendees"
    MD="$OUT_DIR/${NEWBASE}.md"; RAW_MD="$OUT_DIR/${NEWBASE}-raw.md"
    sed -i '' "s|${BASE}|${NEWBASE}|g" "$MD" "$RAW_MD" 2>/dev/null || true
    echo "Renamed to: $NEWBASE"
  fi
fi

echo "Done: $MD"
echo "Raw:  $RAW_MD"
osascript -e "display notification \"Transcript ready: ${BASE}\" with title \"Zaatar\"" 2>/dev/null || true
