# Zaatar

**Your meetings, your machine.** Record, transcribe, diarize, and analyze meetings entirely on your computer. Nothing ever has to leave your machine -- use a local LLM like Ollama for a fully offline pipeline.

https://github.com/user-attachments/assets/86667c90-655f-4a8f-b82d-4974fa4a2693

## What it does

**Capture and transcribe**
- Records mic + system audio natively (works with Meet, Zoom, Teams, Webex, anything)
- Transcribes with whisper.cpp on your GPU (Metal-accelerated on Apple Silicon)
- Identifies speakers with pyannote (GPU-accelerated via MPS/CUDA, optional)
- Preserves multilingual code-switching (Hinglish, Spanglish, any mix) exactly as spoken
- Produces clean meeting notes: summary, key points, bilingual transcripts

**Understand your conversations**
- Behavioral Read on every transcript: per-speaker evidence of hedging, assertiveness, ownership language, directness, and confidence -- with a scored rubric
- Full emotional eval (`zaatar analyze`): prosody analysis (pitch, speech rate, pauses) + arousal/valence/dominance scoring via wav2vec2, merged with linguistic evidence into a behavioral scorecard. Built for interviews, sales calls, and 1:1s
- Live question suggestions during recording: strategic questions about meeting drift, unresolved commitments, risks being avoided

**Build a compounding corpus**
- Extracts commitments into a running ledger (who promised what by when)
- Generates pre-meeting briefs from your prior conversations with the same people -- the more you use it, the better they get
- Scans calendar event attachments (Google Docs, PDFs) for pre-meeting context
- Calendar-aware: prompts at meeting start, auto-stops when it ends, opens the join link

**Built for agents**
- Every component is a composable CLI tool, designed to be called by locally running AI agents
- BYO-LLM: Claude CLI (default), Ollama for fully offline, or any provider via `ZAATAR_LLM_CMD`
- No LLM configured? You still get timestamped, speaker-labeled transcripts

## Why local

- Your conversations never touch a third-party server for transcription, diarization, or analysis
- No accounts, no subscriptions, no "we updated our privacy policy" emails
- Works offline (LLM cleanup is optional, and can use a local model)
- Emotional eval stays on your machine: prosody data and behavioral scores never leave

## Install

### One-line install

```sh
curl -fsSL https://raw.githubusercontent.com/sportzinteractive/zaatar/main/scripts/install.sh | bash
```

Installs dependencies, compiles the native apps, downloads whisper models, and walks through setup. Takes about 5 minutes. Re-run to update.

```sh
zaatar start my-meeting    # first run prompts for mic permission
zaatar stop                # transcribes in background, notifies when done
zaatar analyze last        # run full emotional eval on the last recording
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
        |                              |
   live-transcribe.sh             live-questions.sh
   (rough transcript              (strategic question
    during recording)              suggestions every 90s)
        |
   Event ends -> auto-stop
        |
   whisper.cpp large-v3 (Metal GPU) -----> timestamped transcript
        |
   pyannote (MPS/CUDA GPU) -----> speaker labels (optional)
        |
   LLM cleanup -----> summary, key points, behavioral read, clean transcript
        |
   commitments.sh -----> who-promised-what-by-when ledger
        |
   [optional] analyze.sh -----> prosody + emotion + full behavioral eval
        |
   Notification: "Transcript ready"
```

## Behavioral Read and Emotional Eval

Every transcript includes a **Behavioral Read** (text-only): per-speaker evidence lists for hedging, assertiveness, ownership language, directness, self-advocacy, and behavior under challenge, plus a scored rubric (Clarity, Concision, Assertiveness, Dominance, Listening, Confidence).

For deeper analysis, run `zaatar analyze` to get the **full emotional eval**:

- **Prosody analysis** (parselmouth): pitch baseline and deviation, speech rate, intensity, in-turn pauses, response latency
- **Arousal/valence/dominance** (audeering wav2vec2): emotional trajectory across the conversation, split into early/mid/late phases
- **Stress and engagement moments**: chronological list of notable arousal spikes matched to what was being discussed, with "what to probe next" suggestions
- **Confidence trajectory**: where linguistic and acoustic signals agree (strongest evidence) or conflict (rehearsed answers, surface confidence masking stress)

Use cases: interview debrief, sales call review, 1:1 coaching, negotiation prep, self-improvement.

The emotional eval stays entirely local. The disclaimer is built into every output: acoustic values are relative within-speaker signals, never cross-speaker comparisons, never a hiring decision input.

## Components

| Component | What it does |
|-----------|-------------|
| `zaatarbar` | Menu bar app: record/stop, meeting picker, status, preferences |
| `zaatarviewer` | Transcript browser with live view, upcoming meetings, commitment ledger |
| `zaatarcap` | Native audio capture (mic + system audio, macOS 14.2+) |
| `zaatarprompt` | Floating prompt panel at meeting start |
| `zaatarcal` | Calendar integration via macOS EventKit (Google, Outlook, iCloud) |
| `transcribe.sh` | Transcription + diarization + LLM cleanup + behavioral read pipeline |
| `analyze.sh` | Full emotional eval: prosody + wav2vec2 emotion + LLM synthesis |
| `meet-watch.sh` | Calendar watcher: start prompts, auto-stop, pre-meeting briefs |
| `brief.sh` | Pre-meeting digest from prior transcripts with the same attendees |
| `commitments.sh` | Extracts action items into a trackable ledger |
| `live-transcribe.sh` | Rough live transcript while recording |
| `live-questions.sh` | Strategic question suggestions during recording |

## Calendar integration

Works with any calendar configured in macOS System Settings (Google, Outlook, iCloud, Exchange) via native EventKit. No OAuth setup, no API keys. Cross-platform Google Calendar OAuth script included for non-macOS use.

Recording itself is platform-independent: captures audio at the OS level, so it works with any meeting app. Meet, Zoom, Teams, and Webex join links are detected from event fields.

## Configuration

All settings in `~/.config/zaatar/config`. Run `zaatar setup` to change them interactively, or edit directly (see `config.example.sh`).

Key settings:
- `ZAATAR_LLM_CMD` - LLM provider (empty = Claude CLI; set to ollama/llm/anything)
- `ZAATAR_LANGS` - spoken languages in your meetings
- `ZAATAR_CALENDAR_CMD` - calendar source (auto-configured by setup)
- `ZAATAR_BEHAVIORAL_READ` - include behavioral analysis in transcripts (default: true)
- `ZAATAR_PROSODY_VENV` - python venv for emotional eval (parselmouth + wav2vec2)
- `ZAATAR_WAV_RETENTION_DAYS` - auto-delete recordings after N days (default: 14)
- `ZAATAR_BRIEF_LEAD` - seconds before meeting to generate pre-brief (default: 900)
- `ZAATAR_QUESTIONS_INTERVAL` - seconds between live question suggestions (default: 90; 0 = off)

## Requirements

- macOS 14.2+ (system-audio capture via process tap; earlier versions: mic-only)
- Xcode Command Line Tools (`xcode-select --install`)
- The installer handles everything else: ffmpeg, jq, whisper-cpp, whisper models

Optional:
- An LLM for transcript cleanup, briefs, and behavioral analysis (Claude CLI, Ollama, or any provider)
- Hugging Face token for speaker diarization ([pyannote model access](https://huggingface.co/pyannote/speaker-diarization-3.1))
- For emotional eval: python venv with parselmouth, torch, transformers, soundfile (`zaatar setup --prosody`)

## Consent

You are recording people. Recording-consent laws vary by jurisdiction (some require all-party consent). Tell your participants, get consent, and check your local law before using Zaatar.

## License

MIT
