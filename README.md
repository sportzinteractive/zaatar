# Zaatar

Local-first meeting recorder and transcriber for macOS. Records mic + system
audio natively, transcribes with whisper.cpp, optionally diarizes speakers,
and produces clean meeting notes via the Claude CLI. Calendar-aware: prompts
you when a Google Meet event starts, auto-stops when it ends.

Everything runs on your machine. The only data that leaves it is the raw
transcript text sent to the Claude API for cleanup (skip by not installing
the `claude` CLI; you keep the timestamped raw transcript).

## Components

- `bin/rec` - start/stop/status. Native capture -> wav -> background transcription.
- `bin/transcribe.sh` - whisper.cpp -> optional whisperx+pyannote diarization -> Claude cleanup (summary, key points, transcripts). VAD junk guard skips no-speech recordings.
- `bin/meet-watch.sh` - calendar watcher (launchd, every 60s): floating start prompt at meeting start ("Join & Record" opens the Meet link), auto-stop 2 min after the event ends, wav retention.
- `bin/live-transcribe.sh` - rough live transcript while recording (small model).
- `native/zaatarcap` - Swift capture CLI: mic + system audio via Core Audio process tap (macOS 14.2+), drift-corrected aggregate device, 16kHz mono wav. Falls back to mic-only.
- `native/zaatarprompt` - floating non-activating prompt panel (Granola-style).
- `native/zaatarviewer` - transcript browser with live view.
- `native/zaatarbar` - menu bar app: record/stop, stray-recorder detection, transcription-failure alerts with retry.

## Requirements

- macOS 14.2+ (system-audio process tap), Xcode CLT (`swiftc`)
- `brew install ffmpeg jq whisper-cpp`
- whisper models in `~/.local/share/whisper-models/`: `ggml-large-v3.bin` (final), `ggml-base.bin` (live) from [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp)
- [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) for cleanup (optional but recommended)
- Optional diarization: `pipx install whisperx`, Hugging Face token in `~/.cache/huggingface/token` with pyannote access
- Optional VAD junk guard: `python3 -m venv vad/.venv && vad/.venv/bin/pip install -r vad/requirements.txt`
- Optional calendar prompts: any CLI that prints Google-Calendar-style event JSON (e.g. gogcli: `gog calendar events --today -j --results-only`)

## Install

```sh
./scripts/build.sh                       # compile + install app bundles
mkdir -p ~/.config/zaatar
cp config.example.sh ~/.config/zaatar/config   # edit to taste
bin/rec start my-meeting                 # first run prompts for mic + system audio
bin/rec stop
```

Calendar watcher (set `ZAATAR_CALENDAR_CMD` in the config first):

```sh
sed "s|__ZAATAR_DIR__|$(pwd)|" launchd/org.zaatar.meet-watch.plist \
  > ~/Library/LaunchAgents/org.zaatar.meet-watch.plist
launchctl load ~/Library/LaunchAgents/org.zaatar.meet-watch.plist
```

Menu bar app: `open ~/Applications/ZaatarBar.app` (registers itself as a login item).

## Configuration

All settings live in `~/.config/zaatar/config` (plain `KEY="value"` lines,
read by both the shell scripts and the native apps). See `config.example.sh`
for the full list: directories, models, spoken languages for the cleanup
prompt, mic gain floor, VAD threshold, wav retention.

## macOS permission notes (hard-won)

- Recording is done by `ZaatarCap.app` so the TCC grants (Microphone +
  System Audio Recording) belong to the bundle - recording works when
  started from launchd, the menu bar, or a terminal.
- Ad-hoc signing means every rebuild invalidates the grants; macOS
  re-prompts once. This is expected.
- Never start a recording from a sandboxed shell (TCC attributes the
  request to the sandbox parent and SIGKILLs the recorder).
- Browser AGC (Meet in Chrome) silently drags the macOS input volume down;
  `rec` re-asserts a floor every 30s while recording (`ZAATAR_MIC_GAIN_FLOOR`).

## Consent

You are recording people. Recording-consent laws vary by jurisdiction
(some require all-party consent). Tell your participants, get consent,
and check your local law before using Zaatar.

## License

MIT
