#!/usr/bin/env python
# vad_check.py <audio.wav> - print total detected speech seconds (integer).
# Used by transcribe.sh as a junk-recording guard: empty-room audio makes
# whisper hallucinate entire fake transcripts, so skip the pipeline instead.
# Reads via soundfile (torchaudio >= 2.9 needs torchcodec; not worth the dep).
import sys

import numpy as np
import soundfile as sf
import torch
from silero_vad import load_silero_vad, get_speech_timestamps

SR = 16000

data, sr = sf.read(sys.argv[1], dtype="float32")
if data.ndim > 1:
    data = data.mean(axis=1)
if sr != SR:  # zaatarcap always writes 16k mono; resample defensively
    idx = (np.arange(int(len(data) * SR / sr)) * (sr / SR)).astype(np.int64)
    data = data[np.clip(idx, 0, len(data) - 1)]

model = load_silero_vad()
speech = get_speech_timestamps(torch.from_numpy(data), model, sampling_rate=SR)
total = sum(t["end"] - t["start"] for t in speech) / SR
print(int(total))
