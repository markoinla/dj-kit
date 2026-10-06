"""apollo-repair: restore lossy-compressed music with Apollo.

    apollo-repair --input IN --output OUT.wav [--device auto|mps|cpu]
    apollo-repair --prefetch-weights

stdout carries JSON lines only (one object per line):
    {"event":"status","message":"..."}  {"event":"progress","fraction":0.42}
    {"event":"done","output":"/abs/OUT.wav"}  {"event":"error","message":"..."}
Everything else (logs, warnings, library chatter) goes to stderr. Exit 0 on success.
Weights are cached by huggingface_hub under $HF_HOME.
"""

import os

# Must be set before torch is imported: run ops MPS lacks on the CPU instead of failing.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")

import argparse
import hashlib
import json
import resource
import signal
import sys
import time
from pathlib import Path

WEIGHTS_REPO = "JusperLee/Apollo"
WEIGHTS_FILE = "pytorch_model.bin"
# Pinned Hugging Face commit; with a commit hash, a cached file resolves without network.
WEIGHTS_REVISION = "c68bd80fdd9c0d93d2f4a833cb154624f660a561"
WEIGHTS_SHA256 = "99d9af7f1ff20e63c393035513a655392818d66b4d7fc23d658175c1f15e8d76"

_proto = None  # the real stdout, reserved for protocol lines


def _take_stdout():
    """Keep fd 1 for the protocol and point everything else at stderr, including C-level
    writes to fd 1 from torch/FFmpeg, so stray output can never corrupt the JSON stream."""
    global _proto
    if _proto is not None:
        return
    sys.stdout.flush()
    _proto = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
    os.dup2(2, 1)
    sys.stdout = sys.stderr


def emit(event: str, **fields):
    line = json.dumps({"event": event, **fields}, ensure_ascii=False)
    _proto.write(line + "\n")
    _proto.flush()


def log(msg: str):
    print(f"apollo-repair: {msg}", file=sys.stderr, flush=True)


def fetch_weights(local_only: bool = False) -> Path:
    from huggingface_hub import hf_hub_download

    return Path(hf_hub_download(
        repo_id=WEIGHTS_REPO, filename=WEIGHTS_FILE, revision=WEIGHTS_REVISION,
        local_files_only=local_only,
    ))


def resolve_weights() -> Path:
    try:
        return fetch_weights(local_only=True)
    except Exception:
        return fetch_weights(local_only=False)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def select_device(requested: str):
    import torch

    mps_ok = torch.backends.mps.is_available()
    if requested == "auto":
        return "mps" if mps_ok else "cpu"
    if requested == "mps" and not mps_ok:
        raise RuntimeError("MPS was requested but is not available on this Mac.")
    return requested


def peak_rss_mib() -> float:
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return rss / (1024 * 1024) if sys.platform == "darwin" else rss / 1024


def prefetch() -> int:
    emit("status", message="Downloading model weights")
    path = fetch_weights()
    digest = sha256(path)
    if digest != WEIGHTS_SHA256:
        log(f"warning: weights sha256 {digest} differs from the recorded {WEIGHTS_SHA256}")
    emit("done", output=str(path))
    return 0


def repair(args) -> int:
    from . import audio as audio_io
    from .chunking import run_chunked

    inp, out = Path(args.input).expanduser().resolve(), Path(args.output).expanduser().resolve()
    if not inp.is_file():
        raise FileNotFoundError(f"Input not found: {inp}")
    if inp == out:
        raise ValueError("Input and output must be different files.")

    t0 = time.monotonic()
    emit("status", message="Decoding audio")
    samples = audio_io.decode(inp)
    seconds = samples.shape[1] / audio_io.SAMPLE_RATE
    log(f"decoded {inp.name}: {samples.shape[0]} ch, {seconds:.1f} s")

    emit("status", message="Loading model")
    import numpy as np
    import torch
    from .model import load_apollo

    weights = Path(args.weights) if args.weights else resolve_weights()
    device = select_device(args.device)
    model = load_apollo(str(weights), device)
    log(f"model loaded on {device} ({time.monotonic() - t0:.1f} s so far)")

    # fp16 autocast on MPS: ~2x faster and lighter than fp32 at ~60 dB SNR against fp32
    # output. A chunk that overflows (non-finite output) is redone in fp32.
    half = args.precision == "fp16" or (args.precision == "auto" and device == "mps")
    state = {"device": device, "model": model, "half": half}
    log(f"precision: {'fp16 autocast' if half else 'fp32'}")

    def infer(x):
        dev = state["device"]
        with torch.inference_mode():
            if state["half"] and dev != "cpu":
                with torch.autocast(dev, dtype=torch.float16):
                    y = state["model"](x.to(dev)).float()
                if bool(torch.isfinite(y).all()):
                    return y.squeeze(0).to("cpu").numpy()
                log("non-finite fp16 output; redoing chunk in fp32")
            return state["model"](x.to(dev)).squeeze(0).to("cpu").numpy()

    def forward(segment: np.ndarray) -> np.ndarray:
        x = torch.from_numpy(np.ascontiguousarray(segment)).unsqueeze(0)
        try:
            return infer(x)
        except RuntimeError as e:
            if state["device"] == "cpu":
                raise
            if "out of memory" in str(e).lower():
                # CPU runs ~50x slower than realtime, so it is no rescue for a full track.
                # Free the allocator cache and retry once; then give up with a clear error.
                log(f"MPS out of memory ({e}); retrying chunk once")
                torch.mps.empty_cache()
                try:
                    return infer(x)
                except RuntimeError:
                    raise MemoryError("not enough GPU memory; close other apps and retry") from e
            log(f"{state['device']} failed ({e}); falling back to CPU")
            emit("status", message="GPU failed, continuing on CPU (much slower)")
            state["device"] = "cpu"
            state["model"] = state["model"].to("cpu")
            if torch.backends.mps.is_available():
                torch.mps.empty_cache()
            return infer(x)

    sr = audio_io.SAMPLE_RATE

    def on_progress(done: int, total: int):
        if done == 0:
            emit("status", message=f"Repairing on {state['device'].upper()}")
        emit("progress", fraction=round(done / total, 4))

    t1 = time.monotonic()
    restored = run_chunked(
        forward, samples,
        chunk=int(args.chunk_seconds * sr),
        overlap=int(args.overlap_seconds * sr),
        pad=int(args.pad_seconds * sr),
        on_progress=on_progress,
    )
    infer_s = time.monotonic() - t1
    del samples

    emit("status", message="Writing output")
    clipped = audio_io.write_wav(out, restored, sr, fmt=args.format)
    if clipped:
        log(f"clipped {clipped} samples above full scale")
    total_s = time.monotonic() - t0
    log(f"{seconds:.1f} s audio: inference {infer_s:.1f} s on {state['device']} "
        f"(RTF {infer_s / max(seconds, 1e-9):.2f}), total {total_s:.1f} s, "
        f"peak RSS {peak_rss_mib():.0f} MiB")
    emit("done", output=str(out))
    return 0


def parse_args(argv=None):
    p = argparse.ArgumentParser(prog="apollo-repair", description=__doc__.split("\n")[0])
    p.add_argument("--input", help="audio file to repair (mp3, m4a, flac, wav, aiff, ...)")
    p.add_argument("--output", help="WAV file to write (44.1 kHz)")
    p.add_argument("--device", choices=("auto", "mps", "cpu"), default="auto")
    p.add_argument("--format", choices=("pcm24", "float"), default="pcm24",
                   help="output sample format (default 24-bit PCM)")
    p.add_argument("--precision", choices=("auto", "fp32", "fp16"), default="auto",
                   help="auto = fp16 autocast on MPS, fp32 on CPU")
    p.add_argument("--chunk-seconds", type=float, default=5.0)
    p.add_argument("--overlap-seconds", type=float, default=0.5)
    p.add_argument("--pad-seconds", type=float, default=1.0,
                   help="real audio inferred beyond each chunk edge and discarded")
    p.add_argument("--weights", help="local checkpoint instead of the pinned HF download")
    p.add_argument("--prefetch-weights", action="store_true",
                   help="download the model weights into $HF_HOME and exit")
    args = p.parse_args(argv)
    if not args.prefetch_weights and not (args.input and args.output):
        p.error("--input and --output are required")
    if args.chunk_seconds <= 0 or args.overlap_seconds < 0 or args.pad_seconds < 0:
        p.error("chunk must be positive; overlap and pad non-negative")
    if args.overlap_seconds * 2 > args.chunk_seconds:
        p.error("--overlap-seconds must be at most half of --chunk-seconds")
    return args


def _on_sigterm(signum, frame):
    raise SystemExit(143)


def main(argv=None) -> int:
    _take_stdout()
    signal.signal(signal.SIGTERM, _on_sigterm)
    try:
        args = parse_args(argv)
    except SystemExit as e:
        if e.code:
            emit("error", message="Invalid arguments (see stderr)")
        return int(e.code or 0)
    try:
        return prefetch() if args.prefetch_weights else repair(args)
    except SystemExit as e:
        emit("error", message="Cancelled")
        return int(e.code or 1)
    except KeyboardInterrupt:
        emit("error", message="Cancelled")
        return 130
    except BaseException as e:  # noqa: BLE001 - every failure must surface as an event
        import traceback

        traceback.print_exc(file=sys.stderr)
        msg = str(e) or e.__class__.__name__
        if isinstance(e, MemoryError) or "out of memory" in msg.lower():
            msg = f"Out of memory: {msg}"
        emit("error", message=msg)
        return 1


if __name__ == "__main__":
    sys.exit(main())
