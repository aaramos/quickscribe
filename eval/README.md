# Comparison test

Scores Apple's speech and cleanup, and optionally a person's own service,
against the scripted dictations in `corpus.py`. Nothing here reads real
dictation history.

Why these cases: a self-correction left in means a wrong number that looks
right, so those are counted apart. Dictated questions and commands check that
the model cleans them up rather than answering them. Sensitive topics check
Apple's safety filters.

The voice is Apple's Samantha, so this doesn't measure real voices, accents,
rooms or microphones. Word accuracy on a real voice still needs checking by
hand.

Everything runs through the package's own tools. Build first:

```bash
cd app && swift build
```

Make a working folder and write the corpus into it:

```bash
mkdir -p /tmp/qs
python3 -c "import json,runpy; json.dump(runpy.run_path('eval/corpus.py')['C'], open('/tmp/qs/corpus.json','w'))"
```

Then `generate_audio.sh <corpus.json> <dir>` speaks each dictation into WAV
files, and two executables run the measurements. `cleanup-eval` takes
`speech <corpus.json> <audio-dir>`, `clean <corpus.json> <variant>` (variants
`rules`, `polish`, `concise`, `active_voice`, `rewrite`, and the `service_*`
forms, whose server the environment names: `QSE_BASE`, `QSE_MODEL`, and
`QSE_KEY` or `QSE_KEYFILE`), `limits`, and `live <file.wav>`; it prints one
JSON line per item, conventionally saved as `speech_*.jsonl` and
`clean_*.jsonl`. `time-eval <time-corpus.json> <repeats>` runs the
invented-time before/after experiment on its own two-sentence corpus.
`score.py <folder>` turns the line files in a folder into the table;
`pipeline_corpus.py <corpus.json> <speech.jsonl> <out.json>` rewrites the
corpus so each raw text is what an engine actually heard, which lets cleanup
be scored on what it would really receive, end to end.
