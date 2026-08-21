# Third-Party Licenses

Zaatar's own code is MIT-licensed. Some optional dependencies have different licenses that may affect your use.

## Emotional eval (prosody analysis)

**parselmouth** (Praat bindings) -- GPL v2+
The `prosody/prosody.py` module imports parselmouth for pitch and intensity analysis. Parselmouth and Praat are GPL-licensed. If you distribute modifications to prosody.py, the GPL may apply to your derivative work.

**audeering/wav2vec2-large-robust-12-ft-emotion-msp-dim** -- CC BY-NC-SA 4.0
The emotion model used for arousal/valence/dominance scoring is licensed for non-commercial use only. Commercial use of the emotional eval feature requires obtaining a separate license from [audeering](https://www.audeering.com/) or substituting a commercially-licensed model. The `--skip-avd` flag runs prosody analysis without the emotion model.

## Speaker diarization

**pyannote/speaker-diarization-3.1** -- gated model
The pyannote pretrained models require accepting license terms on [Hugging Face](https://huggingface.co/pyannote/speaker-diarization-3.1) before download. Review the model card for usage restrictions. Diarization is optional; Zaatar works without it.

## Runtime dependencies (not bundled)

| Dependency | License | Notes |
|---|---|---|
| whisper.cpp | MIT | |
| ffmpeg | LGPL 2.1+ | Invoked as a CLI tool, not linked |
| Silero VAD | MIT | |
| transformers | Apache 2.0 | |
| torch | BSD-style | |
| soundfile / libsndfile | LGPL 2.1 | |

None of these are bundled in Zaatar's source distribution. They are installed separately by the user.
