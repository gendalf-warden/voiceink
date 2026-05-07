#!/bin/bash
# Publish a notarized DMG to GitHub Releases and update latest.json manifest.
#
# Usage:
#   ./scripts/release.sh                    # uses VERSION file
#   ./scripts/release.sh --draft            # creates as draft (no public release yet)
#   ./scripts/release.sh --notes-file FILE  # use custom release notes file
#
# Prerequisites:
#   - VoiceInk-{VERSION}.dmg exists in project root (run ./build-app.sh release first)
#   - gh CLI authenticated (gh auth login)
#   - Notarized DMG (handled by build-app.sh release)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

VERSION=$(cat VERSION | tr -d '[:space:]')
DMG="VoiceInk-${VERSION}.dmg"
TAG="v${VERSION}"

DRAFT_FLAG=""
NOTES_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --draft) DRAFT_FLAG="--draft"; shift;;
        --notes-file) NOTES_FILE="$2"; shift 2;;
        *) echo "Unknown arg: $1"; exit 1;;
    esac
done

if [ ! -f "$DMG" ]; then
    echo "ERROR: $DMG not found. Run ./build-app.sh release first."
    exit 1
fi

# Verify notarization on the DMG
echo "[1/5] Verifying notarization..."
if ! spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | grep -q "accepted"; then
    echo "WARNING: DMG may not be notarized correctly. Continuing anyway..."
fi

# Compute SHA256
echo "[2/5] Computing SHA256..."
SHA256=$(shasum -a 256 "$DMG" | awk '{print $1}')
SIZE=$(du -m "$DMG" | awk '{print $1}')
SIZE_BYTES=$(stat -f %z "$DMG" 2>/dev/null || stat -c %s "$DMG")
echo "       SHA256: $SHA256"
echo "       Size:   ${SIZE} MB"

# Read changelog section for this version
echo "[3/5] Extracting release notes for $TAG..."
NOTES_TMP="/tmp/voiceink-release-notes.md"
if [ -n "$NOTES_FILE" ]; then
    cp "$NOTES_FILE" "$NOTES_TMP"
elif [ -f CHANGELOG.md ]; then
    awk -v v="\\[${VERSION}\\]" '
        $0 ~ "^## " v { found=1; next }
        found && /^## / { exit }
        found { print }
    ' CHANGELOG.md > "$NOTES_TMP"
    if [ ! -s "$NOTES_TMP" ]; then
        echo "WARNING: no entry for [$VERSION] in CHANGELOG.md"
        echo "Release $TAG" > "$NOTES_TMP"
    fi
fi

# Append SHA256 to release notes
cat >> "$NOTES_TMP" <<EOF

---

**SHA256:** \`$SHA256\`
**Size:** ${SIZE} MB
EOF

# Create or update GitHub release
echo "[4/5] Creating GitHub release $TAG..."
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "       Release $TAG already exists — uploading DMG to existing release"
    gh release upload "$TAG" "$DMG" --clobber
else
    gh release create "$TAG" \
        --title "VoiceInk $VERSION" \
        --notes-file "$NOTES_TMP" \
        $DRAFT_FLAG \
        "$DMG"
fi

# Generate latest.json manifest (auto-updater target)
echo "[5/5] Updating latest.json..."
RELEASE_URL=$(gh release view "$TAG" --json url -q .url)
DOWNLOAD_URL="https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/download/${TAG}/${DMG}"

cat > latest.json <<EOF
{
    "version": "$VERSION",
    "tag": "$TAG",
    "released": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "min_macos": "13.0",
    "dmg": {
        "url": "$DOWNLOAD_URL",
        "size": $SIZE_BYTES,
        "sha256": "$SHA256"
    },
    "release_notes_url": "$RELEASE_URL"
}
EOF

# Upload latest.json to the release as well (so /releases/latest/download/latest.json works)
gh release upload "$TAG" latest.json --clobber

echo ""
echo "=== Done ==="
echo "  Release: $RELEASE_URL"
echo "  DMG URL: $DOWNLOAD_URL"
echo "  latest.json: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/latest/download/latest.json"
