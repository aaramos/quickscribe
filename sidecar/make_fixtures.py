"""Generate synthetic 10s / 30s / 60s 16k-mono-int16 WAV utterance fixtures.

Tone bursts + silence cadence mimic speech rhythm for timing benchmarks.
Run: .venv/bin/python make_fixtures.py
"""
from __future__ import annotations

import numpy as np
import soundfile as sf
from pathlib import Path

HERE = Path(__file__).resolve().parent
SR = 16000


def make_utterance(seconds: float, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    n = int(SR * seconds)
    out = np.zeros(n, dtype=np.float32)
    i = 0
    syll = 0
    while i < n:
        # syllable-length burst (100-300ms) followed by short gap (30-120ms)
        burst = int(SR * rng.uniform(0.10, 0.30))
        gap = int(SR * rng.uniform(0.03, 0.12))
        f0 = rng.uniform(110, 220)
        t = np.arange(min(burst, n - i)) / SR
        wave = 0.4 * np.sin(2 * np.pi * f0 * t) * np.exp(-t * 2.0)
        out[i : i + len(wave)] += wave.astype(np.float32)
        i += burst + gap
        syll += 1
    return out


for secs in (10, 30, 60):
    path = HERE / f"utterance_{secs}s.wav"
    sf.write(path, make_utterance(secs, seed=secs), SR, subtype="PCM_16")
    print(f"wrote {path}")