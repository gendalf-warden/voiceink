#!/usr/bin/env bash
# Generate ed25519 signing keys for Sparkle auto-update.
#
# This is a ONE-TIME operation per developer machine. The private key is stored
# in the macOS Keychain (Sparkle-VoiceInk-EdDSA account) and never leaves it
# unless explicitly exported with `generate_keys -x`. The public key is printed
# to stdout and must be embedded in the app's Info.plist as `SUPublicEDKey`.
#
# Sparkle binaries come bundled with the SPM dependency at:
#   .build/artifacts/sparkle/Sparkle/bin/
#
# Usage:
#   ./scripts/sparkle-generate-keys.sh         # generate or print existing key
#   ./scripts/sparkle-generate-keys.sh export  # export private key to file (DANGEROUS — for backup only)
#   ./scripts/sparkle-generate-keys.sh import <path>  # import private key from file
#
# After generation, copy the SUPublicEDKey value into build-app.sh
# (variable SU_PUBLIC_ED_KEY) and into the Info.plist heredoc.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/.." && pwd )"
BIN="${REPO_ROOT}/.build/artifacts/sparkle/Sparkle/bin/generate_keys"

if [ ! -x "$BIN" ]; then
    echo "ERROR: generate_keys not found at $BIN" >&2
    echo "Run 'swift package resolve' first to fetch the Sparkle SPM artefact." >&2
    exit 1
fi

ACCOUNT="Sparkle-VoiceInk-EdDSA"

case "${1:-generate}" in
    generate)
        # If a key already exists for this account, print the public part; otherwise generate.
        if "$BIN" --account "$ACCOUNT" -p 2>/dev/null; then
            echo ""
            echo "(Existing key found in Keychain under account '$ACCOUNT'.)"
        else
            "$BIN" --account "$ACCOUNT"
        fi
        ;;
    export)
        DEST="${HOME}/voiceink-sparkle-private-key.txt"
        "$BIN" --account "$ACCOUNT" -x "$DEST"
        echo ""
        echo "Private key exported to: $DEST"
        echo "BACK THIS UP IMMEDIATELY then delete the file. Loss of this key"
        echo "means all future users cannot be updated by you — they would have"
        echo "to manually install a new Sparkle-enabled version with a different key."
        ;;
    import)
        if [ -z "${2:-}" ]; then
            echo "Usage: $0 import <path-to-private-key-file>" >&2
            exit 1
        fi
        "$BIN" --account "$ACCOUNT" -f "$2"
        echo "Private key imported into Keychain (account '$ACCOUNT')."
        ;;
    *)
        echo "Usage: $0 [generate|export|import <path>]" >&2
        exit 1
        ;;
esac
