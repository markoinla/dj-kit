import numpy as np
import pytest

from apollo_repair.chunking import chunk_starts, run_chunked


def identity(x):
    return x.copy()


@pytest.mark.parametrize("total", [10, 999, 1000, 1001, 4321, 10_000])
def test_identity_model_round_trips(total, monkeypatch):
    monkeypatch.setattr("apollo_repair.chunking.MIN_SAMPLES", 50)
    rng = np.random.default_rng(0)
    audio = rng.standard_normal((2, total)).astype(np.float32)
    calls = []
    out = run_chunked(identity, audio, chunk=1000, overlap=200, pad=150,
                      on_progress=lambda d, t: calls.append((d, t)))
    assert out.shape == audio.shape
    np.testing.assert_allclose(out, audio, atol=1e-5)
    assert calls[0][0] == 0 and calls[-1][0] == calls[-1][1]


def test_model_sees_padded_segments(monkeypatch):
    monkeypatch.setattr("apollo_repair.chunking.MIN_SAMPLES", 50)
    lengths = []

    def model(x):
        lengths.append(x.shape[-1])
        return x

    run_chunked(model, np.zeros((1, 5000), np.float32), chunk=1000, overlap=100, pad=250)
    assert set(lengths) == {1500}


def test_chunk_starts_cover_signal():
    starts = chunk_starts(10_000, 1000, 200)
    assert starts[0] == 0 and starts[-1] + 1000 >= 10_000
    assert all(b - a == 800 for a, b in zip(starts, starts[1:]))
