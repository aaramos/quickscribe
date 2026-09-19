# QuickScribe Runbook

Read this before touching anything. Decisions here are settled — do not re-litigate them in comments; block a card only for genuinely new ambiguity.

## Team & cards
- `backend` → sidecar service (card A)
- `frontend` → menu-bar app + overlay (card B, parent = A)
- `backend` owns the benchmark harness too (lives in sidecar repo tree, card A deliverable)
- `gtm` → README + launch copy (card C, parents = A+B)

## Workspace layout (all relative to $REPO_ROOT/)
```
sidecar/            # backend lane
  server.py         # FastAPI app
  stt.py            # Whisper-class engine wrapper (speculative/chunked transcription)
  polish.py         # oMLX cleanup client (profiles: polish|rewrite)
  history.py        # sqlite: last 50 captures
  benchmark.py      # TTI harness (synthetic wav fixtures -> timings)
  fixtures/         # test audio (10s / 30s / 60s utterances)
  requirements.txt
app/                # frontend lane
  Package.swift     # SwiftPM executable; builds QuickScribe.app via build_app.sh
  Sources/...
  build_app.sh      # assembles .app bundle (Info.plist, icon)
docs/
  benchmark.md      # required evidence for acceptance criterion 2
  decisions/        # ADRs if any decision truly needs one
```
File naming: snake_case python, standard Swift conventions. No spaces in filenames.

## Contracts (the two things both lanes must agree on — this is the law)

### Sidecar HTTP API (localhost only, port 8790)
```
GET  /health            -> {"status":"ok","stt_ready":bool,"llm_ready":bool}
POST /transcribe        # multipart: file=<wav 16k mono int16>; query: partial=true for in-flight chunks
                        -> {"text": "...", "language":"en"}
POST /polish            # json: {"text":"...","profile":"polish"|"rewrite"}
                        -> {"text":"...", "degraded":false}
                        # degraded=true when LLM down and raw echoed back
POST /capture           # history write: {"raw":"...","polished":"...","profile":"...","ms_stt":int,"ms_polish":int}
GET  /history?limit=50  -> [{"raw":...,"polished":...,"profile":...,"ts":...}]
```
All JSON, UTF-8. No auth (localhost bind 127.0.0.1 only).

### Model policy (backend decides specifics within these bounds — no cloud, no down-quantizing quality for speed beyond what still beats the TTI budget)
- STT: MLX-native streaming-capable whisper (e.g. whisper.mlx / mlx-whisper large-v3-turbo class). Warm-loaded at service start.
- LLM cleanup: fast flash-class model already served by local oMLX (http://127.0.0.1:port per host config — read from oMLX, do not hardcode a model name in app code; expose model name in sidecar config).
- Sidecar is the ONLY component that talks to models. The app never touches STT/LLM directly.

## Process / runtime topology (settled)
- Sidecar runs as a **LaunchAgent** (label `com.quickscribe.sidecar`), started at login, auto-restart on crash. The menu app talks HTTP to it; app restart never disturbs the sidecar.
- The app owns: hotkey, overlay, audio capture (AVAudioEngine 16k mono), streaming chunks to sidecar at ~1–2 s boundaries, final assembly, insertion, clipboard restore.
- The sidecar owns: STT engine, polish, history, warm-up.
- Audio chunk format to /transcribe partial: raw wav, cumulative-or-incremental is backend's call — but final TTI math assumes only the tail is transcribed post-release.

## Handoff protocol
- Frontend codes against THIS document's contract from day one (no waiting on card A to finish; the contract is the interface).
- Any contract change = backend comments on card A first, frontend acknowledges. Never silently change endpoint shapes.
- Blockers: `kanban_comment` on your card → pm answers with a decision, not a question.

## Definition of done (per role)
- backend: sidecar installed as LaunchAgent on this machine, healthy on :8790, models warm, endpoints match contract exactly, benchmark.py runs and wrote real numbers into docs/benchmark.md, history populated.
- frontend: QuickScribe.app builds via build_app.sh, launches, permissions onboarding works, hold+tap modes work, insert works in the 4 test apps, esc/clipboard/history/overlay states per brief, no console crash logs in demo.
- gtm: README.md (what/why/install/use/hotkeys), plus docs/about.md with the speed-first design story for engineers and a short end-user pitch. Facts must match the code — read it before writing it.

## Do NOT (load-bearing)
- Do NOT add cloud endpoints, telemetry, analytics, or "phone home" of any kind. Localhost + oMLX only.
- Do NOT invent voice commands ("new paragraph" etc.) — out of scope v1.
- Do NOT build an editor UI, settings window zoo, or preferences beyond: hotkey config (one screen max), profile choice.
- Do NOT pin/rename models in app code (frontend never references model names at all; sidecar reads from its own config).
- Do NOT run package managers inside /workspace/App/* mounts (host live apps) — this project lives in ~/Projects, use venvs for python deps.
- Do NOT restructure the layout above or rename top-level dirs.
- Do NOT "optimize" the app into Electron/web views — native Swift menu-bar app is settled; the sidecar is the escape hatch for ML heaviness.
- Do NOT write to git remotes or create GitHub repos; local commits only.
- Do NOT mark a card done with a known unfinished step (deploy/restart) — file the follow-up card instead.
