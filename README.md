# Zaatar

**Your meetings, your machine.** Record, transcribe, diarize, and summarize meetings entirely locally. Nothing leaves your computer except the transcript text you choose to send to an LLM.

https://github.com/user-attachments/assets/zaatar-demo.mp4

## What it does

- Records mic + system audio natively (works with Meet, Zoom, Teams, Webex, anything)
- Transcribes with whisper.cpp on your GPU (Metal-accelerated on Apple Silicon)
- Identifies speakers with pyannote (GPU-accelerated, optional)
- Produces clean meeting notes: summary, key points, cleaned transcript, English translation
- Extracts commitments into a running ledger (who promised what by when)
- Generates pre-meeting briefs from your prior conversations with the same people
- Calendar-aware: prompts at meeting start, auto-stops when it ends, opens the join link

## Why local

- Your conversations never touch a third-party server for transcription or diarization
- No accounts, no subscriptions, no "we updated our privacy policy" emails
- Works offline (except the LLM cleanup step, which is optional)
- BYO-LLM: Claude CLI (default), ollama for fully offline, or any provider via `ZAATAR_LLM_CMD`
- No LLM configured? You still get timestamped, speaker-labeled transcripts

## Install

### One-line install

```sh
curl -fsSL https://raw.githubusercontent.com/sportzinteractive/zaatar/main/scripts/install.sh | bash
```

Installs dependencies, compiles the native apps, downloads whisper models, and walks through setup. Takes about 5 minutes. Re-run to update.

```sh
zaatar start my-meeting    # first run prompts for mic permission
zaatar stop                # transcribes in background, notifies when done
```

### Download

Grab `Zaatar.dmg` from [Releases](https://github.com/sportzinteractive/zaatar/releases), drag to Applications, launch. Setup runs on first open.

### Homebrew

```sh
brew install --HEAD sportzinteractive/zaatar/zaatar
zaatar setup
```

## How it works

```
Calendar event starting
        |
   [Join & Record] -----> opens Meet/Zoom/Teams link
        |
   zaatarcap (mic + system audio, 16kHz mono wav)
        |
   Event ends -> auto-stop
        |
   whisper.cpp large-v3 (Metal GPU) -----> timestamped transcript
        |
   pyannote (MPS/CUDA GPU) -----> speaker labels (optional)
        |
   LLM cleanup -----> summary, key points, clean transcript
        |
   commitments.sh -----> who-promised-what-by-when ledger
        |
   Notification: "Transcript ready"
```

## Components

| Component | What it does |
|-----------|-------------|
| `zaatarbar` | Menu bar app: record/stop, status, preferences |
| `zaatarviewer` | Transcript browser with live view during recording |
| `zaatarcap` | Native audio capture (mic + system audio, macOS 14.2+) |
| `zaatarprompt` | Floating prompt panel at meeting start |
| `zaatarcal` | Calendar integration via macOS EventKit (Google, Outlook, iCloud) |
| `transcribe.sh` | Transcription + diarization + LLM cleanup pipeline |
| `meet-watch.sh` | Calendar watcher: start prompts, auto-stop, pre-meeting briefs |
| `brief.sh` | Pre-meeting digest from prior transcripts with the same attendees |
| `commitments.sh` | Extracts action items into a trackable ledger |
| `live-transcribe.sh` | Rough live transcript while recording |

## Calendar integration

Works with any calendar configured in macOS System Settings (Google, Outlook, iCloud, Exchange) via native EventKit. No OAuth setup, no API keys. Cross-platform Google Calendar OAuth script included for non-macOS use.

Recording itself is platform-independent: captures audio at the OS level, so it works with any meeting app. Meet, Zoom, Teams, and Webex join links are detected from event fields.

## Configuration

All settings in `~/.config/zaatar/config`. Run `zaatar setup` to change them interactively, or edit directly (see `config.example.sh`).

Key settings:
- `ZAATAR_LLM_CMD` - LLM provider (empty = Claude CLI; set to ollama/llm/anything)
- `ZAATAR_LANGS` - spoken languages in your meetings
- `ZAATAR_CALENDAR_CMD` - calendar source (auto-configured by setup)
- `ZAATAR_WAV_RETENTION_DAYS` - auto-delete recordings after N days (default: 14)
- `ZAATAR_BRIEF_LEAD` - seconds before meeting to generate pre-brief (default: 900)

## Requirements

- macOS 14.2+ (system-audio capture via process tap; earlier versions: mic-only)
- Xcode Command Line Tools (`xcode-select --install`)
- The installer handles everything else: ffmpeg, jq, whisper-cpp, whisper models

Optional:
- An LLM for transcript cleanup and briefs (Claude CLI, ollama, or any provider)
- Hugging Face token for speaker diarization ([pyannote model access](https://huggingface.co/pyannote/speaker-diarization-3.1))

## Consent

You are recording people. Recording-consent laws vary by jurisdiction (some require all-party consent). Tell your participants, get consent, and check your local law before using Zaatar.

## License

MIT
