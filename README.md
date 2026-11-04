# QuickScribe

Menu-bar dictation for macOS. Hit a hotkey, talk, and clean text types itself into whatever app has focus — no cloud, no round trip, measured fast.

- **Fully local.** A native Swift menu-bar app captures audio and streams it to a sidecar service on `127.0.0.1`; the sidecar runs MLX Whisper for STT and a local oMLX-served LLM for cleanup. There are no external endpoints in the code — the only URL the app knows is `http://127.0.0.1:8790`.
- **Fast, proven fast.** Time-to-Insert (hotkey release → text on screen) is measured end-to-end against the live sidecar, not estimated. Current results: **517 ms P50** for a 10-second utterance, 564 ms for 30 s, 520 ms for 60 s — all inside budget. See [docs/benchmark.md](docs/benchmark.md).
- **Speak messy, land clean.** The default *polish* profile strips fillers, fixes mishearings, punctuation, and capitalization while keeping your words. *Rewrite* restructures into tight prose with bullets when you rambled a list.

Built for one machine today (a Mac Studio running oMLX), designed to be renameable and packageable for tomorrow.

## How it works (30-second version)

Two pieces:

| Piece | What it is | Where |
|---|---|---|
| **QuickScribe.app** | Native Swift menu-bar app: hotkey, overlay pill, audio capture, text insertion | `app/` |
| **Sidecar** | FastAPI service: Whisper STT, LLM polish, history | `sidecar/` |

The app never touches models. The sidecar never touches your keyboard. They only speak HTTP over localhost.

## Install

Requirements: macOS 14+, Python 3.11, a local oMLX server on `127.0.0.1:1234` serving a fast chat model (startup defaults live in `sidecar/config.toml` — both the polish LLM and the transcription model are switchable live from the menu bar), Apple Silicon required for MLX.

### 1. Sidecar

```bash
cd quickscribe/sidecar
./install_deps.sh                      # python3.11 venv + requirements
cp com.quickscribe.sidecar.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.quickscribe.sidecar.plist
```

The LaunchAgent starts at login and auto-restarts on crash. First boot downloads the Whisper model once; after that it's offline-capable. Note: the plist hardcodes this machine's absolute paths — edit `ProgramArguments`/`WorkingDirectory` if you install elsewhere. Verify:

```bash
curl http://127.0.0.1:8790/health
# {"status":"ok","stt_ready":true,"llm_ready":true}
```

### 2. App

```bash
cd quickscribe/app
./build_app.sh
open build/QuickScribe.app
```

First launch asks for two permissions — grant both:
- **Microphone** — capture your voice (audio goes only to localhost)
- **Accessibility** — global hotkey listening and the ⌘V paste that inserts text

A 🎙︎ icon appears in the menu bar. That's the whole UI. (Sidecar down? The icon becomes 🚫 with a tooltip; nothing crashes.)

## Hotkeys

| Keys | Action |
|---|---|
| **Hold ⌃⌘** | Push-to-talk: capture starts after a brief dwell (no key pressed during it); release either modifier to finish |
| **Hold ⌃⌘⇧** | Same gesture, forced **Rewrite** profile |
| **⌃⌘1 / ⌃⌘2 / ⌃⌘3** | Pick Polish, Concise or Active Voice, before or during a dictation |
| **⌃⌘ + any other key** | Passes through untouched — ⌃⌘F, ⌃⌘Q, ⌃⌘Space work exactly as before; a key press during capture cancels it (nothing inserted) |
| **Esc** | Cancel — nothing is inserted, clipboard untouched |
| **Menu bar → Start Recording (hands-free)** | Hands-free toggle: record until you click Stop |

Modifier-only hold (owner UX change 2026-09-18 — the old ⌘⌥Space binding collided with other apps and is removed). Capture only arms once both ⌃ and ⌘ have been held ~150 ms with no key in between, so ⌃⌘-prefixed system shortcuts keep working everywhere. Works globally — Notes, TextEdit, Chrome, Terminal.

## Profiles

Choose from the menu-bar menu (switchable without relaunch):

- **Polish** (default) — removes fillers, honors self-corrections ("at 2, actually 3" becomes "at 3"), fixes punctuation and mishearings, formats lists. Keeps your meaning and tone.
- **Concise** — the shortest version that still says everything.
- **Active Voice** — turns passive sentences active when the actor is known.
- **Rewrite** — tighten into clear sentences, bullets for lists, professional tone. Preserves all information.

Your choice is remembered. You can also pick a mode with ⌃⌘1/2/3, or by starting a dictation with "switch to concise" (alone, or followed by a period and the text to dictate).

**Menu bar → Settings…** shows the prompt behind Polish, Concise and Active Voice. Edit and save to change the very next dictation, reset to get the factory text back, or try a draft on sample dictation without saving. Your edits are stored in `~/Library/QuickScribe/prompts.json`, separate from the factory text, so updates never overwrite them.

If the polish step comes back unusable (LLM down, or a completion with no content), QuickScribe retries once and then inserts the **raw transcript** rather than making you wait — the overlay says `! Polish unavailable — inserted raw text`.

## Models

Two menu-bar submenus, switchable without relaunch:

- **Polish Model** — the local oMLX chat model used for cleanup; the list is live from oMLX.
- **Transcription Model** — the MLX Whisper model doing STT. Candidates: the `[stt] models` list in `sidecar/config.toml` plus every mlx-community Whisper already in the local Hugging Face cache (pure local scan — the app itself never lists from the network). A switch **warm-loads the candidate before committing** (first switch to a not-yet-downloaded repo fetches it once, then offline); anything failing leaves the previous model active — and the checkmark honestly stays on it. Your choice persists and re-applies even if the sidecar restarts on its config default.

## Details worth knowing

- **Your clipboard comes back.** Insertion snapshots your clipboard, pastes, then restores what you had. Known v1 edge case: a cloud-only Universal Clipboard image may not survive restoration (the overlay logs it).
- **History.** Last 50 captures (raw + polished) in the menu → History; click a row to copy the polished text. Stored in a local sqlite file (`~/Library/QuickScribe/history.sqlite3`). No search, no export, no sync — on purpose.
- **Live partials.** While you speak, 1.5-second audio chunks stream to the sidecar and the overlay pill shows the transcript building in real time. At release, only the audio tail is left to transcribe — that's where the sub-second TTI comes from.
- **English only** in v1.

## Rename it

App display name and bundle ID live in exactly one place: `app/Sources/QuickScribe/AppInfo.swift`. Edit, rebuild, done. "QuickScribe" is a working title by design.

## Layout

```
quickscribe/
  README.md            # you are here
  brief.md             # product brief (behavior, speed budgets, acceptance)
  runbook.md         # contracts + settled decisions
  app/               # Swift menu-bar app (SwiftPM; build_app.sh assembles .app)
  sidecar/           # FastAPI sidecar (server.py, stt.py, polish.py, history.py)
  docs/
    about.md         # the speed-first architecture story
    benchmark.md     # measured TTI evidence
    decisions/       # ADRs
```

## Re-verify the numbers

```bash
cd quickscribe/sidecar
.venv/bin/python -m unittest discover -s tests -t .   # sidecar tests
.venv/bin/python benchmark.py     # runs synthetic 10/30/60s fixtures, rewrites docs/benchmark.md
```
