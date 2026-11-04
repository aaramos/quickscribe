"""STT engine — oMLX-hosted models (default) or local mlx-whisper.

Backends (config [stt] backend):
  omlx   POST the WAV to the oMLX OpenAI-compatible /v1/audio/transcriptions.
         Any STT model oMLX hosts from its model store (AI RAID) is usable:
         no HF cache, no external drive, no local weights. Default since
         2026-11-03 (owner request: all STT models on oMLX — the HF cache
         lived on a disconnected external volume; oMLX's store is on the RAID).
  local  mlx-whisper from a local weights dir (HF cache snapshot or path).
         Fallback for oMLX-less hosts.

mlx-whisper 0.4.3 landmine (local backend): load_model() only looks for
weights.safetensors / weights.npz, but mlx-community repos ship model.safetensors
— _ensure_weights_name() adds a weights.safetensors link BEFORE load, or a
"bad audio: [load_npz] …" 500 on every request (2026-11-03 incident: the
cache dir had a complete model.safetensors and every chunk still failed).

Silence gate (t_b3e7802c): chunks below the RMS floor never reach ANY model,
in either backend — Whisper's canonical failure on silence is the "Thank you."
hallucination loop.
"""
from __future__ import annotations

import asyncio
import io
import json
import logging
import re
import time
import wave

import httpx
import mlx_whisper
import numpy as np
from pathlib import Path
from huggingface_hub import snapshot_download

log = logging.getLogger("quickscribe.stt")

TARGET_SR = 16000

# Silence floor (t_b3e7802c defense-in-depth): chunks below this RMS never
# touch a model. Mirrors AppInfo.silenceRmsFloor on the app side (~-48 dBFS).
SILENCE_RMS_FLOOR = 0.004

_OMLX_KEY_PATH = Path.home() / ".omlx" / "settings.json"

_HF_HUB = Path.home() / ".cache" / "huggingface" / "hub"

# Staged hardlink copies of plain (non-HF-cache) model dirs, so a weights
# symlink can be added without mutating the user's model store.
_STAGE_ROOT = Path.home() / "Library" / "QuickScribe" / "stt-models"

# Name pattern for auto-discovering STT models from oMLX's live /models list.
# Selecting a non-STT match fails its warm-load and rolls back — self-healing.
_STT_NAME = re.compile(r"(whisper|parakeet|sensevoice|\basr\b|asr-|audio|omni)", re.I)


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


def _silent_wav(seconds: float = 0.1) -> bytes:
    """Tiny silent WAV — warm-load ping that cannot hallucinate."""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(TARGET_SR)
        w.writeframes(np.zeros(int(seconds * TARGET_SR), dtype=np.int16).tobytes())
    return buf.getvalue()


_SILENT_WAV = _silent_wav()


def _snapshot_dir(repo_id: str) -> Path:
    """Resolve HF repo id to the local snapshot dir (avoids mlx-whisper's
    repo-id path, which chokes on the current model.safetensors naming)."""
    return Path(snapshot_download(repo_id=repo_id))


def discover_cached_models() -> list[str]:
    """Already-downloaded mlx-community whisper repos, decoded from HF hub
    cache dir names (models--mlx-community--whisper-x -> mlx-community/
    whisper-x). Pure local scan — the picker's candidate list grows from
    anything this machine has already fetched, with zero network."""
    try:
        out = []
        for p in _HF_HUB.glob("models--mlx-community--*"):
            if not ((p / "refs").is_dir() or (p / "snapshots").is_dir()):
                continue
            repo = p.name[len("models--"):].replace("--", "/", 1)
            if "whisper" in repo.lower():
                out.append(repo)
        return sorted(out)
    except OSError:
        return []


def _omlx_api_key() -> str:
    """Same source as polish.py: oMLX's own settings file (auth.api_key)."""
    with open(_OMLX_KEY_PATH) as fh:
        return json.load(fh)["auth"]["api_key"]


def _is_hf_cache_dir(model_dir: Path) -> bool:
    """HF snapshot dirs are disposable — a weights link added there is safe.
    Anything else (the user's curated model store) is never mutated: a staged
    hardlink copy gets the link instead."""
    parts = model_dir.resolve().parts
    return any(part.startswith("models--") for part in parts)


def _ensure_weights_name(model_dir: Path) -> Path:
    """Return a dir mlx-whisper 0.4.3 CAN load (weights.safetensors/.npz).
    mlx-community repos ship model.safetensors; mlx-whisper looks for
    weights.safetensors then weights.npz and dies on the missing one."""
    def loadable(d: Path) -> bool:
        return (d / "weights.safetensors").exists() or (d / "weights.npz").exists()

    if loadable(model_dir):
        return model_dir
    src = model_dir / "model.safetensors"
    if not src.exists():
        raise ValueError(f"no loadable weights in {model_dir} (need weights.safetensors, weights.npz or model.safetensors)")

    if _is_hf_cache_dir(model_dir):
        link = model_dir / "weights.safetensors"
        if not link.exists():
            link.symlink_to(src.name)
        return model_dir

    # Plain user dir: stage a hardlink copy (zero space on the same fs) so
    # the store itself is never touched.
    staged = _STAGE_ROOT / model_dir.name
    staged.mkdir(parents=True, exist_ok=True)
    for f in model_dir.iterdir():
        if f.is_file() and not (staged / f.name).exists():
            try:
                (staged / f.name).hardlink_to(f)
            except OSError:
                import shutil
                shutil.copy2(f, staged / f.name)
    link = staged / "weights.safetensors"
    if not link.exists():
        link.symlink_to("model.safetensors")
    return staged


def _resolve_local(model_id: str) -> str:
    """HF repo id -> snapshot dir; existing local dir -> itself. In both
    cases the result is guaranteed loadable by mlx-whisper (weights shim)."""
    model_dir = Path(model_id)
    if not model_dir.is_absolute() and "/" in model_id and not model_dir.exists():
        # Looks like an HF repo id (org/name) and not a local path.
        model_dir = _snapshot_dir(model_id)
    if not model_dir.exists():
        raise ValueError(f"STT model dir does not exist: {model_dir}")
    return str(_ensure_weights_name(model_dir))


class STTEngine:
    def __init__(self, backend: str = "omlx", model_id: str = "whisper-large-v3-turbo-4bit",
                 language: str = "en", candidates: list[str] | None = None,
                 omlx_base_url: str = "http://127.0.0.1:1234/v1", timeout_s: float = 20.0):
        self.backend = backend
        # omlx: bare oMLX model id (/v1/models "id"); local: HF repo id or dir path.
        self.model_id = model_id
        self.language = language
        self.temperature = 0.0
        self._candidates = [c for c in (candidates or []) if c]
        self.omlx_base_url = omlx_base_url.rstrip("/")
        self._timeout = timeout_s
        self._ready = False                 # local backend: warm-load succeeded
        self._omlx_ok = False               # omlx backend: last liveness
        self._last_omlx_probe = 0.0
        self._model_path: str | None = None  # local backend: resolved loadable dir
        self._client: httpx.AsyncClient | None = None

    @property
    def ready(self) -> bool:
        return self._omlx_ok if self.backend == "omlx" else self._ready

    async def check_ready(self) -> bool:
        """LIVE readiness for /health and the /transcribe gate. local = the
        warm-load flag; omlx = ttl-cached liveness probe, so a dead oMLX
        shows stt_ready=false within one probe (the app dims its icon) and
        a recovered oMLX self-heals without a sidecar restart."""
        if self.backend == "omlx":
            return await self.probe()
        return self._ready

    # ---- oMLX plumbing ---------------------------------------------------------

    def _get_client(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(
                timeout=self._timeout,
                headers={"Authorization": f"Bearer {_omlx_api_key()}"},
                limits=httpx.Limits(max_keepalive_connections=4),
            )
        return self._client

    async def _list_omlx_models(self) -> list[str]:
        try:
            r = await self._get_client().get(f"{self.omlx_base_url}/models", timeout=5)
            if r.status_code != 200:
                return []
            return [m["id"] for m in r.json().get("data", []) if m.get("id")]
        except Exception as exc:
            log.warning("oMLX model list failed: %s", exc)
            return []

    async def probe(self, ttl: float = 10.0) -> bool:
        """oMLX liveness, ttl-cached. Cheap GET /models — never wakes a model."""
        if self.backend != "omlx":
            return self._ready
        now = time.monotonic()
        if self._omlx_ok and now - self._last_omlx_probe < ttl:
            return True
        try:
            r = await self._get_client().get(f"{self.omlx_base_url}/models", timeout=5)
            self._omlx_ok = r.status_code == 200
        except Exception:
            self._omlx_ok = False
        self._last_omlx_probe = now
        return self._omlx_ok

    async def _omlx_transcribe(self, wav_bytes: bytes, timeout: float | None = None) -> str:
        files = {"file": ("chunk.wav", wav_bytes, "audio/wav")}
        data = {"model": self.model_id, "language": self.language}
        r = await self._get_client().post(
            f"{self.omlx_base_url}/audio/transcriptions", data=data, files=files,
            timeout=timeout or self._timeout,
        )
        self._omlx_ok = r.status_code == 200
        self._last_omlx_probe = time.monotonic()
        if r.status_code != 200:
            raise RuntimeError(f"oMLX transcribe {r.status_code}: {r.text[:200]}")
        return (r.json().get("text") or "").strip()

    # ---- lifecycle -------------------------------------------------------------

    async def load(self) -> None:
        """Warm at startup. Never raises — oMLX down at boot degrades to
        stt_ready=false (the app dims its icon) and self-heals; a broken
        local cache likewise. The server itself always comes up."""
        if self.backend == "omlx":
            self._omlx_ok = await self.probe(ttl=0)
            if self._omlx_ok:
                try:
                    await self._omlx_transcribe(_SILENT_WAV, timeout=120)
                    log.info("STT warm (omlx): %s", self.model_id)
                except Exception as exc:
                    log.warning("STT warm-load via oMLX failed (first use may be slow): %s", exc)
            else:
                log.error("oMLX unreachable at startup — stt_ready=false until it returns")
        else:
            try:
                self._model_path = _resolve_local(self.model_id)
                mlx_whisper.transcribe(
                    np.zeros(TARGET_SR, dtype=np.float32),
                    path_or_hf_repo=self._model_path,
                )
                self._ready = True
                log.info("STT warm (local): %s", self.model_id)
            except Exception as exc:
                self._ready = False
                log.error("STT local warm failed — stt_ready=false: %s", exc)

    # ---- model picker -----------------------------------------------------------

    async def models(self) -> list[str]:
        """Candidates for the menu-bar picker. omlx: curated config list ∩
        what oMLX actually serves, then anything STT-looking oMLX picked up
        (new models appear without a sidecar change). local: HF cache scan
        + curated + active."""
        if self.backend == "omlx":
            live = await self._list_omlx_models()
            out = [m for m in self._candidates if m in live]
            if self.model_id in live and self.model_id not in out:
                out.append(self.model_id)
            for m in live:
                if m not in out and _STT_NAME.search(m):
                    out.append(m)
            return out
        out = []
        for m in self._candidates + [self.model_id] + discover_cached_models():
            if m and m not in out:
                out.append(m)
        return out

    async def set_model(self, model_id: str) -> bool:
        """Hot-swap. omlx: warm-load (possibly cold load) BEFORE committing —
        on any failure the previous model stays active and False is returned
        (same contract as the polish-model picker)."""
        model_id = model_id.strip()
        if not model_id:
            return False
        if model_id == self.model_id:
            return True
        if self.backend == "omlx":
            old = self.model_id
            self.model_id = model_id
            try:
                r = await self._get_client().post(
                    f"{self.omlx_base_url}/audio/transcriptions",
                    data={"model": model_id, "language": self.language},
                    files={"file": ("warm.wav", _SILENT_WAV, "audio/wav")},
                    timeout=120,  # first-ever use may load (and warm) the model
                )
                ok = r.status_code == 200
                if not ok:
                    log.warning("STT switch to %s failed: %s", model_id, r.text[:200])
            except Exception as exc:
                ok = False
                log.warning("STT switch to %s failed: %s", model_id, exc)
            if not ok:
                self.model_id = old
                return False
            self._omlx_ok = True
            log.info("STT model hot-swapped -> %s", model_id)
            return True
        # local
        old = self.model_id
        try:
            local = _resolve_local(model_id)
            mlx_whisper.transcribe(
                np.zeros(TARGET_SR, dtype=np.float32), path_or_hf_repo=local
            )
        except Exception as exc:
            self.model_id = old
            log.warning("STT switch to %s failed; staying on %s: %s",
                        old, self.model_id, exc)
            return False
        self.model_id = model_id
        self._model_path = local
        self._ready = True
        log.info("STT model hot-swapped -> %s", model_id)
        return True

    # ---- main operation ----------------------------------------------------------

    async def transcribe(self, wav_bytes: bytes, partial: bool = False) -> str:
        """Transcribe 16k mono int16 WAV bytes. ValueError = malformed audio
        (400); RuntimeError = service failure (500). partial=True marks
        in-flight chunks (both backends treat chunks identically)."""
        samples = _decode_wav(wav_bytes)
        if len(samples) < TARGET_SR * 0.1:
            return ""
        # RMS gate BEFORE dispatch (t_b3e7802c): silent audio never reaches
        # a model — no decode of silence, no silence hallucination.
        level = rms(samples)
        if level < SILENCE_RMS_FLOOR:
            log.info("transcribe gated: rms=%.5f < floor %.4f, %.1fs — no decode",
                     level, SILENCE_RMS_FLOOR, len(samples) / TARGET_SR)
            return ""
        if self.backend == "omlx":
            return await self._omlx_transcribe(wav_bytes)
        if not self._ready or not self._model_path:
            raise RuntimeError("STT not ready (local backend not warm)")
        # ModelHolder is keyed by the exact path string: load()/set_model()
        # register self._model_path, so transcribe MUST pass the same key or
        # mlx-whisper re-resolves the HF repo on every call — a needless
        # snapshot_download that 500s the moment the cache volume is gone
        # (2026-11-02 incident: unmounted external drive → every chunk 500).
        return await asyncio.to_thread(
            _local_decode, self._model_path, samples, self.language, self.temperature
        )


def _local_decode(model_path: str, samples: np.ndarray, language: str,
                  temperature: float) -> str:
    result = mlx_whisper.transcribe(
        samples,
        path_or_hf_repo=model_path,
        language=language,
        condition_on_previous_text=False,
        # Fixed temp + relaxed fallback thresholds: dictation tails are short,
        # and whisper's multi-temperature retry loop (up to 5 passes) was the
        # dominant latency source on noisier tails (1.2-2.8s -> ~180-450ms).
        temperature=temperature,
        compression_ratio_threshold=2.4,
        logprob_threshold=-1.0,
        no_speech_threshold=0.6,
    )
    return result.get("text", "").strip()
