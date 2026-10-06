# Adapted from https://github.com/JusperLee/Apollo inference.py (run_model, chunk_starts,
# crossfade_weights; commit e84bcacc59d5455f05d86a5c97dd4aeb3c14dbb6) by Kai Li and Yi Luo.
# Licensed under CC BY-SA 4.0 (see LICENSE and NOTICE.md in the project root).
# Changes: numpy accumulators, one chunk per forward pass, a per-chunk progress callback,
# and a minimum-length pad so very short inputs survive the model's STFT.
"""Bounded-memory chunked inference with padded context and normalized linear crossfades."""

from typing import Callable

import numpy as np

# Inputs are zero-padded to at least this many samples before the model sees them
# (the STFT needs more than n_fft/2 samples); the padding is cropped off again.
MIN_SAMPLES = 44_100


def chunk_starts(total: int, chunk: int, overlap: int) -> list[int]:
    hop = chunk - overlap
    starts = [0]
    while starts[-1] + chunk < total:
        starts.append(starts[-1] + hop)
    return starts


def crossfade_weights(length: int, overlap: int, fade_in: bool, fade_out: bool) -> np.ndarray:
    w = np.ones(length, dtype=np.float32)
    n = min(overlap, length)
    if n:
        ramp = np.linspace(0.0, 1.0, n, dtype=np.float32)
        if fade_in:
            w[:n] = ramp
        if fade_out:
            w[-n:] = np.minimum(w[-n:], ramp[::-1])
    return w


def _pad_to(x: np.ndarray, length: int) -> np.ndarray:
    if x.shape[-1] >= length:
        return x
    return np.pad(x, ((0, 0), (0, length - x.shape[-1])))


def run_chunked(
    model_fn: Callable[[np.ndarray], np.ndarray],
    audio: np.ndarray,
    chunk: int,
    overlap: int,
    pad: int,
    on_progress: Callable[[int, int], None] = lambda done, total: None,
) -> np.ndarray:
    """Restore `audio` ([channels, samples] float32) chunk by chunk.

    `model_fn` maps [channels, n] -> [channels, n]. `on_progress(done, total)` fires
    after every chunk. Output has exactly the input's shape.
    """
    if overlap * 2 > chunk:
        raise ValueError("overlap must be at most half the chunk length")
    channels, total = audio.shape

    if total <= chunk:
        on_progress(0, 1)
        out = model_fn(_pad_to(audio, MIN_SAMPLES))[:, :total]
        on_progress(1, 1)
        return np.ascontiguousarray(out, dtype=np.float32)

    starts = chunk_starts(total, chunk, overlap)
    padded_len = chunk + 2 * pad
    out = np.zeros((channels, total), dtype=np.float32)
    wsum = np.zeros(total, dtype=np.float32)
    on_progress(0, len(starts))

    for i, start in enumerate(starts):
        end = min(start + chunk, total)
        valid = end - start
        # Model output is wrong for ~0.5 s at the edges of whatever it is given, so each
        # chunk is inferred with `pad` samples of real neighbouring audio per side, which
        # are then discarded. The file's own edges take none (the last chunk extends
        # further left instead), since padding with silence degrades the output.
        p_start = max(0, start - pad)
        if pad and end == total:
            p_start = max(0, total - padded_len)
        segment = _pad_to(audio[:, p_start : p_start + padded_len], max(padded_len, MIN_SAMPLES))
        restored = model_fn(segment)
        offset = start - p_start
        piece = restored[:, offset : offset + valid]
        w = crossfade_weights(valid, overlap, fade_in=i > 0, fade_out=i < len(starts) - 1)
        out[:, start:end] += piece * w
        wsum[start:end] += w
        on_progress(i + 1, len(starts))

    if np.any(wsum <= 0):
        raise RuntimeError("chunk overlap-add left uncovered samples")
    out /= wsum
    return out
