# QuickScribe (working title) — Brief

## One-liner
A menu-bar dictation app for macOS: tap a global hotkey, speak, and polished text types itself into whatever app has focus — fully local, built for speed.

## Who it's for
Primary: the owner of an Apple Silicon desktop (256GB, oMLX serving local LLMs). Power user who dictates constantly into chat fields, terminals, editors, and email.
Secondary (door open, not scope): other Mac users — the build must stay renameable/packageable, but v1 ships for this machine only.

## The problem
Voice-to-text today forces a choice: raw transcripts that read like speech (fillers, mishearings, run-on sentences), or slow cloud products with round-trip latency and privacy cost. 30 seconds from stop-talking to usable text is a non-starter.

## Behavior (v1)
1. Menu-bar app (no dock icon). Global hotkey (REVISED 2026-09-18 at owner request — the original ⌘⌥Space binding collided with other apps):
   - **Hold ⌃⌘ = push-to-talk.** Release either modifier → stop, polish, insert. This is the only keyboard gesture.
   - Tap-to-toggle is **retired**: a modifier-only chord cannot distinguish tap from hold. Hands-free toggle moves to a menu-bar item ("Start/Stop Recording").
   - While ⌃⌘ is held, capture starts only after a ~150 ms dwell with no other key pressed; any key press before that abandons the start and passes the event through **unchanged** (⌃⌘Q, ⌃⌘F, ⌃⌘Space et al. must keep working). A key press during capture cancels it with nothing inserted.
   - Collision regression is an acceptance criterion (see AC1).
2. While speaking, a minimal overlay pill appears: status + live partial transcript so the user knows it's listening and understanding.
3. On stop, the pipeline (local STT → local LLM cleanup) completes and the polished text is **inserted into the focused app** (clipboard-restore paste technique).
4. Two cleanup profiles:
   - **Polish (default):** strip fillers (um/uh/you-know), fix mishearings, fix grammar/punctuation/capitalization, keep the user's voice and word choice.
   - **Rewrite (heavy):** restructure into clear sentences, tighten, bullets when the speech was a list, professional tone.
   - Profile switchable from the menu-bar menu; quick variant: **hold ⌃⌘⇧** always means Rewrite (replaces the retired ⌥⌘Space variant).
5. Language: **English only** (STT English-optimized; cleanup prompt English-tuned).
6. Esc cancels the capture — nothing is inserted, clipboard untouched.
7. Empty/failed capture → nothing inserted, subtle overlay state, never a crash.
8. LLM cleanup unavailable/down → **insert the raw transcript anyway** (graceful degradation, logged warning).
9. Clipboard safety: user's clipboard is restored after insertion (with one caveat: if the user's clipboard held unsynced image data that can't be restored, note it in overlay — v1 accepts this edge case).
10. Rolling history: last 50 captures (raw + polished) browsable from the menu, click to copy. No search, no export.

## Speed requirements (non-negotiable)
"Time to Insert" (TTI) = hotkey-release → text present in the focused app. Measured, not estimated.

| Utterance length | TTI P50 | TTI P95 |
|---|---|---|
| ≤ 10 s | ≤ 1.5 s | ≤ 3 s |
| ≤ 30 s | ≤ 2.5 s | ≤ 5 s |
| ≤ 60 s | ≤ 5 s | ≤ 10 s |

How this must be achieved (architectural constraints, not suggestions):
- Transcription **overlaps with speech** (chunked/speculative transcription during recording), so at release only the audio tail is left to process.
- Models are **warm at login** (sidecar service, models preloaded). No cold-load on first dictation of the day.
- Cleanup uses a fast flash-class local model via oMLX; cleanup of a ~50-word utterance must not add more than ~1 s.
- The overlay updates within 100 ms of hotkey press (perceived latency matters as much as real latency).

## Acceptance criteria (what I review against)
1. App runs on this Mac as a menu-bar item; hold-to-talk works globally in Notes, TextEdit, Chrome, and Terminal; hands-free toggle works from the menu bar. **Collision regression: ⌃⌘Q, ⌃⌘F, ⌃⌘Space, ⌃⌘← must behave exactly as they did before QuickScribe was installed** — QuickScribe must not swallow them.
2. TTI budgets above are met with **evidence**: benchmark script + results logged (`docs/benchmark.md`), demonstrated in a real focused app.
3. Polish profile demonstrably removes fillers/fixes punctuation while preserving phrasing; Rewrite demonstrably restructures; both switchable without relaunch.
4. Esc cancels cleanly; LLM-down inserts raw transcript; no crash paths in the demo.
5. Clipboard restored after insert (verified with a pre-set clipboard).
6. Mic + Accessibility permissions requested once, with clear onboarding; no other permission prompts.
7. History shows last 50 captures, copy-on-click.
8. 100% local: no network calls except localhost sidecar + local oMLX. Verifiable (no cloud endpoints in code).
9. Repo builds a renameable .app (bundle id + display name in one config spot). No notarization/updater needed.

## Out of scope (v1)
Cloud STT/LLM of any kind · languages other than English · voice commands ("new line" vocab) · speaker diarization · multi-user · sync/export/search of history · plugin system · Windows/Linux · notarized distribution, auto-update, App Store packaging · per-app hotkey profiles · translation.

## Naming
"QuickScribe" is a working title; renaming must be a one-place change (see runbook packaging note).
