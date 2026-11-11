#!/bin/zsh
# Creates tts-server/.venv and downloads the Pocket TTS voice (~100 MB) and the
# Parakeet speech-to-text model (~600 MB) so Clicky can run them offline.
# Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"
PYTHON_FOR_VENV="${PYTHON_FOR_VENV:-/opt/homebrew/bin/python3.12}"
[ -x .venv/bin/python ] || "$PYTHON_FOR_VENV" -m venv .venv
.venv/bin/pip install --quiet --upgrade pip
.venv/bin/pip install --quiet -r requirements.txt
.venv/bin/python -I -c "from huggingface_hub import snapshot_download; snapshot_download('mlx-community/pocket-tts'); snapshot_download('mlx-community/parakeet-tdt-0.6b-v2')"
echo "Voice server ready. Restart Clicky to use it."
