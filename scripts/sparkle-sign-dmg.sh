#!/usr/bin/env bash
# Sign a DMG with the ed25519 private key stored in Keychain.
# Outputs `sparkle:edSignature` and `length` for the appcast.xml enclosure tag.
#
# Usage:
#   ./scripts/sparkle-sign-dmg.sh path/to/VoiceInk-X.Y.ZZZ.dmg
#
# Output is in two lines, suitable for piping or grep:
#   length="11534336"
#   sparkle:edSignature="<base64 sig>"
#
# Used by scripts/release.sh to embed signature into appcast.xml.

set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <path-to-dmg>" >&2
    exit 1
fi

DMG="$1"
if [ ! -f "$DMG" ]; then
    echo "ERROR: file not found: $DMG" >&2
    exit 1
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/.." && pwd )"
BIN="${REPO_ROOT}/.build/artifacts/sparkle/Sparkle/bin/sign_update"

if [ ! -x "$BIN" ]; then
    echo "ERROR: sign_update not found at $BIN" >&2
    echo "Run 'swift package resolve' first." >&2
    exit 1
fi

ACCOUNT="Sparkle-VoiceInk-EdDSA"

# sign_update prints: sparkle:edSignature="..." length="..."
"$BIN" --account "$ACCOUNT" "$DMG"
