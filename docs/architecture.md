# QuickScribe — How It Works (Architecture, in plain terms)

Two programs, one machine, nothing external.

## The two pieces
| Piece | What it does | Runs as |
|---|---|---|
| **QuickScribe.app** | Your keyboard, your screen, your mic | Menu-bar app (native Swift) |
| **Sidecar** | All the thinking | Local web service on `127.0.0.1:8790`, starts at login |

They only ever talk over your own machine. There are no cloud endpoints anywhere in the code.

## The models (the brain power)
| Model | Job | Why this one | Speed |
|---|---|---|---|
| **whisper-large-v3-turbo-4bit** (MLX) | Hearing: speech → raw text | Whisper's fastest accurate tier, runs natively on Apple Silicon; 4-bit = half the memory, same ears | ~0.2s per audio tail |
| **Qwen3.5-9B-oQ8e-mtp** (via oMLX) | Polishing: raw speech → clean prose | Answers instantly with zero "thinking tokens" — its faster sibling was disqualified because it silently deliberates for 6–30s first; 8-bit keeps quality, MTP speculation keeps speed | ~0.5s per cleanup |

Both models are **loaded into RAM at login and kept warm** (a heartbeat ping every 60s) — nothing cold-starts when you speak. On a 256GB Studio this is free.

## Your journey through the system (one dictation)
1. **You hold ⌃⌘** → app starts capturing audio, picks a real microphone automatically, shows its name.
2. **While you talk** → 1.5-second audio chunks stream to the sidecar; Whisper transcribes each chunk as it lands; the overlay shows the words building. *This is the speed trick: most of the transcription happens before you stop speaking.*
3. **You release** → only the last ~2 seconds of audio ("the tail") still needs transcribing (~0.2s).
4. **Cleanup** → the raw text goes to Qwen with your profile's instruction (Polish = keep your voice; ⌃⌘⇧ = Rewrite = restructure), ~0.5s.
5. **Insert** → your clipboard is snapshotted, text pastes into whatever app has focus, your clipboard comes back.

Measured end-to-end: ~1.9–3.0s into real apps, well inside the 1.5–2.5s budget.

## Honesty rules (the "never lie to the user" layer)
- **Silent mic** → decodes nothing, says *"Couldn't hear you — check your mic (device: X)"*, inserts nothing. (This replaced a real failure mode where a silent loopback input made Whisper invent "thank you" on repeat.)
- **LLM down** → inserts your raw words, flags it. Never blocks you waiting.
- **Sidecar dead** → icon goes 🚫, keystroke does nothing rather than half-working; auto-recovers in ~6s.
- **Same phrase twice** → treated as machine noise, suppressed.

## Where things live
- `app/` — Swift: hotkey listener (never steals your shortcuts), overlay, audio capture, insert
- `sidecar/` — Python: Whisper endpoint, polish endpoint, last-50 history (sqlite)
- `docs/benchmark.md` — the measured numbers, raw runs included
- Model names are pinned in exactly one file: `sidecar/config.toml` — swap either model there, restart, done.
