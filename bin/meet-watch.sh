#!/bin/bash
# meet-watch.sh - Granola-style meeting prompt (run every minute via launchd)
# When a calendar event with a Google Meet link is starting, prompt to record.
# When that event ends and the watcher started a recording, auto-stop.
# Requires ZAATAR_CALENDAR_CMD to be configured; exits quietly otherwise.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

SCRIPT_PATH="$0"; [ -L "$SCRIPT_PATH" ] && SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH")"
BIN_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
. "$BIN_DIR/../lib/config.sh"

STATE_DIR="$ZAATAR_STATE_DIR"
REC="$BIN_DIR/rec"
# Floating panel (prints clicked label or "timeout"); falls back to nothing gracefully
ZPROMPT="$BIN_DIR/../native/zaatarprompt/zaatarprompt"
CACHE="$STATE_DIR/events-cache.json"
CACHE_TTL=600  # re-fetch calendar every 10 min
mkdir -p "$STATE_DIR"

[ -n "$ZAATAR_CALENDAR_CMD" ] || exit 0

NOW_EPOCH="$(date +%s)"

# --- WAV retention (daily): delete old recordings once their final transcript exists ---
RETAIN_MARK="$STATE_DIR/retention-last"
if [ "${ZAATAR_WAV_RETENTION_DAYS:-0}" -gt 0 ] && { [ ! -f "$RETAIN_MARK" ] || [ $(( NOW_EPOCH - $(stat -f %m "$RETAIN_MARK") )) -gt 86400 ]; }; then
  touch "$RETAIN_MARK"
  find "$ZAATAR_REC_DIR" -name '*.wav' -mtime +"$ZAATAR_WAV_RETENTION_DAYS" 2>/dev/null | while read -r W; do
    B="$(basename "$W" .wav)"
    # keep the wav if there is no final transcript (failed/missing = still needed for retry)
    if [ -s "$ZAATAR_TRANSCRIPTS_DIR/$B.md" ]; then
      rm -f "$W" "$W.level" "${W%.wav}.attendees" "${W%.wav}.title"
      echo "$(date '+%F %T') INFO: retention deleted $W" >> "$STATE_DIR/meet-watch.log"
    fi
  done
fi

# --- fetch today's events (cached) ---
if [ ! -f "$CACHE" ] || [ $(( NOW_EPOCH - $(stat -f %m "$CACHE") )) -gt $CACHE_TTL ]; then
  FETCH_OK=false
  for _ in 1 2 3; do
    if bash -c "$ZAATAR_CALENDAR_CMD" > "$CACHE.tmp" 2>>"$STATE_DIR/meet-watch.log"; then
      FETCH_OK=true; break
    fi
    sleep 5
  done
  if [ "$FETCH_OK" = true ]; then
    mv "$CACHE.tmp" "$CACHE"
  else
    rm -f "$CACHE.tmp"
    echo "$(date '+%F %T') WARN: calendar fetch failed" >> "$STATE_DIR/meet-watch.log"
    # Flaky network must not kill stop prompts: fall back to stale cache if we have one
    if [ ! -f "$CACHE" ]; then exit 0; fi
    echo "$(date '+%F %T') INFO: using stale events cache" >> "$STATE_DIR/meet-watch.log"
  fi
fi

recording() { [ -f "$STATE_DIR/rec.pid" ] && kill -0 "$(cat "$STATE_DIR/rec.pid")" 2>/dev/null; }

# --- long-recording guard: any recording running >2h gets a "still in a meeting?" prompt ---
GUARD="$STATE_DIR/guard-prompted"
if recording; then
  R_ELAPSED=$(( NOW_EPOCH - $(stat -f %m "$STATE_DIR/rec.pid") ))
  LAST_GUARD=0
  [ -f "$GUARD" ] && LAST_GUARD="$(stat -f %m "$GUARD")"
  if [ "$R_ELAPSED" -gt 7200 ] && [ $(( NOW_EPOCH - LAST_GUARD )) -gt 1800 ]; then
    touch "$GUARD"
    HRS=$(( R_ELAPSED / 3600 )); MINS=$(( (R_ELAPSED % 3600) / 60 ))
    BTN="$("$ZPROMPT" --title "Still in a meeting?" --subtitle "Recording for ${HRS}h ${MINS}m" \
      --primary "Stop (fast)" --button "Stop (full)" --button "Keep recording" --timeout 55 2>/dev/null || echo "gave up")"
    case "$BTN" in
      "Stop (fast)") "$REC" stop --fast >>"$STATE_DIR/meet-watch.log" 2>&1; rm -f "$STATE_DIR/meet-watch.active" "$GUARD"; exit 0 ;;
      "Stop (full)") "$REC" stop >>"$STATE_DIR/meet-watch.log" 2>&1; rm -f "$STATE_DIR/meet-watch.active" "$GUARD"; exit 0 ;;
      *) : ;;  # keep or timed out; re-ask in 30 min
    esac
  fi
else
  rm -f "$GUARD"
fi

# --- pre-meeting brief: for a Meet event starting within ZAATAR_BRIEF_LEAD
# seconds, generate a digest of prior meetings with the same attendees ---
if [ "${ZAATAR_BRIEF_LEAD:-0}" -gt 0 ]; then
  UPCOMING="$(jq -r --arg now "$NOW_EPOCH" --arg lead "$ZAATAR_BRIEF_LEAD" '
    def toepoch:
      capture("(?<dt>[0-9-]+T[0-9:]{8})(\\.[0-9]+)?(?<tz>Z|(?<sign>[+-])(?<oh>[0-9]{2}):?(?<om>[0-9]{2}))$") as $c
      | ($c.dt | strptime("%Y-%m-%dT%H:%M:%S") | mktime)
        - (if $c.tz == "Z" then 0
           else (if $c.sign == "+" then 1 else -1 end) * (($c.oh|tonumber)*3600 + ($c.om|tonumber)*60)
           end);
  def joinurl:
    (.hangoutLink // empty),
    ([.conferenceData.entryPoints[]? | select(.entryPointType == "video") | .uri] | first // empty),
    (((.location // "") + " " + (.description // ""))
      | (try (capture("(?<u>https://[a-zA-Z0-9./?=_%:#&~+-]*(zoom\\.us/(j|my|s)/|teams\\.microsoft\\.com/l/meetup-join|teams\\.live\\.com/meet|webex\\.com/(meet|join)/)[a-zA-Z0-9./?=_%:#&~+-]*)").u) catch empty)),
    "";
    [ .[]
      | select(first(joinurl) != "")
      | select((.attendees // [] | map(select(.self == true and .responseStatus == "declined")) | length) == 0)
      | select(.start.dateTime)
      | (.start.dateTime | toepoch) as $s
      | select(($now | tonumber) >= ($s - ($lead | tonumber)) and ($now | tonumber) < ($s - 180))
      | {id: .id, summary: (.summary // "meeting"),
         attendees: ([.attendees[]? | select(.resource != true) | (.displayName // .email)] | join(", "))}
    ] | first // empty | @json' "$CACHE" 2>/dev/null || true)"
  if [ -n "$UPCOMING" ] && [ -x "$BIN_DIR/brief.sh" ]; then
    UP_ID="$(printf '%s' "$UPCOMING" | jq -r '.id')"
    BRIEFED="$STATE_DIR/briefed-${UP_ID}"
    if [ ! -f "$BRIEFED" ]; then
      touch "$BRIEFED"
      UP_TITLE="$(printf '%s' "$UPCOMING" | jq -r '.summary')"
      UP_ATT="$(printf '%s' "$UPCOMING" | jq -r '.attendees // ""')"
      if [ -n "$UP_ATT" ]; then
        echo "$(date '+%F %T') BRIEF: generating for '$UP_TITLE'" >> "$STATE_DIR/meet-watch.log"
        nohup "$BIN_DIR/brief.sh" --title "$UP_TITLE" --attendees "$UP_ATT" \
          >> "$STATE_DIR/meet-watch.log" 2>&1 &
      fi
    fi
  fi
fi

# --- find a Meet event active now (start-60s .. end), not declined by me ---
ACTIVE="$(jq -r --arg now "$NOW_EPOCH" '
  # RFC3339 -> epoch; jq mktime is UTC-based so apply the numeric offset ourselves
  def toepoch:
    capture("(?<dt>[0-9-]+T[0-9:]{8})(\\.[0-9]+)?(?<tz>Z|(?<sign>[+-])(?<oh>[0-9]{2}):?(?<om>[0-9]{2}))$") as $c
    | ($c.dt | strptime("%Y-%m-%dT%H:%M:%S") | mktime)
      - (if $c.tz == "Z" then 0
         else (if $c.sign == "+" then 1 else -1 end) * (($c.oh|tonumber)*3600 + ($c.om|tonumber)*60)
         end);
  def joinurl:
    (.hangoutLink // empty),
    ([.conferenceData.entryPoints[]? | select(.entryPointType == "video") | .uri] | first // empty),
    (((.location // "") + " " + (.description // ""))
      | (try (capture("(?<u>https://[a-zA-Z0-9./?=_%:#&~+-]*(zoom\\.us/(j|my|s)/|teams\\.microsoft\\.com/l/meetup-join|teams\\.live\\.com/meet|webex\\.com/(meet|join)/)[a-zA-Z0-9./?=_%:#&~+-]*)").u) catch empty)),
    "";
  [ .[]
    | select(first(joinurl) != "")
    | select((.attendees // [] | map(select(.self == true and .responseStatus == "declined")) | length) == 0)
    | select(.start.dateTime)
    | (.start.dateTime | toepoch) as $s
    | (.end.dateTime   | toepoch) as $x
    | select(($now | tonumber) >= ($s - 60) and ($now | tonumber) < $x)
    | {id: .id, summary: (.summary // "meeting"), start: $s, end: $x, meet: first(joinurl),
       attendees: ([.attendees[]? | select(.resource != true) | (.displayName // .email)] | join(", "))}
  ] | first // empty | @json' "$CACHE" 2>/dev/null || true)"

WATCH_META="$STATE_DIR/meet-watch.active"   # exists when watcher started a recording: "<eventId> <endEpoch>"

# Passive macOS notification (argv form: immune to quotes/emojis in titles)
notify() {
  osascript -e 'on run argv
display notification (item 1 of argv) with title "Zaatar"
end run' -- "$1" >/dev/null 2>&1 || true
}

# --- auto-stop: watcher-started recording whose event ended >2 min ago ---
if [ -f "$WATCH_META" ] && recording; then
  read -r W_ID W_END < "$WATCH_META"
  STILL_ACTIVE="$(printf '%s' "$ACTIVE" | jq -r --arg id "$W_ID" 'select(.id == $id) | .id' 2>/dev/null || true)"
  if [ -z "$STILL_ACTIVE" ] && [ "$NOW_EPOCH" -gt $(( W_END + 120 )) ]; then
    "$REC" stop --fast >>"$STATE_DIR/meet-watch.log" 2>&1
    rm -f "$WATCH_META"
    notify "Stopped recording, transcribing. Meeting ran over? Restart from the menu bar."
  fi
  exit 0
fi
[ -f "$WATCH_META" ] && ! recording && rm -f "$WATCH_META"

# --- start prompt: ask before recording; unanswered prompt = not recorded ---
[ -z "$ACTIVE" ] && exit 0
recording && exit 0

EV_ID="$(printf '%s' "$ACTIVE" | jq -r '.id')"
EV_TITLE="$(printf '%s' "$ACTIVE" | jq -r '.summary')"
EV_START="$(printf '%s' "$ACTIVE" | jq -r '.start')"
EV_END="$(printf '%s' "$ACTIVE" | jq -r '.end')"
EV_MEET="$(printf '%s' "$ACTIVE" | jq -r '.meet')"
PROMPTED="$STATE_DIR/prompted-${EV_ID}"
[ -f "$PROMPTED" ] && exit 0

# zaatarprompt opens --url only when the PRIMARY button is clicked
ZARGS=(--title "$EV_TITLE" --subtitle "$(date -r "$EV_START" +%H:%M) - $(date -r "$EV_END" +%H:%M) | not recorded if ignored")
if [ -n "$EV_MEET" ]; then
  ZARGS+=(--primary "Join & Record" --button "Record" --url "$EV_MEET")
else
  ZARGS+=(--primary "Record")
fi
ZARGS+=(--button "Skip" --timeout 55)
BTN="$("$ZPROMPT" "${ZARGS[@]}" 2>/dev/null || echo "timeout")"

start_recording() {
  SLUG="$(printf '%s' "$EV_TITLE" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g' | cut -c1-40)"
  # ZaatarCap.app holds its own mic TCC grant, so we can start directly from launchd
  "$REC" start "${SLUG:-meeting}" >>"$STATE_DIR/meet-watch.log" 2>&1
  echo "$EV_ID $EV_END" > "$WATCH_META"
  # participant sidecar: biases whisper spelling + claude speaker mapping downstream
  EV_ATT="$(printf '%s' "$ACTIVE" | jq -r '.attendees // ""')"
  WAV="$(cat "$STATE_DIR/rec.meta" 2>/dev/null || true)"
  if [ -n "$EV_ATT" ] && [ -n "$WAV" ]; then
    printf '%s\n' "$EV_ATT" > "${WAV%.wav}.attendees"
  fi
  # title sidecar: preserves the real event title (the slug is lossy - lowercased,
  # punctuation stripped, truncated at 40 chars); transcribe.sh embeds it in the md
  if [ -n "$WAV" ]; then
    printf '%s\n' "$EV_TITLE" > "${WAV%.wav}.title"
  fi
}

echo "$(date '+%F %T') PROMPT: '$EV_TITLE' -> $BTN" >> "$STATE_DIR/meet-watch.log"
case "$BTN" in
  Skip)
    touch "$PROMPTED"
    ;;
  "Record"|"Join & Record")
    touch "$PROMPTED"
    start_recording
    ;;
  *)
    # timed out / prompt unavailable: RE-OFFER each cycle until 10 min into the
    # meeting (unanswered prompts silently lose meetings), then give up with a
    # notification. Never auto-record on timeout: auto-recording meetings
    # nobody joined produces junk empty-room "transcripts".
    if [ "$NOW_EPOCH" -ge $(( EV_START + 600 )) ]; then
      touch "$PROMPTED"
      notify "Not recording: $EV_TITLE (prompt unanswered; start from the menu bar to record)"
    fi
    ;;
esac
