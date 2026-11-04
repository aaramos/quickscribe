"""QuickScribe sidecar — STT + polish + history service.

FastAPI on 127.0.0.1:8790 per quickscribe/runbook.md contract. Local-only.

STT backends (config [stt] backend; see stt.py):
  omlx   (default) — served by the oMLX server; any STT model in its store.
  local  — mlx-whisper against a local weights dir (HF cache or path).
Polish always goes to the oMLX LLM endpoint ([llm]) and degrades to raw.
"""
from __future__ import annotations

import asyncio
import logging
import os
import time
import tomllib
from contextlib import asynccontextmanager
from pathlib import Path

import uvicorn
from fastapi import FastAPI, File, HTTPException, Query, UploadFile
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from history import History
from polish import Polisher
from stt import STTEngine

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
log = logging.getLogger("quickscribe")

HERE = Path(__file__).resolve().parent
CFG_PATH = Path(os.environ.get("QUICKSCRIBE_CONFIG", HERE / "config.toml"))

with open(CFG_PATH, "rb") as fh:
    CFG = tomllib.load(fh)

_STT = CFG["stt"]
_OMLX = _STT.get("omlx") or {}  # [stt.omlx] table (base_url, timeout_s)

stt_engine = STTEngine(
    backend=_STT.get("backend", "omlx"),
    model_id=_STT["model_id"],
    language=_STT.get("language", "en"),
    candidates=_STT.get("models", []),
    omlx_base_url=_OMLX.get("base_url", "http://127.0.0.1:1234/v1"),
    timeout_s=float(_OMLX.get("timeout_s", 20)),
)
polisher = Polisher(
    base_url=CFG["llm"]["base_url"],
    model=CFG["llm"]["model"],
    timeout_s=CFG["llm"].get("timeout_s", 6),
    keepalive_s=CFG["llm"].get("keepalive_s", 60),
)
history = History(
    db_path=Path(os.path.expanduser(CFG["history"]["db_path"])),
    limit=CFG["history"].get("limit", 50),
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Warm STT at startup (omlx: liveness probe + one silent decode; local:
    # weights load). load() never raises — a downed backend degrades to
    # stt_ready=false and self-heals; the server itself always comes up so
    # polish + history stay alive.
    t0 = time.perf_counter()
    await stt_engine.load()
    log.info("STT warm in %.2fs (backend=%s model=%s ready=%s)",
             time.perf_counter() - t0, stt_engine.backend, stt_engine.model_id, stt_engine.ready)
    # LLM readiness is checked lazily; /health reflects last probe.
    await polisher.probe()
    # Keep oMLX model resident so first /polish after long idle isn't a cold-start.
    await polisher.start_keepalive()
    yield
    await polisher.close()


app = FastAPI(title="QuickScribe sidecar", lifespan=lifespan)


class PolishBody(BaseModel):
    text: str
    profile: str = "polish"


class CaptureBody(BaseModel):
    raw: str
    polished: str
    profile: str
    ms_stt: int
    ms_polish: int


class ModelBody(BaseModel):
    model: str


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "stt_ready": await stt_engine.check_ready(),
        "llm_ready": await polisher.probe(),
        "model": polisher.model,
    }


@app.get("/models")
async def list_models():
    """Live oMLX model list for the menu-bar picker."""
    return JSONResponse({"models": await polisher.list_models(), "current": polisher.model})


@app.post("/models")
async def switch_model(body: ModelBody):
    """Hot-swap the polish model — no restart. On failure the previous
    model stays active and ok=false is returned."""
    name = body.model.strip()
    if not name:
        raise HTTPException(status_code=400, detail="model must be non-empty")
    ok, active = await polisher.set_model(name)
    return JSONResponse({"ok": ok, "model": active})


@app.get("/stt/models")
async def list_stt_models():
    """Candidate transcription models for the menu-bar picker. omlx backend:
    curated config list ∩ what oMLX serves, plus anything STT-looking oMLX
    has picked up (new models appear without a sidecar change). local:
    curated + active + HF-cache whisper repos."""
    return JSONResponse({"models": await stt_engine.models(),
                         "current": stt_engine.model_id})


@app.post("/stt/models")
async def switch_stt_model(body: ModelBody):
    """Hot-swap the transcription model — no restart. The candidate is
    warm-loaded (possibly a cold load) BEFORE committing: on failure the
    previous model stays active and ok=false is returned (same contract as
    POST /models for the polish LLM)."""
    name = body.model.strip()
    if not name:
        raise HTTPException(status_code=400, detail="model must be non-empty")
    ok = await stt_engine.set_model(name)
    return JSONResponse({"ok": ok, "model": stt_engine.model_id})


@app.post("/transcribe")
async def transcribe(
    file: UploadFile = File(...),
    partial: bool = Query(False, description="in-flight chunk: cumulative or incremental audio"),
):
    if not await stt_engine.check_ready():
        raise HTTPException(status_code=503, detail="stt not ready")
    audio = await file.read()
    if not audio:
        raise HTTPException(status_code=400, detail="empty audio")
    t0 = time.perf_counter()
    try:
        text = await stt_engine.transcribe(audio)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=f"bad audio: {exc}") from exc
    ms = int((time.perf_counter() - t0) * 1000)
    log.info("transcribe backend=%s partial=%s bytes=%d ms=%d",
             stt_engine.backend, partial, len(audio), ms)
    return JSONResponse({"text": text, "language": stt_engine.language, "ms": ms})


@app.post("/polish")
async def polish(body: PolishBody):
    if body.profile not in ("polish", "rewrite"):
        raise HTTPException(status_code=400, detail="profile must be 'polish' or 'rewrite'")
    t0 = time.perf_counter()
    text, degraded = await polisher.polish(body.text, body.profile)
    ms = int((time.perf_counter() - t0) * 1000)
    log.info("polish profile=%s degraded=%s ms=%s", body.profile, degraded, ms)
    return JSONResponse({"text": text, "degraded": degraded, "ms": ms})


@app.post("/capture")
async def capture(body: CaptureBody):
    entry = history.add(
        raw=body.raw,
        polished=body.polished,
        profile=body.profile,
        ms_stt=body.ms_stt,
        ms_polish=body.ms_polish,
    )
    return JSONResponse({"ok": True, "id": entry})


@app.get("/history")
async def get_history(limit: int = Query(50, ge=1, le=50)):
    return JSONResponse(history.recent(limit))


if __name__ == "__main__":
    uvicorn.run(
        app,
        host=CFG["server"]["host"],
        port=CFG["server"]["port"],
        log_level="info",
    )
