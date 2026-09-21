"""Whisper-class STT engine wrapper (mlx-whisper). Warm-loaded, chunk-friendly."""
from __future__ import annotations

import io
import logging
import wave

import mlx_whisper
import numpy as np
from pathlib import Path

log = logging.getLogger("quickscribe.stt")

TARGET_SR = 16000

# Silence floor (t_b3e7802c defense-in-depth): chunks below this RMS never
# touch the model. Mirrors AppInfo.silenceRmsFloor on the app side (~-48
# dBFS). A silent WAV must return "" WITHOUT a decode — Whisper's canonical
# failure on silence is the "Thank you." hallucination loop.
SILENCE_RMS_FLOOR = 0.004


def rms(samples: np.ndarray) -> float:
    if samples.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(np.square(samples, dtype=np.float64))))


def _decode_wav(data: bytes) -> np.ndarray:
    """Decode 16k-mono-int16 WAV bytes to float32 in [-1, 1]."""
    try:
        with wave.open(io.BytesIO(data), "rb") as w:
            if w.getnframes() == 0:
                raise ValueError("zero frames")
            sr = w.getframerate()
            ch = w.getnchannels()
            width = w.getsampwidth()
            raw = w.readframes(w.getnframes())
    except wave.Error as exc:
        raise ValueError(f"not a wav: {exc}") from exc
    if width != 2:
        raise ValueError(f"expected 16-bit samples, got {width * 8}-bit")
    if ch != 1:
        raise ValueError(f"expected mono, got {ch} channels")
    samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if sr != TARGET_SR:
        # Resample with linear interpolation (good enough for dictation chunks).
        n_out = int(round(len(samples) * TARGET_SR / sr))
        if n_out == 0:
            raise ValueError("zero samples after resample")
        samples = np.interp(
            np.linspace(0, len(samples) - 1, n_out), np.arange(len(samples)), samples
        ).astype(np.float32)
    return samples


def _snapshot_dir(repo_id: str) -> Path:
    """Resolve HF repo id to the local snapshot dir (avoids mlx-whisper's
    repo-id path which looks for weights.npz naming this repo doesn't use)."""
    from huggingface_hub import snapshot_download

    return Path(snapshot_download(repo_id=repo_id))


class STTEngine:
    def __init__(self, model_id: str, language: str = "en",
                 temperature: float = 0.0):
        self.model_id = model_id
        self.language = language
        self.temperature = temperature
        self._ready = False

    @property
    def ready(self) -> bool:
        return self._ready

    def load(self) -> None:
        """Warm-load weights. First ever call downloads from HF; afterwards local."""
        mlx_whisper.transcribe(
        np.zeros(TARGET_SR, dtype=np.float32),
        path_or_hf_repo=str(_snapshot_dir(self.model_id)),
    )
        self._ready = True
        log.info("STT warm: %s", self.model_id)

    def transcribe(self, wav_bytes: bytes, partial: bool = False) -> str:
        """Transcribe 16k mono int16 WAV bytes. partial=True marks in-flight chunks."""
        samples = _decode_wav(wav_bytes)
        if len(samples) < TARGET_SR * 0.1:
            return ""
        # RMS gate BEFORE decode (t_b3e7802c): silent audio never reaches
        # Whisper — no decode of silence, no silence hallucination.
        level = rms(samples)
        if level < SILENCE_RMS_FLOOR:
            log.info("transcribe gated: rms=%.5f < floor %.4f, %.1fs — no decode",
                     level, SILENCE_RMS_FLOOR, len(samples) / TARGET_SR)
            return ""
        result = mlx_whisper.transcribe(
            samples,
            path_or_hf_repo=self.model_id,
            language=self.language,
            condition_on_previous_text=False,
            # Fixed temp + relaxed fallback thresholds: dictation tails are short,
            # and whisper's multi-temperature retry loop (up to 5 passes) was the
            # dominant latency source on noisier tails (1.2-2.8s -> ~180-450ms).
            temperature=self.temperature,
            compression_ratio_threshold=2.4,
            logprob_threshold=-1.0,
            no_speech_threshold=0.6,
        )
        return result.get("text", "").strip()