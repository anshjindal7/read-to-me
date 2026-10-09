#!/bin/bash
# One-time setup for the Qwen features: a Python environment with MLX, plus the two models.
# Safe to run again — it skips anything already done. Needs an Apple Silicon Mac and Python 3.10+.
#
#   Qwen3-VL-8B (4-bit)            ~5 GB   reads page photos
#   Qwen3-TTS-1.7B CustomVoice     ~3 GB   narrates
set -euo pipefail

DIR="$HOME/Library/Application Support/ReadToMe"
HERE="$(cd "$(dirname "$0")" && pwd)"
# The helper sits next to this script in the app bundle, or in ../Resources in the repo.
HELPER="$HERE/readtome_ai.py"
[ -f "$HELPER" ] || HELPER="$HERE/../Resources/readtome_ai.py"

# Apps launched from Finder get a minimal PATH, so look in the usual Python install spots too.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Library/Frameworks/Python.framework/Versions/Current/bin:$PATH"
PYTHON=""
for candidate in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" >/dev/null && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
        PYTHON="$(command -v "$candidate")"
        break
    fi
done
if [ -z "$PYTHON" ]; then
    echo "ERROR: Python 3.10 or newer is needed. Install it from https://www.python.org/downloads/"
    exit 1
fi

echo "STEP Setting up Python ($("$PYTHON" --version))"
mkdir -p "$DIR"
cp "$HELPER" "$DIR/readtome_ai.py"
[ -x "$DIR/venv/bin/python" ] || "$PYTHON" -m venv "$DIR/venv"

echo "STEP Installing MLX libraries"
"$DIR/venv/bin/pip" install --quiet --upgrade pip
"$DIR/venv/bin/pip" install --quiet mlx-vlm mlx-audio soundfile

download() {
    echo "STEP Downloading $1"
    for attempt in 1 2 3 4 5; do
        if HF_HUB_DISABLE_XET=1 "$DIR/venv/bin/python" -c \
            "from huggingface_hub import snapshot_download; snapshot_download('$1')" >/dev/null 2>&1; then
            return 0
        fi
        echo "Download interrupted, retrying ($attempt/5)..."
        sleep 5
    done
    echo "ERROR: Couldn't download $1. Check your internet connection and run setup again."
    exit 1
}
download "mlx-community/Qwen3-VL-8B-Instruct-4bit"
download "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"

echo "DONE"
