"""Reference run of the original beat_this (PyTorch) for AnalysisKit's tempo parity tests.

usage: python -I beat_this_reference.py <beat_this checkout> <final0.ckpt> <out dir> <audio files...>

Setup (in a scratch dir): uv venv; uv pip install torch torchaudio numpy soxr einops
rotary-embedding-torch soundfile; beat_this from https://github.com/CPJKU/beat_this (checked
against b95c8ab); final0.ckpt from https://cloud.cp.jku.at/public.php/dav/files/7ik4RrBKTS273gp/final0.ckpt.

Per file writes <out>/<name>/: mono22k.f32 (soxr-resampled mono), mel.f32 (frames x 128),
logits_final0.f32 (frame-wise beat logits), beats_final0.txt. Point TEST_RUNNER_BEAT_THIS_REF_DIR
at <out> (and TEST_RUNNER_BEAT_THIS_AUDIO at the audio folder) when running TempoModelTests.
"""
import os
import sys

import numpy as np
import soundfile as sf
import soxr
import torch

src, ckpt, outdir, files = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
sys.path.insert(0, src)
from beat_this.inference import Spect2Frames  # noqa: E402
from beat_this.model.postprocessor import Postprocessor  # noqa: E402
from beat_this.preprocessing import LogMelSpect  # noqa: E402

mel = LogMelSpect()
model = Spect2Frames(ckpt)
post = Postprocessor("minimal")
for path in files:
    name = os.path.splitext(os.path.basename(path))[0]
    d = os.path.join(outdir, name)
    os.makedirs(d, exist_ok=True)
    sig, sr = sf.read(path, dtype="float64", always_2d=True)
    sig = sig.mean(1)
    if sr != 22050:
        sig = soxr.resample(sig, in_rate=sr, out_rate=22050)
    sig = sig.astype(np.float32)
    sig.tofile(os.path.join(d, "mono22k.f32"))
    spect = mel(torch.tensor(sig))
    spect.numpy().astype(np.float32).tofile(os.path.join(d, "mel.f32"))
    beat, down = model(spect)
    beat.numpy().astype(np.float32).tofile(os.path.join(d, "logits_final0.f32"))
    beats, _ = post(beat, down)
    np.savetxt(os.path.join(d, "beats_final0.txt"), beats, fmt="%.4f")
    print(name, len(beats), "beats", flush=True)
