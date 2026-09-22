#!/usr/bin/env python3
"""Model bake-off driver — task t_42b25328.

Drives the REAL QuickScribe product path: POST :8790/models (hot-swap) +
POST :8790/polish (profile polish|rewrite). Raw oMLX direct is used ONLY for
the Qwen3.6 thinking-off comparison (identical payload to the sidecar's).

Protocol per model (PM traps honored):
  1. hot-swap via /models (server-side warm ping = load, recorded as cold)
  2. first real polish on S1 = cold measurement (recorded separately)
  3. priming: 2 warm polish runs on filler samples (discarded from timing)
  4. timing runs: 10 samples x 2 profiles x RUNS reps, streaming not needed
     here (sidecar streams internally), record ms + output + degraded flag.

Qwen3.6-35B-A3B extra: thinking is ON by default (defect). Measured honest
as-is through the sidecar on 2 samples x 2 reps (documented, NOT timed for
verdict), then full comparison direct-to-oMLX with chat_template_kwargs
enable_thinking=false (same system prompts/temperature/max_tokens as sidecar).

Evidence: JSONL, one event per call. Failures are recorded, never skipped.
"""
import json, statistics, sys, time, pathlib
import httpx

ROOT = pathlib.Path("/Users/macstudio/Projects/multi-agent-team/quickscribe")
CORPUS = json.loads((ROOT / "sidecar/fixtures/bakeoff_corpus.json").read_text())
SIDE = "http://127.0.0.1:8790"
OMLX_KEY = json.load(open(pathlib.Path.home() / ".omlx/settings.json"))["auth"]["api_key"]
OMLX = "http://127.0.0.1:1234/v1"
OUT = ROOT / "evidence/t_42b25328/bakeoff.jsonl"
OUT.parent.mkdir(parents=True, exist_ok=True)

RUNS = 5
DEFAULT_MODEL = "Qwen3.5-9B-oQ8e-mtp"
MODELS = [
    "Qwen3.5-9B-oQ8e-mtp",          # current default
    "gemma-4-e4b-it-4bit",
    "Phi-4-mini-instruct-4bit",
    "Mistral-Small-3.2-24B-Instruct-2506-4bit",
    "gemma-4-26b-a4b-it-4bit",
    "Qwen3.6-35B-A3B-4bit",         # thinking-on defect: special path
]

SYSTEM_PROMPTS = {
    "polish": ("Clean up this dictated text: strip fillers (um, uh, you know), fix obvious "
               "mishearings, grammar, punctuation, capitalization. Keep the speaker's words. "
               "Output only the cleaned text."),
    "rewrite": ("Rewrite this dictated text as clear prose: tighten wording, well-formed "
                "sentences, bullets for lists, professional tone. Preserve all information. "
                "Output only the rewritten text."),
}

ev = OUT.open("a")
def emit(obj):
    obj["ts"] = round(time.time(), 3)
    ev.write(json.dumps(obj, ensure_ascii=False) + "\n")
    ev.flush()
    print(f"[{time.strftime('%H:%M:%S')}] {obj.get('model','')} {obj.get('kind','')} "
          f"{obj.get('sample','')} {obj.get('profile','')} ms={obj.get('ms','')} "
          f"dep={obj.get('degraded','')}", flush=True)

def side_polish(text, profile, timeout=90.0):
    t0 = time.perf_counter()
    try:
        r = httpx.post(f"{SIDE}/polish", json={"text": text, "profile": profile}, timeout=timeout)
        ms = int((time.perf_counter() - t0) * 1000)
        j = r.json()
        return ms, j.get("text", ""), j.get("degraded", True), None
    except Exception as exc:
        ms = int((time.perf_counter() - t0) * 1000)
        return ms, "", True, f"{type(exc).__name__}: {exc}"

def omlx_polish(model, text, profile, thinking=False, timeout=180.0):
    payload = {
        "model": model,
        "messages": [{"role": "system", "content": SYSTEM_PROMPTS[profile]},
                     {"role": "user", "content": text}],
        "temperature": 0.3,
        "max_tokens": min(2048, max(128, len(text) * 2)),
        "chat_template_kwargs": {"enable_thinking": thinking},
    }
    t0 = time.perf_counter()
    try:
        r = httpx.post(f"{OMLX}/chat/completions",
                       headers={"Authorization": f"Bearer {OMLX_KEY}"},
                       json=payload, timeout=timeout)
        ms = int((time.perf_counter() - t0) * 1000)
        j = r.json()
        if r.status_code != 200:
            return ms, "", True, json.dumps(j)[:200], None
        c = j["choices"][0]["message"]
        return ms, (c.get("content") or "").strip(), False, None, c.get("reasoning_content")
    except Exception as exc:
        ms = int((time.perf_counter() - t0) * 1000)
        return ms, "", True, f"{type(exc).__name__}: {exc}", None

def switch(model):
    r = httpx.post(f"{SIDE}/models", json={"model": model}, timeout=180)
    j = r.json()
    emit({"kind": "switch", "model": model, "ok": j.get("ok"), "active": j.get("model")})
    return j.get("ok")

def timed_block(model, reps=RUNS, direct=False, thinking=False, note=""):
    for profile in ("polish", "rewrite"):
        for sid, item in CORPUS.items():
            for rep in range(reps):
                if direct:
                    ms, out, dep, err, _ = omlx_polish(model, item["text"], profile, thinking)
                else:
                    ms, out, dep, err = side_polish(item["text"], profile)
                    _ = None
                emit({"kind": "timed", "note": note, "model": model, "sample": sid,
                     "profile": profile, "rep": rep, "ms": ms, "degraded": dep,
                     "error": err, "output": out})

def main():
    h = httpx.get(f"{SIDE}/health", timeout=10).json()
    emit({"kind": "start", "health": h})
    for model in MODELS:
        if not switch(model):
            emit({"kind": "skip_model", "model": model, "reason": "switch failed"})
            continue
        # cold: first real call after swap (may already be warm from switch ping)
        ms, out, dep, err = side_polish(CORPUS["S1"]["text"], "polish")
        emit({"kind": "cold", "model": model, "sample": "S1", "profile": "polish",
              "ms": ms, "degraded": dep, "error": err, "output": out})
        # priming (discarded)
        for s in ("S1", "S10"):
            side_polish(CORPUS[s]["text"], "polish")

        if model == "Qwen3.6-35B-A3B-4bit":
            # honest as-is (thinking ON) via sidecar — 2 samples x 2 reps, NOT in verdict timing
            for sid in ("S1", "S4"):
                for rep in range(2):
                    ms, out, dep, err = side_polish(CORPUS[sid]["text"], "polish", timeout=240)
                    emit({"kind": "thinking_on", "model": model, "sample": sid,
                         "profile": "polish", "rep": rep, "ms": ms, "degraded": dep,
                         "error": err, "output": out})
            timed_block(model, direct=True, thinking=False, note="thinking_off_direct")
        else:
            timed_block(model)

    # restore product default
    switch(DEFAULT_MODEL)
    emit({"kind": "done", "restored": DEFAULT_MODEL})

    # quick summary
    stats = {}
    for line in OUT.read_text().splitlines():
        e = json.loads(line)
        if e.get("kind") == "timed" and not e.get("degraded") and not e.get("error"):
            stats.setdefault((e["model"], e["profile"]), []).append(e["ms"])
    for (m, p), v in sorted(stats.items()):
        v.sort()
        print(f"{m:42s} {p:8s} n={len(v)} p50={statistics.median(v):.0f} "
              f"p95={v[min(len(v)-1, int(round(0.95*len(v))-1))]:.0f}")

if __name__ == "__main__":
    main()
