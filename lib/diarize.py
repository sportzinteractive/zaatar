#!/usr/bin/env python3
"""Standalone speaker diarization using pyannote on MPS (Apple Silicon GPU).

Usage: diarize.py <audio.wav> <output.srt> [--hf-token TOKEN] [--format srt|json]

Produces an SRT or JSON file with speaker labels. JSON output is compatible
with whisperx format ({"segments": [{"start", "end", "speaker"}, ...]}).
Runs on MPS if available, falls back to CPU.
"""
import sys, os, argparse, json, math

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", help="Path to WAV file")
    parser.add_argument("output", help="Output path (.srt or .json)")
    parser.add_argument("--hf-token", default=os.environ.get("HF_TOKEN", ""))
    parser.add_argument("--format", choices=["srt", "json"], default="srt")
    args = parser.parse_args()

    import torch
    from pyannote.audio import Pipeline

    token = args.hf_token or None
    pipeline = Pipeline.from_pretrained("pyannote/speaker-diarization-3.1", token=token)

    device = "cpu"
    if torch.cuda.is_available():
        try:
            pipeline.to(torch.device("cuda"))
            device = "cuda"
        except Exception:
            pass
    elif torch.backends.mps.is_available():
        try:
            pipeline.to(torch.device("mps"))
            device = "mps"
        except Exception:
            pass
    print(f"diarize: using {device}", file=sys.stderr)

    # Pre-load audio as waveform dict: avoids pyannote's torchcodec dependency
    # (torchcodec often can't find FFmpeg on macOS; torchaudio has no backends)
    import wave, numpy as np
    with wave.open(args.audio) as wf:
        sample_rate = wf.getframerate()
        samples = np.frombuffer(wf.readframes(wf.getnframes()), dtype=np.int16)
        if wf.getnchannels() > 1:
            samples = samples.reshape(-1, wf.getnchannels()).mean(axis=1).astype(np.int16)
    waveform = torch.from_numpy(samples.astype(np.float32) / 32768.0).unsqueeze(0)
    result = pipeline({"waveform": waveform, "sample_rate": sample_rate})

    # pyannote 4.x returns DiarizeOutput; 3.x returns Annotation directly
    if hasattr(result, 'speaker_diarization'):
        annotation = result.speaker_diarization
    else:
        annotation = result

    # Collect segments
    segments = []
    for turn, _, speaker in annotation.itertracks(yield_label=True):
        segments.append({"start": round(turn.start, 3), "end": round(turn.end, 3), "speaker": speaker})

    # Write output
    with open(args.output, "w") as f:
        if args.format == "json":
            json.dump({"segments": segments}, f, indent=2)
        else:
            for i, s in enumerate(segments, 1):
                f.write(f"{i}\n")
                f.write(f"{_fmt(s['start'])} --> {_fmt(s['end'])}\n")
                f.write(f"[{s['speaker']}] \n\n")

    print(f"diarize: {len(segments)} segments written to {args.output}", file=sys.stderr)

def _fmt(seconds):
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    ms = int((seconds % 1) * 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"

if __name__ == "__main__":
    main()
