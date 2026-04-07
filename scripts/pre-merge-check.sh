#!/bin/bash
set -euo pipefail

echo "=== Pre-merge checks ==="

echo "[1/3] swift build..."
swift build 2>&1 | tee /tmp/voiceink-build.log
WARNINGS=$(grep -c "warning:" /tmp/voiceink-build.log || true)
if [ "$WARNINGS" -gt 0 ]; then
    echo "FAIL: $WARNINGS compiler warnings found"
    grep "warning:" /tmp/voiceink-build.log
    exit 1
fi
echo "       OK — 0 warnings"

echo "[2/3] swift test..."
swift test
echo "       OK — all tests passed"

echo "[3/3] swift build (release)..."
swift build -c release 2>&1 | tee /tmp/voiceink-build-release.log
WARNINGS_REL=$(grep -c "warning:" /tmp/voiceink-build-release.log || true)
if [ "$WARNINGS_REL" -gt 0 ]; then
    echo "FAIL: $WARNINGS_REL release warnings found"
    grep "warning:" /tmp/voiceink-build-release.log
    exit 1
fi
echo "       OK — release build clean"

echo ""
echo "=== All checks passed ==="
