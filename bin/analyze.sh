#!/bin/bash
# analyze.sh <audio.wav> - Emotional/behavioral eval for a Zaatar recording.
# Pipeline: whisperx diarization (reused if already done) -> prosody.py
#           (parselmouth + audeering wav2vec2 arousal/valence/dominance)
#           -> LLM behavioral synthesis (linguistic + acoustic evidence)
# Output: $ZAATAR_TRANSCRIPTS_DIR/<base>-behavioral.md
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

SCRIPT_PATH="$0"; [ -L "$SCRIPT_PATH" ] && SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH")"
BIN_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
. "$BIN_DIR/../lib/config.sh"

AUDIO="$1"
OUT_DIR="$ZAATAR_TRANSCRIPTS_DIR"
STATE_DIR="$ZAATAR_STATE_DIR"
HF_TOKEN="$(cat "$ZAATAR_HF_TOKEN_FILE" 2>/dev/null || true)"

# Find prosody venv python
PY=""
if [ -n "$ZAATAR_PROSODY_VENV" ] && [ -x "$ZAATAR_PROSODY_VENV/bin/python" ]; then
  PY="$ZAATAR_PROSODY_VENV/bin/python"
elif [ -x "$BIN_DIR/../prosody/.venv/bin/python" ]; then
  PY="$BIN_DIR/../prosody/.venv/bin/python"
fi

BASE="$(basename "$AUDIO" .wav)"
ANALYSIS_DIR="$OUT_DIR/analysis/$BASE"
FINAL="$OUT_DIR/${BASE}-behavioral.md"
mkdir -p "$ANALYSIS_DIR" "$STATE_DIR"

[ -f "$AUDIO" ] || { echo "ERROR: audio missing at $AUDIO"; exit 1; }
[ -n "$PY" ] || { echo "ERROR: prosody venv not found. Run: zaatar setup --prosody"; exit 1; }
[ -n "$HF_TOKEN" ] || { echo "ERROR: no HF token (needed for diarization)"; exit 1; }

# [1/3] Diarized segments (persistent; reused on re-runs)
WX_JSON="$ANALYSIS_DIR/${BASE}.json"
if [ ! -s "$WX_JSON" ]; then
  echo "[1/3] Diarization (whisperx + pyannote, ~15-30 min/hr audio)..."
  whisperx "$AUDIO" --model medium --device cpu --compute_type int8 \
    --threads 8 --diarize --hf_token "$HF_TOKEN" \
    --output_dir "$ANALYSIS_DIR" --output_format json \
    > "$ANALYSIS_DIR/whisperx.log" 2>&1 \
    || { echo "ERROR: diarization failed"; tail -5 "$ANALYSIS_DIR/whisperx.log"; exit 1; }
else
  echo "[1/3] Reusing existing diarization."
fi
[ -s "$WX_JSON" ] || { echo "ERROR: whisperx JSON missing after run"; exit 1; }

# [2/3] Acoustic analysis
ACOUSTIC="$ANALYSIS_DIR/acoustic-read.md"
echo "[2/3] Prosody + emotion analysis..."
"$PY" "$BIN_DIR/../prosody/prosody.py" \
  --wav "$AUDIO" --segments "$WX_JSON" --out "$ACOUSTIC" \
  || { echo "ERROR: prosody analysis failed"; exit 1; }

# [3/3] LLM synthesis: merge transcript evidence with acoustic evidence
echo "[3/3] Behavioral synthesis..."
RAW_MD="$OUT_DIR/${BASE}-raw.md"
PROMPT="$(cat <<'PROMPT'
You are producing a behavioral/emotional evaluation of a recorded conversation (often an interview). The conversation may be multilingual. The input contains: (1) a diarized transcript (JSON segments with speaker labels and timestamps), (2) an Acoustic Read with per-speaker prosody statistics and arousal/valence/dominance trajectories, and possibly (3) a raw Whisper transcript.

Produce a markdown document with exactly these sections:

# Behavioral & Emotional Eval

## Reliability
Transcript quality (corruption, hallucination artifacts), diarization quality (speaker label consistency), and this disclaimer verbatim: "Acoustic values are relative within-speaker signals only; remote audio is compressed and the emotion model is English-trained. This is an interviewer aid for follow-up probing, never a hiring decision input or a document to share."

## Speaker Map
Map diarization labels (SPEAKER_00 etc.) to likely identities from context. If the input includes a participant list from the calendar invite, treat it as the authoritative roster and name spellings. State confidence.

## Scorecard
For each non-host speaker, a markdown table:

| Parameter | Score | Confidence | Evidence |
|---|---|---|---|

Six parameters, scored 1-5 with these anchors:
- Clarity & Structure: 1 = rambling, ideas fragmentary; 3 = mostly coherent, some meandering; 5 = ordered reasoning, ideas land cleanly.
- Concision / Focus: 1 = drifts off-question, padded answers; 3 = gets there with detours; 5 = answers the question asked, stops when done.
- Assertiveness: 1 = never takes a position; 3 = takes positions but yields quickly under pushback; 5 = states and defends positions with reasons.
- Conversational Dominance: 1 = minimal airtime, follows only; 3 = proportional share; 5 = controls airtime and topics (use airtime/turn statistics from the Acoustic Read; this is descriptive, not good or bad).
- Listening & Collaboration: 1 = talks past others, interrupts, ignores prior points; 3 = acknowledges but rarely builds; 5 = builds on others' points, yields appropriately, credits others.
- Confidence: 1 = pervasive hedging and self-undercutting; 3 = mixed; 5 = definitive claims held under challenge. Mark this row's Confidence column no higher than Medium (text+prosody confidence inference is the least reliable).

Scorecard rules:
- Every score cites at least one quote with timestamp in the Evidence cell (short fragments; this is a table, keep cells tight).
- Confidence column = High/Medium/Low based on sample size and evidence agreement.
- A speaker with under ~3 minutes of speaking time gets one row: "Insufficient sample" - no scores.
- Interpret scores against role: a candidate dominating an interview differs from a peer dominating a standup. Add a one-line "Role context:" note under each table.
- Aggression is NOT scored. If genuinely hostile or belittling behavior appears, add a flagged line "Aggression flag:" under the table with quotes; otherwise omit entirely.
- Scores are relative to the norms of this conversation type, not absolute personality judgments.

## Confidence Trajectory
For each non-host speaker: how confidence evolved across the conversation, merging BOTH evidence types. Linguistic: hedging, restarts, fillers, definitive claims. Acoustic: pitch deviation from own baseline, speech rate shifts, response latency, arousal/dominance trends across early/mid/late. Cite timestamps. Where linguistic and acoustic evidence AGREE, say so (strongest signal). Where they conflict, flag it (e.g., confident words with rising pitch and latency = rehearsed answer worth probing).

## Stress & Engagement Moments
Chronological list of notable moments per speaker: arousal deviations from the Acoustic Read matched to what was being discussed at that timestamp. For each: [MM:SS], the topic/question, the acoustic signal, the linguistic behavior, and a one-line "what to probe" suggestion.

## Behavioral Evidence
For each non-host speaker, the standard trait read - direct quotes with timestamps as evidence, or "Insufficient evidence": hedging vs certainty, assertiveness under challenge, ownership language, directness, self-advocacy. No numeric scores or verdicts; evidence lists with at most a one-line pattern observation each.

Rules: do not invent content not present in the input. Base quotes on the transcript as given. If diarization labels are inconsistent (same voice split across labels), note it and merge cautiously. Output only the markdown document.
PROMPT
)"

INPUT="$ANALYSIS_DIR/synthesis-input.md"
{
  ATT_FILE="${AUDIO%.wav}.attendees"
  if [ -s "$ATT_FILE" ]; then
    echo "## Participants (from calendar invite)"
    head -1 "$ATT_FILE"
    echo
  fi
  echo "## Diarized segments (JSON)"
  echo '```json'
  # segments only, trimmed to keep prompt within budget
  jq '{segments: [.segments[] | {start, end, speaker, text}]}' "$WX_JSON" 2>/dev/null \
    | head -c 120000 || cat "$WX_JSON" | head -c 120000
  echo
  echo '```'
  echo
  cat "$ACOUSTIC"
  if [ -s "$RAW_MD" ]; then
    echo
    echo "## Raw whisper transcript (reference for exact wording)"
    head -c 40000 "$RAW_MD"
  fi
} > "$INPUT"

OK=false
if zaatar_llm_available; then
  for ATTEMPT in 1 2; do
    if zaatar_llm "$PROMPT" \
        < "$INPUT" > "$ANALYSIS_DIR/synthesis.md" 2>"$ANALYSIS_DIR/claude.err" \
        && [ -s "$ANALYSIS_DIR/synthesis.md" ]; then
      OK=true; break
    fi
    echo "WARN: synthesis attempt $ATTEMPT failed"
  done
fi

if [ "$OK" = true ]; then
  {
    cat "$ANALYSIS_DIR/synthesis.md"
    echo
    echo "---"
    echo "- Source audio: ${AUDIO}"
    echo "- Acoustic read: ${ACOUSTIC}"
    echo "- Processed: $(date '+%Y-%m-%d %H:%M') (local; prosody + AVD + LLM)"
  } > "$FINAL"
else
  echo "WARN: LLM synthesis failed; keeping acoustic read only"
  {
    echo "# Behavioral & Emotional Eval (acoustic only - synthesis failed)"
    echo
    cat "$ACOUSTIC"
  } > "$FINAL"
fi

echo "Done: $FINAL"
ZP="$BIN_DIR/../native/zaatarprompt/zaatarprompt"
[ -x "$ZP" ] && nohup "$ZP" --title "Emotional eval ready" --subtitle "${BASE}" \
  --primary "OK" --timeout 60 >/dev/null 2>&1 &
osascript -e "display notification \"Emotional eval ready: ${BASE}\" with title \"Zaatar\"" 2>/dev/null || true
