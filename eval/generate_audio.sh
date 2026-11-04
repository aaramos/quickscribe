#!/usr/bin/env bash
# Speaks each scripted dictation with Apple's Samantha voice.
# Usage: generate_audio.sh <corpus.json> <out-dir>
set -euo pipefail
python3 - "$1" "$2" <<'PY'
import json, subprocess, sys
for item in json.load(open(sys.argv[1])):
    subprocess.run(["say", "-v", "Samantha", "--data-format=LEI16@16000", "--file-format=WAVE",
                    "-o", f"{sys.argv[2]}/{item['id']}.wav", item["raw"]], check=True)
PY
