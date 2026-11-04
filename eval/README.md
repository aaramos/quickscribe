# Comparison test

Scores Apple's speech and cleanup against the original QuickScribe on the scripted
dictations in `corpus.py`. Nothing here reads real dictation history.

Why these cases: a self-correction left in means a wrong number that looks right, so
those are counted apart. Dictated questions and commands check that the model cleans them
up rather than answering them. Sensitive topics check Apple's safety filters.

The voice is Apple's Samantha, so this doesn't measure real voices, accents, rooms or
microphones. Word accuracy on a real voice still needs checking by hand.

The original QuickScribe's helper must be running on 127.0.0.1:8790 for `today.py`.

```bash
python3 -c "import json,runpy; json.dump(runpy.run_path('eval/corpus.py')['C'], open('/tmp/qs/corpus.json','w'))"
```

Then use `generate_audio.sh` for the audio, `apple-eval speech|clean|limits|live` and
`today.py` for the runs (saved as `speech_*.jsonl` and `clean_*.jsonl`), and `score.py` for
the table. `pipeline_corpus.py` feeds each engine's transcript to its own cleanup, which
gives the end-to-end score.
