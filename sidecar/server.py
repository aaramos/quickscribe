"""QuickScribe sidecar — local STT + polish + history service.

FastAPI on 127.0.0.1:8790 per quickscribe/runbook.md contract. Local-only.
"""
from __future__ import annotations

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

stt_engine = STTEngine(
    model_id=CFG["stt"]["model_id"],
    language=CFG["stt"].get("language", "en"),
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
    # Warm STT at startup (downloads once on first ever boot, then local).
    t0 = time.perf_counter()
    stt_engine.load()
    log.info("STT warm in %.2fs (model=%s)", time.perf_counter() - t0, stt_engine.model_id)
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


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "stt_ready": stt_engine.ready,
        "llm_ready": await polisher.probe(),
    }


@app.post("/transcribe")
async def transcribe(
    file: UploadFile = File(...),
    partial: bool = Query(False, description="in-flight chunk: cumulative or incremental audio"),
):
    if not stt_engine.ready:
        raise HTTPException(status_code=503, detail="stt not ready")
    audio = await file.read()
    if not audio:
        raise HTTPException(status_code=400, detail="empty audio")
    t0 = time.perf_counter()
    try:
        text = stt_engine.transcribe(audio)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=f"bad audio: {exc}") from exc
    ms = int((time.perf_counter() - t0) * 1000)
    log.info("transcribe partial=%s bytes=%d ms=%d", partial, len(audio), ms)
    return JSONResponse({"text": text, "language": stt_engine.language, "ms": ms})


@app.post("/polish")
async def polish(body: PolishBody):
    if body.profile not in ("polish", "rewrite"):
        raise HTTPException(status_code=400, detail="profile must be 'polish' or 'rewrite'")
    t0 = time.perf_counter()
    text, degraded = await polisher.polish(body.text, body.profile)
    ms = int((time.perf_counter() - t0) * 1000)
    log.info("polish profile=%s degraded=%s ms=%d", body.profile, degraded, ms)
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