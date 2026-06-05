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
    # Double-escape brackets: shell turns \\\\[ into \\[, awk's -v then parses \\[ as \[
    # in the stored string, which the regex engine treats as a literal [.
    # The simpler \\[ in shell becomes \[ raw → awk's -v strips the backslash →
    # final regex is a character class [0.5.002], which matches the wrong thing.
    awk -v v="\\\\[${VERSION}\\\\]" '
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

# GH Pages is the single source of truth from 0.5.008 onwards. We no longer
# dual-publish to GitHub Releases (the bridging mirror is gone — all known
# users migrated to ≥0.5.006 which has the new SUFeedURL baked in).
#
# Note: the `models-v1` release on GitHub is preserved — ModelManager.swift
# downloads bundled whisper/qwen models from that specific tag at first launch.

echo "[4/6] Generating latest.json + appcast.xml..."
PAGES_BASE="https://gendalf-warden.github.io/voiceink"
DOWNLOAD_URL="${PAGES_BASE}/${DMG}"
RELEASE_NOTES_URL="${PAGES_BASE}/changelog.html"  # TODO: render CHANGELOG to HTML on pages

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
    "release_notes_url": "$RELEASE_NOTES_URL"
}
EOF

# Generate appcast.xml for Sparkle auto-updater.
echo "[4/6]   generating appcast.xml..."
SIGN_SCRIPT="${SCRIPT_DIR}/scripts/sparkle-sign-dmg.sh"
if [ ! -x "$SIGN_SCRIPT" ]; then
    echo "ERROR: $SIGN_SCRIPT not found or not executable"
    exit 1
fi
# sign_update output format: sparkle:edSignature="..." length="..."
SIGN_OUTPUT=$("$SIGN_SCRIPT" "$DMG")
ED_SIG=$(echo "$SIGN_OUTPUT" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p')
SIGN_LENGTH=$(echo "$SIGN_OUTPUT" | sed -nE 's/.*length="([^"]+)".*/\1/p')
if [ -z "$ED_SIG" ] || [ -z "$SIGN_LENGTH" ]; then
    echo "ERROR: failed to parse sign_update output: $SIGN_OUTPUT"
    exit 1
fi

# RFC-822 date for Sparkle's pubDate (e.g., "Thu, 22 May 2026 23:00:00 +0000")
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

# Extract release notes for inline embedding (markdown → CDATA). Strip the
# "---\nSHA256/Size" footer we appended earlier, Sparkle's dialog renders
# the markdown but the SHA footer is redundant there.
NOTES_HTML=$(awk '/^---$/{exit} {print}' "$NOTES_TMP")

# DELIBERATELY no <sparkle:releaseNotesLink>: that would tell Sparkle to load
# a URL in an embedded WebView, which embeds the full GitHub release page
# complete with GitHub's nav bar ("Sign in", "Code", "Issues", repo header).
# Instead we put the release notes inline in <description> as HTML — Sparkle
# renders that with its native (chrome-free) WebView.
NOTES_BODY=$(echo "$NOTES_HTML" | python3 -c '
import sys, html
md = sys.stdin.read()
# Minimal markdown-to-HTML: convert ### headings, ** bold **, - list items,
# and `code`. Keeps the dialog readable without a full markdown lib.
import re
out = []
in_list = False
for line in md.splitlines():
    s = line.rstrip()
    if not s.strip():
        if in_list: out.append("</ul>"); in_list = False
        out.append("")
        continue
    m = re.match(r"^(#{1,4})\s+(.*)$", s)
    if m:
        if in_list: out.append("</ul>"); in_list = False
        lvl = len(m.group(1))
        out.append(f"<h{lvl}>{html.escape(m.group(2))}</h{lvl}>")
        continue
    if s.lstrip().startswith("- "):
        if not in_list: out.append("<ul>"); in_list = True
        item = s.lstrip()[2:]
        item = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", html.escape(item).replace("&lt;strong&gt;", "<strong>").replace("&lt;/strong&gt;", "</strong>"))
        item = re.sub(r"`([^`]+)`", r"<code>\1</code>", item)
        out.append(f"  <li>{item}</li>")
        continue
    if in_list: out.append("</ul>"); in_list = False
    line_html = html.escape(s)
    line_html = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", line_html)
    line_html = re.sub(r"`([^`]+)`", r"<code>\1</code>", line_html)
    out.append(f"<p>{line_html}</p>")
if in_list: out.append("</ul>")
print("\n".join(out))
')

cat > appcast.xml <<EOF
<?xml version="1.0" standalone="yes"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>VoiceInk</title>
        <link>https://gendalf-warden.github.io/voiceink/</link>
        <description>VoiceInk macOS dictation app — release feed</description>
        <language>en</language>
        <item>
            <title>Version ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <description><![CDATA[${NOTES_BODY}]]></description>
            <enclosure
                url="${DOWNLOAD_URL}"
                length="${SIGN_LENGTH}"
                type="application/octet-stream"
                sparkle:edSignature="${ED_SIG}" />
        </item>
    </channel>
</rss>
EOF

echo "[5/6] Publishing to gh-pages (GH Pages)..."
PAGES_DIR="/tmp/voiceink-gh-pages"
if [ -d "$PAGES_DIR/.git" ]; then
    git -C "$PAGES_DIR" fetch --quiet origin gh-pages
    git -C "$PAGES_DIR" reset --quiet --hard origin/gh-pages
else
    git clone --quiet --branch gh-pages --single-branch \
        https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner).git "$PAGES_DIR"
fi

cp "$DMG" "$PAGES_DIR/"
cp appcast.xml "$PAGES_DIR/"
cp latest.json "$PAGES_DIR/"

# Regenerate landing page with the current download link
cat > "$PAGES_DIR/index.html" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>VoiceInk — Native macOS voice dictation</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; max-width: 620px; margin: 80px auto; padding: 20px; color: #1d1d1f; line-height: 1.5; }
  h1 { font-size: 36px; margin-bottom: 8px; }
  .tagline { color: #6e6e73; font-size: 18px; margin-bottom: 32px; }
  .cta-row { display: flex; flex-wrap: wrap; gap: 12px; align-items: center; }
  .download { display: inline-block; background: #0066cc; color: white; padding: 14px 28px; text-decoration: none; border-radius: 10px; font-size: 16px; font-weight: 500; }
  .download:hover { background: #0052a3; }
  .install-guide { display: inline-block; background: transparent; color: #0066cc; padding: 13px 22px; text-decoration: none; border-radius: 10px; font-size: 15px; font-weight: 500; border: 2px solid #0066cc; }
  .install-guide:hover { background: #e7f1fc; text-decoration: none; }
  .version-info { color: #6e6e73; font-size: 14px; margin-top: 12px; }
  h2 { margin-top: 48px; font-size: 22px; }
  ul { padding-left: 20px; }
  li { margin: 6px 0; }
</style>
</head>
<body>
<h1>VoiceInk</h1>
<p class="tagline">Native macOS menu-bar voice dictation. Local Whisper + LLM. No cloud, no subscription.</p>

<div class="cta-row">
  <a class="download" href="${DMG}">Download VoiceInk ${VERSION}</a>
  <a class="install-guide" href="install.html">Installation guide →</a>
</div>
<div class="version-info">v${VERSION} · ${SIZE} MB · macOS 13+ · Apple Silicon</div>

<h2>What it does</h2>
<ul>
  <li>Hold <strong>Fn</strong> anywhere, dictate, release — text is pasted at the cursor</li>
  <li>Whisper large-v3-turbo for transcription (runs locally on your Mac)</li>
  <li>Qwen 2.5 for punctuation &amp; light editing (also local)</li>
  <li>Transcribe audio/video files from the menu bar</li>
  <li>Custom replacements dictionary for tricky names</li>
</ul>

<h2>Auto-update</h2>
<p>After install, use the menu-bar item «Check for Updates…» to get new releases.</p>
</body>
</html>
HTML

cd "$PAGES_DIR"
git add -A
git -c user.email=ds@itquick.ai -c user.name="Dima Sushkov" commit --quiet -m "Release ${VERSION}" || \
    echo "       (no changes to commit — likely re-running release.sh)"
git push --quiet origin gh-pages
cd - >/dev/null

# Wait for GH Pages build to finish so the operator sees confirmation that
# the release is live before exit. Typically ~30-60 s.
echo "[6/6] Waiting for GH Pages build to complete..."
for i in $(seq 1 30); do
    status=$(gh api /repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/pages -q .status 2>/dev/null || echo "unknown")
    echo "       [$i/30] pages status: ${status}"
    if [ "$status" = "built" ]; then
        if curl -sfI "$DOWNLOAD_URL" >/dev/null 2>&1; then
            echo "       Pages live, DMG reachable."
            break
        fi
    fi
    sleep 5
done

echo ""
echo "=== Done ==="
echo "  Pages (canonical): ${PAGES_BASE}/"
echo "  DMG URL:           $DOWNLOAD_URL"
echo "  appcast.xml:       ${PAGES_BASE}/appcast.xml"
echo "  latest.json:       ${PAGES_BASE}/latest.json"
echo ""
echo "  Sparkle clients (≥0.5.006) will pick this up at the next 'Check for Updates…'."
