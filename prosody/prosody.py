#!/usr/bin/env python3
"""prosody.py - Acoustic/emotional analysis for Zaatar recordings.

Input:  16kHz mono WAV + whisperx diarized JSON (segments with speaker labels)
Output: markdown "Acoustic Read": per-speaker prosody stats, arousal/valence/
        dominance trajectory, notable moments. Within-speaker RELATIVE framing
        only (Meet-compressed remote audio makes absolute values unreliable).

Usage: prosody.py --wav <file.wav> --segments <wx.json> --out <acoustic-read.md>
"""

import argparse
import json
import sys

import numpy as np
import soundfile as sf

SR = 16000
MIN_SEG_SEC = 1.0          # ignore blips
AVD_WIN_MAX_SEC = 10.0     # cap window length fed to wav2vec2
AVD_MAX_WINDOWS = 100      # CPU budget: evenly sample beyond this
PAUSE_SEC = 0.6            # in-turn gap that counts as a pause


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def load_segments(path):
    with open(path) as f:
        data = json.load(f)
    segs = []
    for s in data.get("segments", []):
        start, end = float(s.get("start", 0)), float(s.get("end", 0))
        if end - start < MIN_SEG_SEC:
            continue
        segs.append({
            "start": start, "end": end,
            "speaker": s.get("speaker") or "UNKNOWN",
            "text": (s.get("text") or "").strip(),
        })
    return segs


def ts(sec):
    return f"{int(sec // 60):02d}:{int(sec % 60):02d}"


# --- parselmouth prosody per segment ---

def pitch_stats(snd_slice):
    import parselmouth
    try:
        pitch = snd_slice.to_pitch_ac(pitch_floor=70, pitch_ceiling=400)
        f0 = pitch.selected_array["frequency"]
        f0 = f0[f0 > 0]
        if len(f0) < 5:
            return None
        return {
            "f0_median": float(np.median(f0)),
            # semitone SD around the median: variability independent of register
            "f0_sd_st": float(np.std(12 * np.log2(f0 / np.median(f0)))),
        }
    except Exception:
        return None


def intensity_stats(snd_slice):
    try:
        inten = snd_slice.to_intensity(minimum_pitch=70)
        v = inten.values[inten.values > 0]
        if len(v) < 5:
            return None
        return {"int_mean": float(np.mean(v)), "int_sd": float(np.std(v))}
    except Exception:
        return None


# --- audeering wav2vec2 arousal/valence/dominance (model card recipe) ---

class AVDModel:
    NAME = "audeering/wav2vec2-large-robust-12-ft-emotion-msp-dim"

    def __init__(self):
        import torch
        import torch.nn as nn
        from transformers import Wav2Vec2Processor
        from transformers.models.wav2vec2.modeling_wav2vec2 import (
            Wav2Vec2Model, Wav2Vec2PreTrainedModel)

        class RegressionHead(nn.Module):
            def __init__(self, config):
                super().__init__()
                self.dense = nn.Linear(config.hidden_size, config.hidden_size)
                self.dropout = nn.Dropout(config.final_dropout)
                self.out_proj = nn.Linear(config.hidden_size, config.num_labels)

            def forward(self, features):
                x = self.dropout(features)
                x = torch.tanh(self.dense(x))
                x = self.dropout(x)
                return self.out_proj(x)

        class EmotionModel(Wav2Vec2PreTrainedModel):
            def __init__(self, config):
                super().__init__(config)
                self.wav2vec2 = Wav2Vec2Model(config)
                self.classifier = RegressionHead(config)
                self.init_weights()

            def forward(self, input_values):
                outputs = self.wav2vec2(input_values)
                hidden = torch.mean(outputs[0], dim=1)
                return self.classifier(hidden)

        self.torch = torch
        self.processor = Wav2Vec2Processor.from_pretrained(self.NAME)
        self.model = EmotionModel.from_pretrained(self.NAME)
        self.model.eval()

    def predict(self, audio):
        inputs = self.processor(audio, sampling_rate=SR, return_tensors="pt")
        with self.torch.no_grad():
            out = self.model(inputs.input_values)[0].numpy()
        # model outputs [arousal, dominance, valence] in ~0..1
        return {"arousal": float(out[0]), "dominance": float(out[1]),
                "valence": float(out[2])}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wav", required=True)
    ap.add_argument("--segments", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--skip-avd", action="store_true",
                    help="prosody only, skip wav2vec2 emotion model")
    args = ap.parse_args()

    import parselmouth

    audio, sr = sf.read(args.wav, dtype="float32")
    if sr != SR:
        log(f"WARN: expected {SR}Hz, got {sr}Hz")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    total_sec = len(audio) / sr
    snd = parselmouth.Sound(audio, sampling_frequency=sr)

    segs = load_segments(args.segments)
    if not segs:
        log("ERROR: no usable segments")
        sys.exit(1)
    speakers = sorted({s["speaker"] for s in segs})
    log(f"{len(segs)} segments, {len(speakers)} speakers, {total_sec/60:.0f} min")

    # per-segment prosody
    for s in segs:
        sl = snd.extract_part(from_time=s["start"], to_time=min(s["end"], total_sec))
        s["pitch"] = pitch_stats(sl)
        s["inten"] = intensity_stats(sl)
        dur = s["end"] - s["start"]
        s["rate_wps"] = len(s["text"].split()) / dur if dur > 0 else 0

    # pauses and response latency
    lat = {sp: [] for sp in speakers}     # gap before this speaker takes the turn
    inpause = {sp: 0 for sp in speakers}  # in-turn pauses > PAUSE_SEC
    for prev, cur in zip(segs, segs[1:]):
        gap = cur["start"] - prev["end"]
        if gap <= 0:
            continue
        if cur["speaker"] == prev["speaker"]:
            if gap > PAUSE_SEC:
                inpause[cur["speaker"]] += 1
        else:
            if gap < 8:  # longer gaps are topic changes, not response latency
                lat[cur["speaker"]].append(gap)

    # AVD on merged windows (CPU budget)
    avd_model = None
    if not args.skip_avd:
        log("loading emotion model (first run downloads ~1.2GB)...")
        try:
            avd_model = AVDModel()
        except Exception as e:
            log(f"WARN: emotion model unavailable ({e}); prosody-only output")

    windows = []
    if avd_model:
        cur = None
        for s in segs:
            if (cur and s["speaker"] == cur["speaker"]
                    and s["start"] - cur["end"] < 1.0
                    and s["end"] - cur["start"] <= AVD_WIN_MAX_SEC):
                cur["end"] = s["end"]
                cur["text"] += " " + s["text"]
            else:
                if cur:
                    windows.append(cur)
                cur = dict(speaker=s["speaker"], start=s["start"],
                           end=s["end"], text=s["text"])
        if cur:
            windows.append(cur)
        if len(windows) > AVD_MAX_WINDOWS:
            idx = np.linspace(0, len(windows) - 1, AVD_MAX_WINDOWS).astype(int)
            windows = [windows[i] for i in sorted(set(idx))]
        log(f"scoring {len(windows)} windows for arousal/valence/dominance...")
        for i, w in enumerate(windows):
            a = audio[int(w["start"] * sr):int(min(w["end"], total_sec) * sr)]
            w["avd"] = avd_model.predict(a)
            if (i + 1) % 20 == 0:
                log(f"  {i+1}/{len(windows)}")

    # --- report ---
    lines = ["## Acoustic Read", ""]
    lines += [
        "Reliability: remote audio is Meet-compressed and downmixed with mic; "
        "ABSOLUTE values are unreliable. Only WITHIN-speaker relative changes are "
        "meaningful. Never compare speakers against each other. Emotion model is "
        "English-trained; Hinglish segments are directional pointers only.",
        "",
    ]

    thirds = [(0, total_sec / 3, "early"), (total_sec / 3, 2 * total_sec / 3, "mid"),
              (2 * total_sec / 3, total_sec + 1, "late")]

    for sp in speakers:
        ss = [s for s in segs if s["speaker"] == sp]
        talk = sum(s["end"] - s["start"] for s in ss)
        pitches = [s["pitch"]["f0_median"] for s in ss if s["pitch"]]
        if not pitches:
            continue
        base_pitch = float(np.median(pitches))
        lines.append(f"### {sp} ({talk/60:.0f} min speech, {len(ss)} turns)")
        lines.append("")
        lines.append("| phase | pitch vs own baseline | pitch variability (st SD) "
                     "| rate (w/s) | arousal | valence | dominance |")
        lines.append("|---|---|---|---|---|---|---|")
        for lo, hi, label in thirds:
            ph = [s for s in ss if lo <= s["start"] < hi]
            if not ph:
                lines.append(f"| {label} | - | - | - | - | - | - |")
                continue
            p = [s["pitch"]["f0_median"] for s in ph if s["pitch"]]
            v = [s["pitch"]["f0_sd_st"] for s in ph if s["pitch"]]
            r = [s["rate_wps"] for s in ph if s["rate_wps"] > 0]
            dp = (100 * (np.median(p) - base_pitch) / base_pitch) if p else None
            wa = [w["avd"] for w in windows
                  if w["speaker"] == sp and lo <= w["start"] < hi and "avd" in w]
            def med(key):
                return f"{np.median([x[key] for x in wa]):.2f}" if wa else "-"
            lines.append(
                f"| {label} "
                f"| {('%+.0f%%' % dp) if dp is not None else '-'} "
                f"| {(f'{np.median(v):.1f}') if v else '-'} "
                f"| {(f'{np.median(r):.1f}') if r else '-'} "
                f"| {med('arousal')} | {med('valence')} | {med('dominance')} |"
            )
        lines.append("")
        l = lat[sp]
        lines.append(f"- Response latency (median gap before taking turn): "
                     f"{np.median(l):.1f}s over {len(l)} turns" if l else
                     "- Response latency: insufficient turn-taking data")
        lines.append(f"- In-turn pauses > {PAUSE_SEC}s: {inpause[sp]}")
        lines.append("")

        # notable moments: biggest arousal deviations from own median
        wa = [w for w in windows if w["speaker"] == sp and "avd" in w]
        if len(wa) >= 5:
            amed = np.median([w["avd"]["arousal"] for w in wa])
            ranked = sorted(wa, key=lambda w: -abs(w["avd"]["arousal"] - amed))[:4]
            lines.append("Notable moments (largest arousal deviation from own median):")
            for w in sorted(ranked, key=lambda w: w["start"]):
                d = w["avd"]["arousal"] - amed
                snippet = w["text"][:110] + ("..." if len(w["text"]) > 110 else "")
                lines.append(f"- [{ts(w['start'])}] arousal {'+' if d >= 0 else ''}{d:.2f} "
                             f"vs own median: \"{snippet}\"")
            lines.append("")

    with open(args.out, "w") as f:
        f.write("\n".join(lines) + "\n")
    log(f"wrote {args.out}")


if __name__ == "__main__":
    main()
