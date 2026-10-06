#!/usr/bin/env python3
"""Generate PyTorch fp32 reference tensors for the Swift parity test.

    python make_reference.py --checkpoint pytorch_model.bin --audio track.mp3 \
        --start 60 --seconds 7 --out reference.safetensors

Decodes `--audio` to 44.1 kHz stereo with PyAV (as apollo/ does), cuts a fixed chunk and
runs the upstream PyTorch model on CPU in fp32. `--audio noise` uses seeded white noise
(0.1 rms) instead: a well-conditioned input that measures pure arithmetic agreement, where
a lossy chunk measures agreement on the near-silent bands Apollo amplifies.
Saved tensors (torch layouts):
  input    [1, C, S]         the chunk fed to both implementations
  features [C, 80, 256, T]   after the band-split bottleneck
  layer0   [C, 80, 256, T]   after the first BSNet layer
  output   [1, C, S]         final restored waveform
  output64 [1, C, S]         the same model run in fp64 (the exact answer, to judge both)
The upstream model is imported from apollo/src/apollo_repair/model.py (a verbatim copy of
look2hear/models/apollo.py at e84bcac minus a print) unless --model points elsewhere.
"""
import argparse
import importlib.util
import pathlib
import time

import av
import numpy as np
import torch
from safetensors.numpy import save_file

HERE = pathlib.Path(__file__).resolve().parent
DEFAULT_MODEL = HERE.parents[2] / "apollo/src/apollo_repair/model.py"


def decode(path, rate=44100):
    with av.open(str(path)) as c:
        s = c.streams.audio[0]
        r = av.AudioResampler(format="fltp", layout="stereo", rate=rate)
        parts = [o.to_ndarray() for f in c.decode(s) for o in r.resample(f)]
        parts += [o.to_ndarray() for o in r.resample(None)]
    return np.concatenate(parts, axis=1).astype(np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", required=True)
    ap.add_argument("--audio", required=True)
    ap.add_argument("--start", type=float, default=60.0)
    ap.add_argument("--seconds", type=float, default=7.0)
    ap.add_argument("--model", default=str(DEFAULT_MODEL))
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    spec = importlib.util.spec_from_file_location("apollo_model", a.model)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    model = m.load_apollo(a.checkpoint, "cpu")
    torch.set_num_threads(12)

    s0, n = int(a.start * 44100), int(a.seconds * 44100)
    if a.audio == "noise":
        audio = (0.1 * np.random.default_rng(0).standard_normal((2, s0 + n))).astype(np.float32)
    else:
        audio = decode(a.audio)
    x = torch.from_numpy(np.ascontiguousarray(audio[:, s0:s0 + n]))[None]
    grabbed = {}
    model.net[0].register_forward_hook(lambda mod, i, o: grabbed.__setitem__("layer0", o))
    with torch.inference_mode():
        feats = model.feature_extractor(x)
        t = time.time()
        y = model(x)
        print(f"torch cpu forward {time.time() - t:.2f}s for {a.seconds}s stereo")
    m64 = model.double()
    m64.eps = float(np.finfo(np.float32).eps)  # same eps as the fp32 model
    with torch.inference_mode():
        y64 = m64(x.double()).float()
    save_file({
        "input": x.numpy(), "features": feats.numpy(),
        "layer0": grabbed["layer0"].numpy(), "output": y.numpy(), "output64": y64.numpy(),
    }, a.out)
    print("saved", a.out, {k: tuple(v.shape) for k, v in
                           {"input": x, "features": feats, "output": y}.items()})


if __name__ == "__main__":
    main()
