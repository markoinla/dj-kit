"""Audio decode/encode. Decoding goes through PyAV (bundled FFmpeg) so mp3, m4a/aac, flac,
wav, aiff and ogg all work with no system ffmpeg; output is a WAV at 44.1 kHz."""

import os
from pathlib import Path

import numpy as np

SAMPLE_RATE = 44_100


def decode(path: str | os.PathLike, rate: int = SAMPLE_RATE) -> np.ndarray:
    """Decode any audio file to float32 [channels, samples] at `rate`.

    Mono stays mono; anything with two or more channels is mixed to stereo."""
    try:
        return _decode_av(path, rate)
    except Exception as av_error:
        try:
            return _decode_soundfile(path, rate)
        except Exception:
            raise av_error from None


def _decode_av(path, rate):
    import av

    with av.open(str(path)) as container:
        if not container.streams.audio:
            raise ValueError(f"No audio stream in {path}")
        stream = container.streams.audio[0]
        n_in = _channel_count(stream)
        layout = "mono" if n_in == 1 else "stereo"
        resampler = av.AudioResampler(format="fltp", layout=layout, rate=rate)
        parts = []
        for frame in container.decode(stream):
            for out in resampler.resample(frame):
                parts.append(out.to_ndarray())
        for out in resampler.resample(None):
            parts.append(out.to_ndarray())
    if not parts:
        raise ValueError(f"No audio decoded from {path}")
    audio = np.concatenate(parts, axis=1).astype(np.float32, copy=False)
    return _check(audio, path)


def _channel_count(stream) -> int:
    for get in (
        lambda: stream.codec_context.layout.nb_channels,
        lambda: len(stream.layout.channels),
        lambda: stream.channels,
        lambda: stream.codec_context.channels,
    ):
        try:
            n = int(get())
            if n > 0:
                return n
        except Exception:
            pass
    return 2


def _decode_soundfile(path, rate):
    import soundfile as sf

    audio, sr = sf.read(str(path), dtype="float32", always_2d=True)
    if sr != rate:
        raise ValueError(f"Expected {rate} Hz audio, got {sr} Hz (PyAV unavailable to resample)")
    audio = audio.T
    if audio.shape[0] > 2:
        audio = audio[:2]
    return _check(np.ascontiguousarray(audio), path)


def _check(audio: np.ndarray, path) -> np.ndarray:
    if audio.ndim != 2 or audio.shape[1] == 0:
        raise ValueError(f"No audio samples in {path}")
    if not np.isfinite(audio).all():
        audio = np.nan_to_num(audio, nan=0.0, posinf=1.0, neginf=-1.0)
    return audio


def write_wav(path: str | os.PathLike, audio: np.ndarray, rate: int = SAMPLE_RATE,
              fmt: str = "pcm24") -> int:
    """Write [channels, samples] float audio atomically. Returns the number of clipped
    samples (pcm24 only; float output is written unclipped)."""
    import soundfile as sf

    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    clipped = 0
    if fmt == "pcm24":
        clipped = int(np.count_nonzero(np.abs(audio) > 1.0))
        audio = np.clip(audio, -1.0, 1.0)
        subtype = "PCM_24"
    elif fmt == "float":
        subtype = "FLOAT"
    else:
        raise ValueError(f"Unknown output format {fmt!r}")
    tmp = path.with_name(f".{path.name}.partial-{os.getpid()}")
    try:
        sf.write(str(tmp), audio.T, rate, subtype=subtype, format="WAV")
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink()
    return clipped
