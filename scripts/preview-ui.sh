#!/bin/bash
# Fast UI iteration harness — compiles + launches a single window in ~3-5 seconds.
# No .app bundle, no whisper-server, no llama-server, no models.
#
# Usage:
#   ./scripts/preview-ui.sh                # default: replacements
#   ./scripts/preview-ui.sh replacements
#   ./scripts/preview-ui.sh settings
#
# Config is isolated to /tmp/voiceink-uipreview-config so production config in
# ~/.config/voiceink/config.json is untouched.

set -euo pipefail

WINDOW="${1:-replacements}"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PREVIEW_CONFIG_DIR="/tmp/voiceink-uipreview-config"
mkdir -p "$PREVIEW_CONFIG_DIR"

cd "$SCRIPT_DIR"
echo "[preview] Window: $WINDOW"
echo "[preview] Config: $PREVIEW_CONFIG_DIR (isolated from production)"
echo ""

VOICEINK_CONFIG_DIR="$PREVIEW_CONFIG_DIR" \
    swift run --scratch-path /tmp/voiceink-build-scratch UIPreview "$WINDOW"
