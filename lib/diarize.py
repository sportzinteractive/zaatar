#!/usr/bin/env python3
"""Standalone speaker diarization using pyannote on MPS (Apple Silicon GPU).

Usage: diarize.py <audio.wav> <output.srt> [--hf-token TOKEN]

Produces an SRT file with speaker labels. Runs on MPS if available, falls back to CPU.
"""
import sys, os, argparse, math

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", help="Path to WAV file")
    parser.add_argument("output", help="Output SRT path")
    parser.add_argument("--hf-token", default=os.environ.get("HF_TOKEN", ""))
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

    diarization = pipeline(args.audio)

    # Write SRT with speaker labels
    with open(args.output, "w") as f:
        for i, (turn, _, speaker) in enumerate(diarization.itertracks(yield_label=True), 1):
            f.write(f"{i}\n")
            f.write(f"{_fmt(turn.start)} --> {_fmt(turn.end)}\n")
            f.write(f"[{speaker}] \n\n")

    print(f"diarize: {i} segments written to {args.output}", file=sys.stderr)

def _fmt(seconds):
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    ms = int((seconds % 1) * 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"

if __name__ == "__main__":
    main()
