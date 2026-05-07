#!/bin/bash
# Upload ML model files to GitHub Releases for first-launch download.
#
# Usage: ./scripts/upload-models.sh
#
# This creates a GitHub release tagged "models-v1" and uploads:
#   1. ggml-large-v3-turbo-q5_0.bin      (Whisper ASR model)
#   2. ggml-large-v3-turbo-encoder.mlmodelc.zip  (CoreML encoder, zipped)
#   3. qwen2.5-3b.gguf                   (LLM for punctuation)
#
# After upload, prints SHA256 values to paste into ModelManager.swift.
#
# Prerequisites:
#   - gh CLI authenticated (gh auth login)
#   - Model files accessible at source paths below

set -euo pipefail

TAG="models-v1"

# Source paths for models
WHISPER_BIN="${HOME}/Library/Mobile Documents/com~apple~CloudDocs/Claude/Whispier cli/models/ggml-large-v3-turbo-q5_0.bin"
COREML_DIR="${HOME}/Library/Mobile Documents/com~apple~CloudDocs/Claude/Whispier cli/models/ggml-large-v3-turbo-encoder.mlmodelc"
QWEN_BLOB="${HOME}/.ollama/models/blobs/sha256-5ee4f07cdb9beadbbb293e85803c569b01bd37ed059d2715faa7bb405f31caa6"

TMP="/tmp/voiceink-model-upload"
rm -rf "$TMP"
mkdir -p "$TMP"

echo "=== Preparing model files ==="

# 1. Whisper binary model
echo "[1/3] Whisper model..."
if [ ! -f "$WHISPER_BIN" ]; then
    echo "ERROR: Whisper model not found at: $WHISPER_BIN"
    exit 1
fi
WHISPER_FILE="$TMP/ggml-large-v3-turbo-q5_0.bin"
cp "$WHISPER_BIN" "$WHISPER_FILE"
WHISPER_SIZE=$(stat -f %z "$WHISPER_FILE")
WHISPER_SHA=$(shasum -a 256 "$WHISPER_FILE" | awk '{print $1}')
echo "       Size: $WHISPER_SIZE bytes"
echo "       SHA256: $WHISPER_SHA"

# 2. CoreML encoder (zip the directory)
echo "[2/3] CoreML encoder (zipping directory)..."
if [ ! -d "$COREML_DIR" ]; then
    echo "ERROR: CoreML model not found at: $COREML_DIR"
    exit 1
fi
COREML_ZIP="$TMP/ggml-large-v3-turbo-encoder.mlmodelc.zip"
(cd "$(dirname "$COREML_DIR")" && zip -r -q "$COREML_ZIP" "$(basename "$COREML_DIR")")
COREML_SIZE=$(stat -f %z "$COREML_ZIP")
COREML_SHA=$(shasum -a 256 "$COREML_ZIP" | awk '{print $1}')
echo "       Size: $COREML_SIZE bytes"
echo "       SHA256: $COREML_SHA"

# 3. Qwen GGUF model
echo "[3/3] Qwen 2.5 3B model..."
if [ ! -f "$QWEN_BLOB" ]; then
    echo "ERROR: Qwen model blob not found. Install with: ollama pull qwen2.5:3b"
    exit 1
fi
QWEN_FILE="$TMP/qwen2.5-3b.gguf"
cp "$QWEN_BLOB" "$QWEN_FILE"
QWEN_SIZE=$(stat -f %z "$QWEN_FILE")
QWEN_SHA=$(shasum -a 256 "$QWEN_FILE" | awk '{print $1}')
echo "       Size: $QWEN_SIZE bytes"
echo "       SHA256: $QWEN_SHA"

echo ""
echo "=== Uploading to GitHub Release $TAG ==="

# Create release if it doesn't exist
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release $TAG already exists — uploading assets (clobber mode)"
else
    echo "Creating release $TAG..."
    gh release create "$TAG" \
        --title "Model Assets v1" \
        --notes "ML model files for VoiceInk first-launch download. These are NOT application releases — they are model assets referenced by the app." \
        --prerelease
fi

echo "Uploading ggml-large-v3-turbo-q5_0.bin ($(du -sh "$WHISPER_FILE" | cut -f1))..."
gh release upload "$TAG" "$WHISPER_FILE" --clobber

echo "Uploading ggml-large-v3-turbo-encoder.mlmodelc.zip ($(du -sh "$COREML_ZIP" | cut -f1))..."
gh release upload "$TAG" "$COREML_ZIP" --clobber

echo "Uploading qwen2.5-3b.gguf ($(du -sh "$QWEN_FILE" | cut -f1))..."
gh release upload "$TAG" "$QWEN_FILE" --clobber

echo ""
echo "=== Done! ==="
echo ""
echo "Paste these values into ModelManager.swift assets:"
echo ""
echo "    // whisper-bin"
echo "    expectedSize: ${WHISPER_SIZE},"
echo "    sha256: \"${WHISPER_SHA}\","
echo ""
echo "    // whisper-coreml"
echo "    expectedSize: ${COREML_SIZE},"
echo "    sha256: \"${COREML_SHA}\","
echo ""
echo "    // qwen-gguf"
echo "    expectedSize: ${QWEN_SIZE},"
echo "    sha256: \"${QWEN_SHA}\","
echo ""

# Cleanup
rm -rf "$TMP"
