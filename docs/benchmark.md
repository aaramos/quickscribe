# QuickScribe sidecar benchmark — measured TTI

Runs per cell: 7. TTI is MEASURED end-to-end per run (tail-2s /transcribe → /polish → simulated insert +50ms) against the live sidecar on :8790 — not hand-summed from component timings.

## TTI (hotkey-release → text present)

| Utterance | TTI P50 (ms) | TTI P95 (ms) | tail STT P50 (ms) | polish P50 (ms) | Budget |
|---|---|---|---|---|---|
| 10s | 517 | 549 | 208 | 259 | ≤1.5s / ≤3s — **PASS** |
| 30s | 564 | 648 | 214 | 300 | ≤2.5s / ≤5s — **PASS** |
| 60s | 520 | 535 | 204 | 262 | ≤5s / ≤10s — **PASS** |

~50-word polish P50 513 ms / P95 553 ms (budget ≤ ~1 s).
Simulated insert overhead: 50 ms (paste technique; measured in frontend lane).
Idle warm-up: oMLX keepalive ping every 60s keeps the model resident; first /polish after ≥10min idle returns degraded=false.

## Raw runs

```json
{
  "tti": {
    "10": {
      "tti_ms": [
        519.9780000373721,
        517.0166249852628,
        526.2176669901237,
        513.3737499825656,
        548.6452079610899,
        496.18437497410923,
        513.3758330019191
      ],
      "stt_ms": [
        222.7418749826029,
        207.59229199029505,
        208.06058403104544,
        209.18795792385936,
        207.4203749652952,
        203.1399579718709,
        204.72395897377282
      ],
      "polish_ms": [
        247.2074159886688,
        259.385957964696,
        268.05966591928154,
        254.0562499780208,
        291.18541709613055,
        243.0059580365196,
        258.6187500273809
      ]
    },
    "30": {
      "tti_ms": [
        563.6572909541428,
        543.9032919937745,
        565.30637498945,
        557.9030829947442,
        573.7291250377893,
        648.3624170767143,
        549.3759160861373
      ],
      "stt_ms": [
        213.7452909955755,
        217.67099993303418,
        204.60541592910886,
        208.5954579524696,
        210.67250007763505,
        240.04616704769433,
        218.29245903063565
      ],
      "polish_ms": [
        299.8728340025991,
        276.2197919655591,
        310.6862079584971,
        299.28270902018994,
        313.03375004790723,
        358.29095798544586,
        281.0459169559181
      ]
    },
    "60": {
      "tti_ms": [
        535.290625016205,
        515.1097499299794,
        497.1085830591619,
        522.2126669948921,
        519.5445830002427,
        520.5862080445513,
        475.50379200838506
      ],
      "stt_ms": [
        204.12729203235358,
        202.7534160297364,
        203.14812508877367,
        206.83870906941593,
        204.8134159995243,
        209.59933404810727,
        201.74987497739494
      ],
      "polish_ms": [
        281.1395829776302,
        262.32533308211714,
        243.9347499748692,
        265.3407920151949,
        264.7050829837099,
        260.96129207871854,
        223.71958300936967
      ]
    }
  },
  "polish_50word_ms": [
    512.8191659459844,
    549.1459579207003,
    553.3938329899684,
    481.34687496349216,
    527.993957977742,
    497.01500008814037,
    492.76370799634606
  ]
}
```

## App-side TTI (t_c94efeef, headless pre-demo)

True hotkey-release→visible-insert TTI requires the owner live demo (TCC Allow pending) — NOT yet measured. The numbers below are headless proxies measured 2026-09-18 against the live sidecar from the running app's exact endpoints, so the live number is bounded by: client audio chunking + these + AX paste.

| Segment | Method | Result |
|---|---|---|
| tail /transcribe (final) | synthetic `say` wav, partial=false | 280 ms, lang=en |
| /polish profile=polish | same utterance | 503 ms, degraded=false |
| /polish profile=rewrite | same utterance | 404 ms, degraded=false |
| sidecar degrade | `launchctl stop com.quickscribe.sidecar` | /health connection-refused (curl 7); app pid 41694 alive, STAT S, zero crash reports in DiagnosticReports; `launchctl start` → healthy in ~6 s |
| AVAudioEngine capture | inputNode tap, same class as app | tap streaming ok (48 kHz stereo in → app resamples to 16k mono) |
| Accessibility | AXIsProcessTrusted | true (already granted system-wide) |
| Clipboard-restore mechanism | compiled Insertion.swift (paste-CmdV stubbed, no keystrokes synthesized) | snapshot→write→restore proven: pre-set string restored byte-exact, marker guard ok |
| History wiring | GET /history + copyClicked code review | endpoint serves rows; click handler writes .polished to pasteboard (AC7) |

Live demo remaining once owner is at the Studio (on the re-cut demo card, new bindings): overlay pill partials, 4-app insert (Notes/TextEdit/Chrome/Terminal), tap-mode, Esc-cancel-clipboard-restore, history click-to-copy, Rewrite profile switch — then real hotkey→insert TTI replaces this proxy table. Old ⌘⌥Space demo scope retired per PM (binding collision).

## Live full-session TTI (t_955de3e6, REAL app stack + REAL mic path)

Measured 2026-09-19 by `app/e2e-proof/main.swift`: compiles the actual SessionController/AudioCapture/HotkeyManager/Insertion/SidecarClient, posts real CGEvent ⌃⌘ hold/release into the system (real event tap), speaks TTS into BlackHole (default in+out routed), live Whisper STT + Qwen polish against the live sidecar. TTI = last phase-change (hotkey release) → history row lands. Insert leg (⌘V into a GUI target) still gated on owner unlock — numbers below are release→history, which bounds TTI from above by the paste dispatch only.

| Scenario | Session | TTI (release→history) | Result |
|---|---|---|---|
| polish profile, push-to-talk | S1 | 1.61 s | history ✓, clipboard restore ✓ |
| rewrite profile (⌃⌘⇧) | S2 | 1.52 s | history ✓, profile=rewrite in row ✓ |
| sidecar −9 mid-capture | S4 | n/a | no insert, no crash (expect ✓) |
| recovery after relaunch | S5 | 1.53 s | history ✓ within ~1.5 s of healthy |

Cross-checks: direct-asset /transcribe 250 ms; loopback-captured playback → identical transcription; degrade warning "polish degraded (LLM unavailable)" surfaced while oMLX backend was down (restarted via `open -a oMLX.app`). Defect found+fixed during this run: silent-tail chunk (empty 200 success) was mis-accounted as a chunk failure in `sendChunk` — now only failed requests count (SessionController.swift).
