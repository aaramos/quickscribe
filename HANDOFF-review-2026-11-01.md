# HANDOFF — review + fix batch, 2026-11-01

**Scope:** full review of `app/Sources/QuickScribe` (12 Swift files, ~2.1k lines) and
`sidecar/polish.py`, followed by a fix batch for every finding, plus RCA of the
reported user-facing defect: *"hold the hotkey → it records, I see it
transcribe — then nothing pastes and it tells me it can't hear me."*

**Author:** reviewing agent (this session). No fresh `t_` id was assigned; use
`t_20261101_review` as the batch id in commit messages and `evidence/` if you
promote this to a card.

---

## 1. Tree state — read before diffing

Everything is **uncommitted**. `git status` shows 9 modified files, but:

- **`sidecar/config.toml` is NOT mine.** The owner changed the polish model
  today (`config.toml.bak-20261101-qwen36swap`, also
  `…bak-20261018-oq6e`). Do not attribute it to this batch, and note it is
  the probable *trigger* of the defect in §2 (new model, empty completions).
- Mine: the 7 files under `app/Sources/QuickScribe/` + `sidecar/polish.py`.

Proof harnesses (`proof-src/*`, `hotkey-proof/proof.swift`) were checked for
compile-relevant coupling: the only internal they touch is
`HotkeyManager._handleForTesting` — kept untouched. All other changed
internals are private. Still rebuild the harnesses (§6.4).

## 2. THE REPORTED DEFECT — root-cause chain (verify this first)

Claim to test: exactly one path produces "transcribed visibly, then *Couldn't
hear you*, then no paste".

1. Mic + STT work → partials render in the overlay, `partialText` non-empty.
   This rules out every "couldn't hear you" branch in
   `resolveFinalText` (they all require an *empty* assembly or a fully-silent
   session).
2. Release → `POST /polish`. `Polisher.polish` (sidecar) only accumulates
   `delta.content`. A model that spends its whole `max_tokens` on *reasoning*
   returns **HTTP 200 with zero content tokens** → `out = ""` →
   `return out, False` → `{"text": "", "degraded": false}`.
3. App: old code `insertText(polished ?? raw, …)` — `""` is not `nil`, so raw
   never became the fallback — and `insertText`'s blank-guard showed
   **"Couldn't hear you — check your mic"**. `Insertion.insert` never ran.
   Correct outcome mislabeled as a mic fault; paste "fails".

Supporting history, already in this repo: `config.toml`'s own comment
documents this model class burning "hundreds of thinking tokens before any
visible output", and `max_tokens = max(128, len(text)*2)` leaves room for it.
**Causation status (t_a0fb24bb): CONFIRMED with a live runtime trace
2026-11-01 21:32–21:41.** After the sidecar was restarted onto the fixed
code, direct oMLX probes showed `Qwen3.6-35B-A3B-4bit` (today's swap)
spending **1024/1024 tokens on reasoning with ZERO content tokens**
(finish=length) at the old `max_tokens = max(128, len*2)` cap; at 4096 it
does answer, but takes 5.9 s — past every TTI bucket. Through the sidecar
the same input reproduced the empty-completion degraded echo, and a
two-clause sentence came back **truncated mid-information** (second
clause silently dropped). Fix (follow-up commit): polish requests now
send `chat_template_kwargs: {"enable_thinking": false}` (measured
120–450 ms, complete text), `max_tokens` got real headroom
(`min(4096, max(1024, len*8))`) as a backstop for stray reasoners, and
`finish=length` is treated as degraded→raw — truncated prose is never
inserted silently. Owner's config model unchanged; oMLX key location
(`~/.omlx/settings.json`) untouched.

**Fix — three layers (each independently sufficient for the symptom):**
- `sidecar/polish.py` → `polish()`: empty completion now logs
  `polish: empty content completion; echoing raw as degraded` and returns
  `(text, degraded=True)` — honoring the contract degraded=raw-echoed.
- `SessionController.polishAndInsert`: `usable = !degraded && !isBlank(polished)`
  — a blank 200 result follows the *existing* degraded ladder: retry once
  within the TTI bucket, then insert **raw** with the `.degraded` overlay.
- `SessionController.insertText`: the mic-blaming message is gone; only
  reachable when raw itself was blank (now impossible via callers) and says
  "Nothing usable to insert". Overlay label for `.degraded` changed to
  "! Polish unavailable — inserted raw text" (true for LLM-down *and* blank).

Grep the unified log after reproducing: old build → nothing; new build →
either sidecar warning or app inserting raw with the degraded badge.

## 3. Full fix table

| # | Severity | File / symbol | Problem (confirmed in code) | Fix |
|---|----------|---------------|------------------------------|-----|
| 1 | **defect** | `polish.py` + `SessionController.polishAndInsert/insertText` | empty LLM completion → false "Couldn't hear you", no paste (§2) | blank ≡ degraded at both layers; retry-once → raw |
| 2 | high | `SessionController.sendChunk / takePendingChunks` | coalescing **replaced** the pending chunk; chunks are non-overlapping audio → silent word-loss whenever STT fell behind real time | buffer accumulates; merged PCM-concatenated into one WAV (`WavWriter.headerSize = 44`) |
| 3 | high | `AudioCapture.startEngine` | throw after `bindForCapture` left the **system default input switched** (`stop()` early-returns while `!isCapturing`, never restored); the permission-retry re-bound and clobbered the restore target | `do/catch` unwinds bind+`activeDevice` on every post-bind failure; defensive unwind at `start()` entry |
| 4 | med | `AudioCapture.ExceptionGuard.run` | body ran under `try?` → **Swift errors discarded**, success reported — e.g. `engine.start()` failing silently → a session that truly hears nothing | Swift error captured and surfaced like an ObjC exception (`swift: …`) |
| 5 | med | `InputDeviceResolver.inputChannels` | summed `mBuffers[0]` once per buffer instead of walking the variable-length `AudioBufferList` | bounds-checked `raw.load(fromByteOffset:)` walk; `AudioPreflight.check` now delegates to it (duplication removed) |
| 6 | med | `AppDelegate.probeSidecar` | one-shot probe → icon stuck dimmed forever if the app beat the LaunchAgent to the port, though dictation worked (and the down-only retry added later went blind to LATER outages after success) | PERMANENT single 30 s monitor in BOTH directions (t_a0fb24bb rework): create-once timer, in-flight gate (no overlapping probes), skipped while recording, transitions owned by the pure `SidecarHealth` reducer (unit-tested) |
| 7 | low | `AppDelegate.ensureAccessibility` | repeating 2 s poll called `rebuildMenu()` unconditionally → swapped `statusItem.menu` under an open menu, forever, while untrusted | rebuild + invalidate only on a trust-state flip |
| 8 | low | `SessionController` metrics | `ms_stt` summed every chunk's decode ms (overlap double-count) — history/benchmark numbers overstated STT latency | wall time releaseAt → raw-ready at `polishAndInsert` entry (**semantic change, §4**) |
| 9 | low | misc | dead code & stale docs: `finalText`, `AppInfo.holdModifiers/holdRewriteModifiers` (+`import CoreGraphics`), `wroteMarker`, `keptTypes` IIFE+comment, `flushTail` "before stop" (actually after, buffered PCM survives), `resolveFinalText` "full re-transcribe" promise, force-unwraps `statusItem.button!` / `NSScreen.main!` | removed / corrected / guarded |

## 4. Judgment calls the reviewer should accept or reject

1. **Filler-only dictation now inserts raw.** "um, uh" → polish legitimately
   returns `""` → treated unusable → retry → **raw inserted** with the
   degraded badge. Chosen rationale: honest fallback > data loss; matches
   brief §8's degrade philosophy. Reject if owner prefers *nothing* inserted
   when the LLM was *up* and cleaned everything away.
   **RESOLVED 2026-11-01 (owner decision via t_a0fb24bb): keep raw fallback
   for blank polish results, including filler-only speech — the transcript
   is never silently discarded.**
2. **Blank results consume the one retry** before raw fallback (bounded by
   the leftover TTI bucket, floor 0.2 s). Cost is latency on deterministic
   blank; benefit is recovering transient blanks.
3. **`ms_stt` meaning changed** (summed decode → release→raw-ready wall).
   History rows and any comparisons **across the boundary are NOT directly
   comparable**; documented in the runbook contract (applied 2026-11-01).
   `sidecar/benchmark.py` measures its own `/transcribe` timings and does
   NOT read history rows, so `docs/benchmark.md` numbers are unaffected.
4. **`polish.py` contract widening**: `degraded=True` now means "LLM down OR
   empty completion". The runbook's contract text still says "when LLM down"
   — proposed doc diff in §7 (NOT applied; contracts are law, you own edits).

## 5. What was verified vs. not

Verified:
- `swift build` → `Build complete!` **zero warnings** (one MainActor
  isolation warning introduced then fixed via `Task { @MainActor }`).
- `python3 -c "import ast; ast.parse(open('sidecar/polish.py').read())"` OK.
- No stale references to removed symbols (`finalText`, `sttMs`,
  `pendingChunk`, `holdModifiers`, `wroteMarker`) anywhere in `app/Sources`.
- `git diff` re-read line-by-line for `SessionController.swift` (§2 logic).

**Not verified (needs this machine):** runtime behavior — hotkey capture,
insertion, bind/restore around a failed start, empty-completion path against
live oMLX, and the proof harnesses (they build outside SwiftPM;
`swift build` does not compile them). Do §6 before trusting the batch.

## 6. Reviewer verification recipe

### 6.1 Build & deploy
```
cd app && swift build              # expect: Build complete!, no warnings
./build_app.sh && open build/QuickScribe.app
launchctl unload ~/Library/LaunchAgents/com.quickscribe.sidecar.plist
launchctl load   ~/Library/LaunchAgents/com.quickscribe.sidecar.plist
curl -s localhost:8790/health      # stt_ready + llm_ready true
```

### 6.2 Targeted: empty-completion degradation (the §2 fix, sidecar layer)
Stub an OpenAI-ish SSE endpoint that streams zero content tokens:
```
python3 - <<'EOF'
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = (b'data: {"choices":[{"delta":{"reasoning_content":"thinking..."}]}\n\n'
                b'data: [DONE]\n\n')
        self.send_response(200); self.send_header("Content-Type","text/event-stream")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", 19999), H).serve_forever()
EOF
```
Run the sidecar with a config copy pointing `[llm] base_url` at
`http://127.0.0.1:19999/v1`, then:
```
curl -s -XPOST localhost:8790/polish -H 'content-type: application/json' \
  -d '{"text":"hello there um","profile":"polish"}'
# expect: {"text":"hello there um","degraded":true,...}   (old: "text":"","degraded":false)
```

### 6.3 Targeted: app layer, blank polish without touching the sidecar
Point the app at the stub-backed sidecar (or stub 8790 itself returning
`{"text":"","degraded":false}`): dictate anything → expect **"! Polish
unavailable — inserted raw text"** and the raw transcript inserted. Old
build: "Couldn't hear you" + nothing.

### 6.4 Regression checklist (manual, this host)
- PTT hold ⌃⌘ ≥150 ms → overlay + partials; release → insert into TextEdit.
- ⌃⌘F / ⌃⌘Space still behave as system shortcuts (dwell abort).
- Any key mid-capture → cancel, nothing inserted. Esc → cancel.
- ⌃⌘⇧ locks Rewrite (release of ⌃ alone still ends correctly; ⇧ toggling
  mid-capture must NOT flip profile — `capturedRewrite`).
- Clipboard preservation: copy a rich item → dictate → after ~0.6 s the
  original pasteboard content is back and your text landed in the field.
- Unplug/replug mic while idle → next capture uses it (t_eec52a7e
  behaviour must survive the engine/bind refactor).
- **Bind leak**: force a failed start (deny Mic permission), then check
  `System Settings → Sound → Input` returns to (or stays on) the user's
  default. Then grant + dictate normally.
- Health monitor (t_a0fb24bb rework — permanent, both directions): kill
  the sidecar → icon dims + tooltip explains within ~30 s **even after a
  healthy start**; restart it → recovers within ~30 s, no app relaunch.
  Probes pause while recording; a delayed response cannot overwrite the
  recording icon (state still tracks, so session end dims/restores
  honestly). Transitions are unit-tested (`SidecarHealthTests`).
- Models submenu hot-swap still round-trips (unchanged path).
- History popover: new rows' `ms_stt` are release→raw-ready wall ms (§4 #3).
- Rebuild proof harnesses per `docs/TESTING.md` build blocks
  (`tapstart-proof`, `hotplug`, level-tap) against the refactored
  `AudioCapture`/`InputDeviceResolver`; PASS criteria unchanged.

## 7. Runbook contract diff — APPLIED 2026-11-01 (t_a0fb24bb doc pass)

```diff
 POST /polish            # json: {"text":"...","profile":"polish"|"rewrite"}
                         -> {"text":"...", "degraded":false}
-                        # degraded=true when LLM down and raw echoed back
+                        # degraded=true when LLM down OR the completion
+                        # carried no content (reasoning-only 200); raw echoed
+                        # back either way; the app retries once, then inserts raw
```

## 8. Residual risks / deliberately out of scope

- **Silence floor duplication**: `AppInfo.silenceRmsFloor` (0.004) still
  manually mirrored in `sidecar/stt.py`. One shared fixture/test is the real
  fix; skipped as cross-lane churn.
- **Clipboard timing**: insertion still uses the fixed 600 ms restore delay
  and paste-by-⌘V-synthesis; target apps that rewrite the pasteboard late
  (or users re-pasting within the window) remain an accepted v1 edge.
- **Unauthenticated localhost sidecar**: any local process can drive the LLM
  / read history. Accepted for single-machine scope (README's claim).
- **Bind design**: capture still flips the *system* default input for the
  capture window (no engine-level device API on this OS build) — invasive by
  necessity; §3 #3 makes it fail-closed, not invisible.
- `ensureAccessibility` still polls every 2 s until the grant (now cheap —
  no menu swaps); stopping the poll entirely would break the
  "grant-then-live" onboarding, so left as-is.
- Guarded force-unwraps (`polished!`, `p2!`) sit behind `usable` checks that
  make them safe by construction; a reviewer may prefer `guard let` style.

## 9. Suggested commits (repo style)

```
fix(app): blank polish fallback — never blame the mic for an empty completion (t_20261101_review)
fix(app): coalesce stream chunks by concat, unwind device bind on failed start, surface Swift errors in ExceptionGuard
fix(sidecar): empty content completion returns degraded=true with raw echoed back
chore(app): metrics, honest labels, dead-code removal (ms_stt = release→raw-ready wall)
```

**Merge gate:** §6.1–6.3 green + owner ruling on §4 #1.

## 10. Addendum — Transcription Model setting (requested after the handoff, same tree)

New owner-facing feature on top of §1–9: change the STT (Whisper) model from the
menu bar, mirroring the polish-model picker's semantics.

- `app/Sources/QuickScribe/ModelPicker.swift` — NEW: the t_741dd1a3 polish picker
  extracted into a shared class (list/active from sidecar, checkmark on the
  sidecar-reported ACTIVE, UserDefaults persistence, one-shot re-apply, silent
  apply on launch, honest failure notice). AppDelegate now wires TWO pickers:
  "Polish Model" + "Transcription Model" (key `QuickScribeSttModel`, switch
  timeout 300 s — first switch may download).
- `SidecarClient` — `listModels(path:timeout:)` / `switchModel(_:path:timeout:)`
  generalized (defaults preserve old behavior).
- `sidecar/stt.py` — `STTEngine.models()` (config candidates + active +
  local HF-cache whisper repos, deduped, NO network listing) and
  `set_model()` (warm-load — snapshot resolve + silent decode, mirroring
  `load()` — BEFORE committing; failure keeps the previous model, returns
  False; in-flight transcribes keep their model reference).
- `sidecar/server.py` — `GET/POST /stt/models`, load off the event loop via
  `asyncio.to_thread`; engine now takes `candidates` from `[stt] models`.
- `sidecar/config.toml` — additive `models = [...]` under `[stt]` (owner's
  `model_id` untouched); README updated (also the §4 label drift).

Runbook contract addition — APPLIED 2026-11-01 (t_a0fb24bb doc pass):

```
GET  /stt/models      -> {"models":["repo-id",...], "current":"active-repo-id"}
POST /stt/models      # json: {"model":"repo-id"}; warm-load BEFORE commit
                      -> {"ok":bool, "model":"active-repo-id"}
                      # ok=false → previous model still active, nothing changed
```

Verified: `swift build` clean; venv unit check of `models()`/`set_model` guards
(cache scan found `mlx-community/whisper-large-v3-8bit` already on this host);
`server.py` parses. NOT verified: live endpoint round-trip (`curl localhost:
8790/stt/models` after a sidecar restart — the running service predates the
change) and the menu actually switching decode behavior mid-day.
Suggested commit: `feat(app,sidecar): transcription-model picker — warm-load before commit, fail keeps active (t_20261101_review)`.

**Merge gate updated:** §6.1–6.3 + §10 live checks green; §4 #1 resolved by
the owner decision recorded above.

## 11. t_a0fb24bb correction pass (2026-11-01, author qwen)

Three confirmed defects fixed + first automated tests + doc corrections:

- **AudioCapture failed-start unwind** — engine now stopped (ExceptionGuard-
  wrapped, so an ObjC exception in stop() cannot abort the unwind) BEFORE the
  bind is restored; engine instance swapped for a fresh one (t_eec52a7e lesson:
  an engine pins its device at first touch for its LIFETIME — a reused failed
  engine would stay bound to the bad device even after hot-plug); stale
  `activeDevice`/`liveTapFormat`/`converter` cleared. The `start()` retry path
  therefore re-resolves + re-binds against a clean engine.
- **Permanent health monitor** — one create-once 30 s timer over the app's
  lifetime replaces the down-only retry (§3 #6); in-flight gate prevents
  overlapping `/health` requests; `SidecarHealth.next` (new pure reducer,
  HotkeyManager-style) owns icon/tooltip transitions, recording-safe.
- **Strict polish budget** — policy extracted to pure `PolishPlanner`
  (`SessionController.runPolish` is now execution-only). Timeout ≤ remaining
  budget always; exhausted budget → insert raw immediately, NO request; at
  most one retry, only while time remains; stale callbacks no-op; exactly-once
  insert (insertOnce) untouched. The old `max(0.2, …)` floor is gone.
- **Tests** — NEW `app/Tests/QuickScribeTests` target (first in this repo;
  Package.swift touched for it): 13 planner-policy cases + 4 flow simulations
  + 7 health-transition cases, all stub-isolated. `swift test` is now the
  automated suite. Audio-device and async-glue paths stay manual (documented
  deviation: not stubbable without an engine-protocol redesign, out of scope).
- **Docs** — runbook `/polish` degraded semantics, `/stt/models` contract,
  `ms_stt` break note APPLIED (§7/§10 markers); §2 trigger downgraded to
  hypothesis; §4 #1 owner ruling recorded.
