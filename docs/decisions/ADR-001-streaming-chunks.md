# ADR-001: Non-overlapping streaming chunks with verbatim partial concatenation

Date: 2026-09-18 · Status: accepted · Lane: frontend (card B)

## Context
The app streams 1.5 s WAV chunks to `POST /transcribe?partial=true` while
the user speaks. Two assembly strategies were considered:

1. **Overlapping chunks** (carry 0.4 s of audio into the next chunk): softens
   word cuts at chunk boundaries, but partial results then contain duplicated
   words that must be fuzzy-deduplicated client-side — lossy, unpredictable,
   and it corrupts the raw transcript that goes into history.
2. **Non-overlapping chunks** (chosen): each chunk covers a distinct time
   range; partial texts concatenate verbatim (`join()` in SessionController).

## Decision
Non-overlapping chunks at `AppInfo.chunkSeconds = 1.5`. Whisper transcribes
each chunk with its own context; a word split across a boundary is rare in
practice for dictation and degrades gracefully (both neighbors are still
transcribed). Tolerances: sidecar benchmark shows tail STT P50 ≈ 1.2 s,
inside the ≤10 s bucket budget (TTI P50 1.5 s) with the tail-only assumption.

## Consequences
- Raw transcript is exactly the concatenation of partials — auditable, no
  client-side heuristics.
- If a chunk fails mid-stream we do NOT re-transcribe the whole audio
  (would blow the TTI budget); we proceed with what we have and log it
  (`chunkFails`), or insert nothing if empty (brief §7).
