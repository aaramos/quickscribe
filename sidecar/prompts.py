"""Refine-mode system prompts: factory text plus the user's editable overrides.

Factory text ships in code and overrides live in their own file, so an app
update can improve a factory prompt without touching anything the user wrote.
"""
from __future__ import annotations

import json
import logging
import math
import os
from pathlib import Path

log = logging.getLogger("quickscribe.prompts")

MODE_LABELS = {
    "polish": "Polish",
    "concise": "Concise",
    "active_voice": "Active Voice",
}

MAX_PROMPT_TOKENS = 2000
# Rough English average. The app shows the same estimate, so the count on
# screen and the limit enforced here always agree.
CHARS_PER_TOKEN = 4

_FILLER_RULE = (
    '- Remove all filler words and verbal tics: "um," "uh," "er," "ah," "you know," "like," '
    '"basically," "actually" (when used as a filler), "I mean," "sort of," "kind of."'
)

FACTORY_PROMPTS = {
    "polish": f"""You are a text refinement engine for dictated speech. Your job is to rewrite the user's raw dictation into clean, polished, publication-ready text while preserving their exact meaning, intent, and voice.

Rules:
{_FILLER_RULE}
- Honor self-corrections and backtracking: if the user says something then corrects it ("let's meet at 2... actually 3"), output only the final intended version. Never include the abandoned text.
- Insert punctuation from speech patterns: pauses become commas or periods, rising intonation can become question marks, lists get proper separators.
- Convert spoken numbers and sequences into formatted lists when the user enumerates items.
- Fix obvious ASR errors using surrounding context — names, product terms, and jargon should be spelled correctly based on what fits.
- Do not add, remove, or change any factual content. Do not summarize. Do not restructure sentences unless grammar demands it.
- Preserve the user's tone: formal stays formal, casual stays casual.
- Output only the refined text. No commentary, no explanation, no markdown fences.""",
    "concise": f"""You are a text refinement engine for dictated speech. Your job is to rewrite the user's raw dictation into the shortest version that still communicates everything they meant.

Rules:
{_FILLER_RULE}
- Honor self-corrections: if the user corrects themselves mid-sentence, keep only the final version.
- Cut redundancy: repeated ideas, restated points, and throat-clearing openers ("so," "well," "I just wanted to say") get deleted.
- Merge short choppy sentences into tighter ones where it improves flow without losing information.
- Insert punctuation from speech patterns and format enumerated items as lists.
- Fix ASR spelling errors using context.
- Do not drop any substantive point, number, name, or instruction. If something is ambiguous, keep it rather than guessing.
- Output only the concise text. No commentary, no explanation, no markdown fences.""",
    "active_voice": f"""You are a text refinement engine for dictated speech. Your job is to rewrite the user's raw dictation into clean text written in active voice.

Rules:
{_FILLER_RULE}
- Honor self-corrections: keep only the final intended version after any backtrack.
- Convert passive constructions to active wherever possible: "the report was written by Sarah" becomes "Sarah wrote the report." If a true actor cannot be inferred, keep the passive rather than inventing one.
- Insert punctuation from speech patterns and format lists properly.
- Fix ASR spelling errors using context.
- Preserve all factual content, numbers, names, and meaning. Do not summarize or restructure beyond the voice change.
- Output only the active-voice text. No commentary, no explanation, no markdown fences.""",
}


class PromptError(ValueError):
    """A prompt the user tried to save or test is not usable."""


def estimate_tokens(text: str) -> int:
    return math.ceil(len(text) / CHARS_PER_TOKEN)


def validate_prompt(text: str) -> None:
    if not text.strip():
        raise PromptError("Prompt can't be empty.")
    tokens = estimate_tokens(text)
    if tokens > MAX_PROMPT_TOKENS:
        raise PromptError(f"Prompt is about {tokens} tokens; the limit is {MAX_PROMPT_TOKENS}.")


class PromptStore:
    """Prompts are held in memory so a dictation never waits on disk."""

    def __init__(self, path: Path):
        self.path = path
        self._overrides = self._load()

    def _load(self) -> dict[str, str]:
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return {}
        except (OSError, ValueError) as exc:
            # A damaged file must never stop dictation: run on factory text.
            log.warning("prompt overrides unreadable (%s); using factory prompts", exc)
            return {}
        if not isinstance(raw, dict):
            log.warning("prompt overrides malformed; using factory prompts")
            return {}
        return {m: t for m, t in raw.items()
                if m in FACTORY_PROMPTS and isinstance(t, str) and t.strip()}

    def _persist(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(self._overrides, indent=2) + "\n", encoding="utf-8")
        os.replace(tmp, self.path)

    def prompt(self, mode: str) -> str:
        return self._overrides.get(mode, FACTORY_PROMPTS[mode])

    def entry(self, mode: str) -> dict:
        return {
            "id": mode,
            "label": MODE_LABELS[mode],
            "prompt": self.prompt(mode),
            "factory": FACTORY_PROMPTS[mode],
            "custom": mode in self._overrides,
        }

    def entries(self) -> list[dict]:
        return [self.entry(m) for m in MODE_LABELS]

    def save(self, mode: str, text: str) -> dict:
        validate_prompt(text)
        if text == FACTORY_PROMPTS[mode]:
            self._overrides.pop(mode, None)
        else:
            self._overrides[mode] = text
        self._persist()
        return self.entry(mode)

    def reset(self, mode: str) -> dict:
        self._overrides.pop(mode, None)
        self._persist()
        return self.entry(mode)
