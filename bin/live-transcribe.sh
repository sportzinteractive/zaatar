#!/bin/bash
# live-transcribe.sh <recording.wav> - rough live transcript for an in-progress recording
# Incrementally transcribes new audio (small whisper model) every ~30s into
# $ZAATAR_STATE_DIR/live-<base>.txt for the Zaatar viewer. Final quality
# transcript still comes from transcribe.sh after rec stop.
#
# Reads raw PCM directly (16kHz mono s16, as zaatarcap writes it) because the
# WAV header of an in-progress AVAudioFile says 0 frames until close.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_PATH="$0"; [ -L "$SCRIPT_PATH" ] && SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH")"
BIN_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
. "$BIN_DIR/../lib/config.sh"

WAV="${1:?usage: live-transcribe.sh <recording.wav>}"
STATE_DIR="$ZAATAR_STATE_DIR"
MODEL="$ZAATAR_LIVE_MODEL"
WHISPER="$(command -v whisper-cli)"
BASE="$(basename "$WAV" .wav)"
LIVE="$STATE_DIR/live-${BASE}.txt"
BPS=32000        # bytes/sec at 16kHz mono s16
CHUNK=30         # min seconds of new audio before a pass
MAXCHUNK=120     # cap per pass so we stay near-live

[ -f "$MODEL" ] || exit 0
[ -n "$WHISPER" ] || exit 0

# Locate the start of PCM data: CoreAudio WAVs often carry a FLLR padding
# chunk, so data does NOT start at byte 44. Find the 'data' chunk marker.
find_data_offset() {
  local off
  off="$(head -c 16384 "$WAV" | LC_ALL=C grep -abo -m1 'data' | head -1 | cut -d: -f1 || true)"
  [ -n "$off" ] && echo $(( off + 8 )) || echo ""
}

DATA_OFF=""
for _ in $(seq 1 10); do
  [ -f "$WAV" ] && DATA_OFF="$(find_data_offset)" && [ -n "$DATA_OFF" ] && break
  sleep 2
done
[ -n "$DATA_OFF" ] || exit 0

TMP="$(mktemp -d /tmp/zaatar-live.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

recorder_alive() { pgrep -f "zaatarcap .*${BASE}\.wav" >/dev/null 2>&1; }

: > "$LIVE"
DONE_S=0
while recorder_alive; do
  SIZE="$(stat -f %z "$WAV" 2>/dev/null || echo 0)"
  AVAIL=$(( (SIZE - DATA_OFF) / BPS ))
  NEW=$(( AVAIL - DONE_S ))
  if [ "$NEW" -lt "$CHUNK" ]; then
    sleep 10
    continue
  fi
  N=$NEW
  [ "$N" -gt "$MAXCHUNK" ] && N=$MAXCHUNK
  # || true: head closes the pipe early and tail dies with SIGPIPE, which
  # pipefail would otherwise turn into a fatal error
  { tail -c +"$(( DATA_OFF + DONE_S * BPS + 1 ))" "$WAV" | head -c "$(( N * BPS ))" > "$TMP/chunk.pcm"; } || true
  [ -s "$TMP/chunk.pcm" ] || { sleep 10; continue; }
  ffmpeg -hide_banner -loglevel error -y -f s16le -ar 16000 -ac 1 -i "$TMP/chunk.pcm" "$TMP/chunk.wav"
  # LC_ALL=C: non-ASCII output breaks sed under launchd's locale
  TEXT="$("$WHISPER" -m "$MODEL" -f "$TMP/chunk.wav" -l auto -mc 0 -nt 2>/dev/null | LC_ALL=C sed '/^[[:space:]]*$/d' || true)"
  if [ -n "$TEXT" ]; then
    printf '[%02d:%02d] %s\n' $(( DONE_S / 60 )) $(( DONE_S % 60 )) "$TEXT" >> "$LIVE"
  fi
  DONE_S=$(( DONE_S + N ))
done
