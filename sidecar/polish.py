"""oMLX cleanup client. The caller supplies the system prompt. Degraded fallback echoes raw.

Keeps oMLX warm with a periodic keepalive completion so the first /polish after
long idle is not a cold-start (acceptance: >=10min idle -> degraded=false).
"""
from __future__ import annotations

import asyncio
import json
import logging
import pathlib
import time

import httpx

log = logging.getLogger("quickscribe.polish")

_KEY_PATH = pathlib.Path.home() / ".omlx" / "settings.json"

# The heavy ⌃⌘⇧ profile. The everyday modes are user-editable: see prompts.py.
REWRITE_PROMPT = (
    "Rewrite this dictated text as clear prose: tighten wording, well-formed "
    "sentences, bullets for lists, professional tone. Preserve all information. "
    "Output only the rewritten text."
)


def _api_key() -> str:
    with open(_KEY_PATH) as fh:
        return json.load(fh)["auth"]["api_key"]


class Polisher:
    def __init__(self, base_url: str, model: str, timeout_s: float = 6.0,
                 keepalive_s: float = 60.0):
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.timeout_s = timeout_s
        self.keepalive_s = keepalive_s
        self._llm_ready = False
        self._last_probe = 0.0
        self._client: httpx.AsyncClient | None = None
        self._ka_task: asyncio.Task | None = None
        self._last_ka_ok = 0.0

    # ---- connection / lifecycle -------------------------------------------------

    def _get_client(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(
                timeout=self.timeout_s,
                headers={"Authorization": f"Bearer {_api_key()}"},
                limits=httpx.Limits(max_keepalive_connections=2),
            )
        return self._client

    async def start_keepalive(self) -> None:
        """Warm the model immediately, then keep it resident; call at app startup."""
        if self._ka_task is None:
            self._ka_task = asyncio.create_task(self._keepalive_loop())

    async def _keepalive_loop(self) -> None:
        log.info("keepalive loop started (every %.0fs)", self.keepalive_s)
        # Immediate warm ping: load the model into oMLX now, not on first real use.
        while True:
            try:
                if self._last_ka_ok == 0.0:
                    t0 = time.perf_counter()
                    ok = await self._warm_ping()
                    if ok:
                        self._last_ka_ok = time.monotonic()
                    log.info("initial warm ping ok=%s in %.0fms", ok,
                             (time.perf_counter() - t0) * 1000)
                else:
                    await asyncio.sleep(self.keepalive_s)
                    t0 = time.perf_counter()
                    ok = await self._warm_ping()
                    if ok:
                        self._last_ka_ok = time.monotonic()
                    log.info("keepalive ping ok=%s in %.0fms", ok,
                             (time.perf_counter() - t0) * 1000)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                log.warning("keepalive ping failed: %s", exc)
                await asyncio.sleep(5)

    async def _warm_ping(self) -> bool:
        """Tiny completion — keeps the model resident in oMLX. Same
        chat_template_kwargs as real requests so warm state matches use."""
        try:
            client = self._get_client()
            r = await client.post(
                f"{self.base_url}/chat/completions",
                json={
                    "model": self.model,
                    "messages": [{"role": "user", "content": "ping"}],
                    "max_tokens": 8,
                    "temperature": 0,
                    "chat_template_kwargs": {"enable_thinking": False},
                },
                timeout=120.0,  # first ping may load the model into oMLX
            )
            r.raise_for_status()
            self._llm_ready = True
            self._last_probe = time.monotonic()
            return True
        except Exception as exc:
            log.warning("warm ping failed: %s", exc)
            self._llm_ready = False
            return False

    # ---- model hot-swap ---------------------------------------------------------

    async def list_models(self) -> list[str]:
        """Live model ids from oMLX /models (cheap, no model wake)."""
        try:
            client = self._get_client()
            r = await client.get(f"{self.base_url}/models")
            r.raise_for_status()
            return [m["id"] for m in r.json().get("data", []) if m.get("id")]
        except Exception as exc:
            log.warning("list_models failed: %s", exc)
            return []

    async def set_model(self, model: str) -> tuple[bool, str]:
        """Hot-swap the polish model (no restart). Verifies the new model
        answers a warm ping; on failure the previous model stays active.
        Returns (ok, active_model)."""
        old = self.model
        if model == old:
            return True, old
        self.model = model
        try:
            ok = await self._warm_ping()
        except asyncio.CancelledError:
            self.model = old
            raise
        if not ok:
            self.model = old
            await self._warm_ping()  # re-confirm fallback is resident
            log.warning("model switch to %s failed; staying on %s", model, old)
            return False, old
        self._last_ka_ok = time.monotonic()  # keepalive now keeps NEW model warm
        log.info("polish model hot-swapped %s -> %s", old, model)
        return True, model

    async def probe(self, ttl: float = 5.0) -> bool:
        """Cheap readiness probe, cached for ttl seconds."""
        now = time.monotonic()
        if self._llm_ready and now - self._last_probe < ttl:
            return True
        # /models GET is cheap and doesn't wake the model; try warm ping too.
        try:
            client = self._get_client()
            r = await client.get(f"{self.base_url}/models")
            self._llm_ready = r.status_code == 200
        except Exception:
            self._llm_ready = False
        self._last_probe = now
        return self._llm_ready

    async def close(self) -> None:
        if self._ka_task:
            self._ka_task.cancel()
            self._ka_task = None
        if self._client and not self._client.is_closed:
            await self._client.aclose()

    # ---- main operation ---------------------------------------------------------

    async def polish(self, text: str, system_prompt: str) -> tuple[str, bool]:
        """Returns (text, degraded). degraded=True → polish result unusable
        (LLM down, empty completion, or cut off at max_tokens); raw echoed
        back per contract."""
        text = text.strip()
        if not text:
            return "", False
        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": text},
            ],
            "temperature": 0.3,
            # Copy-editing does not need chain-of-thought, and thinking mode
            # is fatal to the TTI budget: live probe 2026-11-01 (the incident
            # trace the review lacked) — Qwen3.6-35B-A3B-4bit spent 1024/1024
            # tokens on reasoning and emitted ZERO content tokens at the old
            # len*2 cap (the false "empty completion"); at 4096 it answered
            # but took 5.9 s — past every bucket. enable_thinking:false:
            # 120 ms, finish=stop, clean text. Models whose template lacks
            # the toggle ignore the kwarg; the headroom below covers them.
            "chat_template_kwargs": {"enable_thinking": False},
            # Headroom, not a target: generation stops at the stop token, so
            # a large cap costs nothing on well-behaved models and saves
            # stray reasoners from mid-sentence truncation. Wall time stays
            # bounded by the app's PolishPlanner timeout (t_a0fb24bb).
            "max_tokens": min(4096, max(1024, len(text) * 8)),
        }
        try:
            client = self._get_client()
            # Stream: oMLX serializes requests (max_concurrent_requests=1); when
            # queueing behind another client's long generation, streaming still
            # gets tokens the moment our slot opens instead of a flat timeout.
            payload["stream"] = True
            buf = ""
            finish: str | None = None
            async with client.stream(
                "POST", f"{self.base_url}/chat/completions", json=payload,
            ) as r:
                r.raise_for_status()
                async for line in r.aiter_lines():
                    if not line.startswith("data: "):
                        continue
                    chunk = line[6:]
                    if chunk.strip() == "[DONE]":
                        break
                    try:
                        choice = json.loads(chunk)["choices"][0]
                    except (KeyError, IndexError, ValueError):
                        continue
                    if choice.get("finish_reason"):
                        finish = choice["finish_reason"]
                    delta = choice.get("delta", {}).get("content")
                    if delta:
                        buf += delta
            out = buf.strip()
            self._llm_ready = True
            self._last_probe = time.monotonic()
            if not out:
                # 200-but-empty completion: the model consumed max_tokens on
                # reasoning and emitted zero content tokens. Downstream cannot
                # tell this from success — it produced the false "Couldn't
                # hear you — check your mic" blame-the-mic error. Honor the
                # contract (degraded=True → raw echoed back) so the app
                # retries once and inserts raw instead (brief §8).
                log.warning("polish: empty content completion (finish=%s); echoing raw as degraded", finish)
                return text, True
            if finish == "length":
                # Truncated prose silently inserted is WORSE than raw — it
                # loses information while looking finished (observed live
                # 2026-11-01: second clause dropped from a two-part sentence).
                log.warning("polish: completion hit max_tokens (finish=length) — truncated, echoing raw as degraded")
                return text, True
            return out, False
        except Exception as exc:
            log.warning("polish degraded (LLM unavailable): %s", exc)
            self._llm_ready = False
            return text, True