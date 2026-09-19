#!/bin/bash
# Install sidecar deps into venv (runs once, not from LaunchAgent).
set -euo pipefail
cd "$(dirname "$0")"
python3.11 -m venv .venv 2>/dev/null || true
.venv/bin/pip install --quiet --upgrade pip
.venv/bin/pip install --quiet -r requirements.txt
.venv/bin/python -c "import mlx_whisper, fastapi, uvicorn, httpx, soundfile; print('deps ok')"