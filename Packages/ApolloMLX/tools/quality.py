#!/usr/bin/env python3
"""Compare restored audio against the lossless original.

    python quality.py --flac ref.flac --input lossy.mp3 OUT1.wav [OUT2.wav ...]

Everything is decoded with PyAV to 44.1 kHz stereo, aligned to the FLAC by cross-correlation
(decoders and resamplers add different delays), and trimmed to a common length. Reports per
file: energy above 16 kHz relative to the FLAC (dB), log-spectral distance to the FLAC over
the full band and over 16-22 kHz (LSD, dB; lower is better), and SNR to the FLAC over the full
band and below 8 kHz (where the codec kept the signal, so a repair should not lose any).
Optionally --pair A B prints the SNR between two outputs (e.g. Swift vs Python).
"""
import argparse

import av
import numpy as np

SR = 44100


def decode(path):
    with av.open(str(path)) as c:
        s = c.streams.audio[0]
        r = av.AudioResampler(format="fltp", layout="stereo", rate=SR)
        parts = [o.to_ndarray() for f in c.decode(s) for o in r.resample(f)]
        parts += [o.to_ndarray() for o in r.resample(None)]
    return np.concatenate(parts, axis=1).astype(np.float64)


def lag(ref, x, max_lag=4096):
    """Lag (samples) such that x[i + lag] ~ ref[i], from a mid-track excerpt."""
    n = min(len(ref), len(x))
    a = ref[n // 3: n // 3 + SR * 10]
    seg = x[n // 3 - max_lag: n // 3 + SR * 10 + max_lag]
    corr = np.correlate(seg, a, mode="valid")
    return int(np.argmax(corr)) - max_lag


def align(ref, x):
    lg = lag(ref.mean(0), x.mean(0))
    if lg > 0:
        x = x[:, lg:]
    elif lg < 0:
        x = np.pad(x, ((0, 0), (-lg, 0)))
    return x, lg


def spec(x, n=2048, hop=512):
    w = np.hanning(n)
    frames = np.lib.stride_tricks.sliding_window_view(x, n, axis=-1)[..., ::hop, :] * w
    return np.abs(np.fft.rfft(frames, axis=-1)) ** 2  # ch, T, F


def lowpass(x, cutoff=8000):
    """Brick-wall low-pass (whole-signal FFT), for SNR in the band the lossy codec kept."""
    X = np.fft.rfft(x, axis=-1)
    X[..., np.fft.rfftfreq(x.shape[-1], 1 / SR) > cutoff] = 0
    return np.fft.irfft(X, n=x.shape[-1], axis=-1)


def report(name, ref, x):
    n = min(ref.shape[1], x.shape[1])
    r, y = ref[:, :n], x[:, :n]
    R, Y = spec(r), spec(y)
    f = np.fft.rfftfreq(2048, 1 / SR)
    hb = f >= 16000
    e_hb = 10 * np.log10(Y[..., hb].sum() / R[..., hb].sum())
    eps = 1e-10
    d = 10 * np.log10(R + eps) - 10 * np.log10(Y + eps)
    # skip near-silent frames of the reference
    loud = 10 * np.log10(R.sum(-1) + eps) > 10 * np.log10(R.sum(-1).max()) - 60
    lsd = np.sqrt((d ** 2).mean(-1))[loud].mean()
    lsd_hb = np.sqrt((d[..., hb] ** 2).mean(-1))[loud].mean()
    snr = 10 * np.log10((r ** 2).sum() / ((r - y) ** 2).sum())
    rl, yl = lowpass(r), lowpass(y)
    snr_lo = 10 * np.log10((rl ** 2).sum() / ((rl - yl) ** 2).sum())
    print(f"{name:40s} HF>16k {e_hb:+7.1f} dB | LSD {lsd:5.2f} dB | LSD 16-22k {lsd_hb:5.2f} dB | SNR {snr:5.1f} dB | SNR<8k {snr_lo:5.1f} dB")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--flac", required=True)
    ap.add_argument("--input", required=True)
    ap.add_argument("--pair", nargs=2)
    ap.add_argument("outputs", nargs="*")
    a = ap.parse_args()
    ref = decode(a.flac)
    report("input (lossy)", ref, align(ref, decode(a.input))[0])
    for p in a.outputs:
        x, lg = align(ref, decode(p))
        report(f"{p.split('/')[-1]} (lag {lg})", ref, x)
    if a.pair:
        x, y = decode(a.pair[0]), decode(a.pair[1])
        n = min(x.shape[1], y.shape[1])
        lg = lag(x.mean(0), y.mean(0))
        print(f"pair lag {lg}")
        x, y = x[:, :n - abs(lg)], (y[:, lg:] if lg >= 0 else np.pad(y, ((0, 0), (-lg, 0))))[:, :n - abs(lg)]
        print(f"pair SNR {10 * np.log10((x ** 2).sum() / ((x - y) ** 2).sum()):.1f} dB, max abs {np.abs(x - y).max():.4f}")


if __name__ == "__main__":
    main()
