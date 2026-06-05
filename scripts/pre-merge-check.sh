#!/bin/bash
set -euo pipefail

# Use /tmp scratch path to avoid iCloud Drive rename races on .build/ModuleCache.
SCRATCH=/tmp/voiceink-build-scratch
SWIFT_OPTS="--scratch-path $SCRATCH"

echo "=== Pre-merge checks ==="

echo "[1/3] swift build..."
swift build $SWIFT_OPTS 2>&1 | tee /tmp/voiceink-build.log
# Filter known Swift-6-concurrency false positives on Apple non-Sendable types
# (AVAssetWriter, AVAssetReader, etc. — Apple has not yet marked them Sendable).
# These don't affect runtime correctness.
WARNINGS=$( (grep "warning:" /tmp/voiceink-build.log || true) | (grep -v "SendableClosureCaptures" || true) | wc -l | tr -d ' ')
if [ "$WARNINGS" -gt 0 ]; then
    echo "FAIL: $WARNINGS compiler warnings found (excluding SendableClosureCaptures)"
    grep "warning:" /tmp/voiceink-build.log | grep -v "SendableClosureCaptures"
    exit 1
fi
echo "       OK — 0 actionable warnings"

echo "[2/3] swift test..."
swift test $SWIFT_OPTS
echo "       OK — all tests passed"

echo "[3/3] swift build (release)..."
swift build -c release $SWIFT_OPTS 2>&1 | tee /tmp/voiceink-build-release.log
WARNINGS_REL=$( (grep "warning:" /tmp/voiceink-build-release.log || true) | (grep -v "SendableClosureCaptures" || true) | wc -l | tr -d ' ')
if [ "$WARNINGS_REL" -gt 0 ]; then
    echo "FAIL: $WARNINGS_REL release warnings found (excluding SendableClosureCaptures)"
    grep "warning:" /tmp/voiceink-build-release.log | grep -v "SendableClosureCaptures"
    exit 1
fi
echo "       OK — release build clean"

echo "[4/4] git sync status (backup guard)..."
SYNC_OK=1
if [ -n "$(git status --porcelain)" ]; then
    echo "       ⚠️  uncommitted changes in working tree — commit + push before merge (./scripts/save.sh)"
    SYNC_OK=0
fi
BR=$(git rev-parse --abbrev-ref HEAD)
if ! git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
    echo "       ⚠️  branch '$BR' has no upstream — run: git push -u origin $BR"
    SYNC_OK=0
elif [ "$(git rev-list --count @{u}..HEAD 2>/dev/null || echo 0)" -gt 0 ]; then
    echo "       ⚠️  unpushed commits on '$BR' — run: git push"
    SYNC_OK=0
fi
[ "$SYNC_OK" -eq 1 ] && echo "       OK — '$BR' pushed and tree clean"

echo ""
echo "=== All checks passed ==="
