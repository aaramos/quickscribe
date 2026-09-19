# QuickScribe: how it stays fast

*The architecture story, for engineers. Every number here is in `docs/benchmark.md`, produced by `sidecar/benchmark.py` against the live service. No estimates.*

## The pitch, if you just want it

**Speak messy. Land clean text. Fully local.**

Hold ⌃⌘, talk the way you actually talk — fillers, restarts, "you know" and all. Release. About half a second later, a clean version of what you said is typing itself into the app you were already using. Your clipboard is exactly what it was before. Nothing left your machine: the audio goes to a service on `127.0.0.1`, the transcript gets cleaned by an LLM running on your own hardware, and the history lives in a sqlite file you could delete with `rm`.

No account. No upload. No "30 seconds from stop-talking to usable text" cloud round trip.

---

## Now, for real: the architecture

Two processes, one contract, zero cloud.

```
┌─────────────────────────┐        HTTP/JSON         ┌──────────────────────────┐
│  QuickScribe.app        │ ──── 127.0.0.1:8790 ──▶ │  sidecar (FastAPI)       │
│  native Swift, menu-bar │                           │                          │
│  · global hotkey        │   /transcribe (wav)      │  MLX Whisper (warm)      │
│  · overlay pill         │   /polish (json)         │  oMLX polish  :1234    │
│  · AVAudioEngine 16k    │   /capture /history      │  sqlite history          │
│  · clipboard ⌘V insert  │                           │  keepalive pings         │
└─────────────────────────┘                           └──────────────────────────┘
```

The app owns the keyboard, the mic, and the target app. The sidecar owns every model. The app never references a model name; the sidecar never sees a keystroke. The HTTP contract is fixed in `runbook.md` and both lanes coded against it from day one, in parallel, without waiting on each other.

### 1. Transcription overlaps speech

This is the whole latency strategy. While you're talking, the app captures 1.5-second WAV chunks (16 kHz mono int16 via `AVAudioEngine` + `AVAudioConverter`) and streams each one to `POST /transcribe?partial=true` as it completes. Whisper transcribes each chunk with its own context; the app concatenates the partials **verbatim** — no fuzzy dedup, no client-side heuristics. That choice is deliberate (ADR-001): overlapping chunks would soften boundary word-cuts but force lossy dedup that corrupts the raw transcript in history. Non-overlapping chunks make assembly exact and auditable.

Consequence at hotkey release: almost all of your speech is already transcribed. Only the audio **tail** — the sub-1.5 s sliver buffered at release — remains. Measured tail STT: **~204–214 ms P50** across all fixture lengths.

One in-flight chunk at a time, newest-kept coalescing: if a chunk response is slow, the next chunk queues behind it rather than piling up parallel requests against a serialized engine.

### 2. Models are warm. Always.

Cold-start is the silent killer of dictation UX — the first utterance of the day paying 10+ seconds of weight loading. Three defenses:

- **LaunchAgent at login** (`com.quickscribe.sidecar`, `RunAtLoad` + `KeepAlive`): the sidecar boots before you sit down, loads Whisper during your morning coffee, and auto-restarts if it ever dies.
- **Startup warm-load**: `lifespan()` calls `stt_engine.load()` — a zero-length transcribe to force weights resident — before the service accepts traffic.
- **oMLX keepalive**: the polish model gets a 1-token completion every 60 s. Without it, oMLX evicts an idle model and the first polish after lunch is a cold-start. Verified: after **11 minutes idle**, first polish returned in **380 ms, degraded=false**.

### 3. Polish is bounded, not optimistic

Polish hits a local flash-class model through oMLX (~0.65 s round-trip for ~50 words). But the app doesn't give it unlimited time: the polish call gets **whatever the TTI budget has left** after the tail STT already spent some of it, counted from the hotkey-release timestamp. Budget exhausted means polish wait is capped at 200 ms floor, then whatever comes back — or doesn't — the text gets inserted.

Degradation ladder: success → degraded (LLM error) → retry once with remaining budget → insert raw transcript with an `! LLM down` overlay. The user always gets text. Cloud products make you wait or fail; QuickScribe makes a smaller promise and keeps it.

(Selection note, earned the hard way: the polish model was switched from a Flash-Next-class model to Qwen3.5-9B-oQ8e-mtp because the former had `reasoning_effort=medium` pinned server-side and burned hundreds of thinking tokens before visible output — TTFT 6 s+. A model that produces *no reasoning tokens* is the right model for a 6-second-timeout job. That's in `config.toml` comments so the next person doesn't "upgrade" it back.)

### 4. Insertion respects your machine

Text lands in the focused app via the clipboard-restore technique: snapshot the pasteboard (all readable types), write our text with an internal marker type, synthesize ⌘V, then — after the paste is consumed, 0.6 s — restore the original clipboard if it still holds our payload. The marker prevents recursion; the change-count check means if *you* copied something mid-flight, your copy wins, not our restore. Known v1 edge case, logged and surfaced: cloud-only Universal Clipboard images can't always be restored.

Exactly-once insertion is guarded two ways: an `insertOnce` latch and a session `generation` counter that invalidates any in-flight chunk or polish that straggles back after you hit Esc.

### 5. Localhost is the whole network

`grep` the Swift sources for URLs: one hit, `http://127.0.0.1:8790`. The sidecar binds `127.0.0.1` only, no auth (nothing to authenticate against — it never leaves the loopback interface), and reaches oMLX at `127.0.0.1:1234`. No telemetry, no analytics, no phone-home, by prohibition in the runbook and by structure: the app can't even name a model to phone it about.

## The numbers

TTI = hotkey-release → text present, measured **per run end-to-end** against the live sidecar (tail `/transcribe` → `/polish` → simulated insert +50 ms), 7 runs per cell, not hand-summed from components.

| Utterance | TTI P50 | Budget P50 | TTI P95 | Budget P95 |
|---|---|---|---|---|
| 10 s | 517 ms | 1.5 s | 549 ms | 3 s |
| 30 s | 564 ms | 2.5 s | 648 ms | 5 s |
| 60 s | 520 ms | 5 s | 535 ms | 10 s |

Notice the flat profile — 60 s costs the same as 10 s. That's the streaming design showing up in the data: utterance length barely matters because length was already handled *while you were speaking*.

Reproduce it yourself: `.venv/bin/python benchmark.py` re-runs the fixtures and rewrites the evidence file. If we ever regress, the numbers say so before you do.

## What this is not

v1 is deliberately small: English only, no voice commands ("new paragraph" is *not* supported — type it or say it and edit it), no diarization, no multi-user, no sync/search/export, no settings zoo (hotkeys and profile choice, that's the menu). The out-of-scope list in `brief.md` is longer than the feature list, and that's what kept it fast.
