#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Mode: dev (default) or release
MODE="${1:-dev}"
if [ "$MODE" != "dev" ] && [ "$MODE" != "release" ]; then
    echo "Usage: $0 [dev|release]"
    echo "  dev     — build .app only (fast iteration)"
    echo "  release — build .app + versioned DMG"
    exit 1
fi

# Version from VERSION file
VERSION=$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null | tr -d '[:space:]')
if [ -z "$VERSION" ]; then
    echo "ERROR: VERSION file not found or empty"
    exit 1
fi

APP_NAME="VoiceInk"
# Build outside iCloud Drive to avoid com.apple.provenance xattrs
BUILD_DIR="/tmp/voiceink-build"
BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${BUNDLE}/Contents"
RESOURCES="${CONTENTS}/Resources"
FINAL_BUNDLE="${SCRIPT_DIR}/${APP_NAME}.app"

if [ "$MODE" = "release" ]; then
    echo "=== Building ${APP_NAME} v${VERSION} (RELEASE) ==="
else
    echo "=== Building ${APP_NAME} (dev) ==="
fi

# Paths to whisper resources
WHISPER_BUILD="${HOME}/Library/Mobile Documents/com~apple~CloudDocs/Claude/Whispier cli/whisper.cpp/build"
WHISPER_SERVER="${WHISPER_BUILD}/bin/whisper-server"
# Models are NOT bundled — downloaded on first launch via ModelManager.
# See scripts/upload-models.sh to upload models to GitHub Releases.

# Paths to LLM resources
LLAMA_SERVER="/opt/homebrew/bin/llama-server"

# Step 1: Build release binary
echo "[1/7] Building release binary..."
swift build -c release --scratch-path /tmp/voiceink-build-scratch 2>&1 | tail -1

BINARY="/tmp/voiceink-build-scratch/release/voiceink"
if [ ! -f "$BINARY" ]; then
    echo "ERROR: Binary not found at $BINARY"
    exit 1
fi

# Step 2: Create .app structure
echo "[2/7] Creating bundle structure..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
mkdir -p "${CONTENTS}/MacOS"
mkdir -p "${RESOURCES}/lib"
mkdir -p "${RESOURCES}/lib-llama"

# Step 3: Copy binary
echo "[3/7] Copying binary..."
cp "$BINARY" "${CONTENTS}/MacOS/voiceink"

# Step 4: Copy resources
echo "[4/7] Copying resources..."

echo "       whisper-server..."
if [ ! -f "$WHISPER_SERVER" ]; then
    echo "ERROR: whisper-server not found at: $WHISPER_SERVER"
    exit 1
fi
cp "$WHISPER_SERVER" "${RESOURCES}/whisper-server"
chmod +x "${RESOURCES}/whisper-server"

echo "       whisper dylibs..."
# Copy all required dynamic libraries for whisper-server
DYLIBS=(
    "${WHISPER_BUILD}/src/libwhisper.1.dylib"
    "${WHISPER_BUILD}/src/libwhisper.coreml.dylib"
    "${WHISPER_BUILD}/ggml/src/libggml.0.dylib"
    "${WHISPER_BUILD}/ggml/src/libggml-base.0.dylib"
    "${WHISPER_BUILD}/ggml/src/libggml-cpu.0.dylib"
    "${WHISPER_BUILD}/ggml/src/ggml-blas/libggml-blas.0.dylib"
    "${WHISPER_BUILD}/ggml/src/ggml-metal/libggml-metal.0.dylib"
)
for dylib in "${DYLIBS[@]}"; do
    if [ -L "$dylib" ]; then
        # Resolve symlink and copy the actual file with the symlink name
        real=$(readlink -f "$dylib")
        cp "$real" "${RESOURCES}/lib/$(basename "$dylib")"
    elif [ -f "$dylib" ]; then
        cp "$dylib" "${RESOURCES}/lib/"
    else
        echo "WARNING: dylib not found: $dylib"
    fi
done

# Fix rpaths: point whisper-server to bundled libs
# whisper-server is in Resources/, dylibs in Resources/lib/
install_name_tool -add_rpath @executable_path/lib "${RESOURCES}/whisper-server" 2>/dev/null || true

# Also fix rpaths inside dylibs (they reference each other)
for lib in "${RESOURCES}"/lib/*.dylib; do
    # Change @rpath references to point to same directory
    install_name_tool -add_rpath @loader_path "${lib}" 2>/dev/null || true
done

# Models are NOT bundled — downloaded on first launch via ModelManager.
# See scripts/upload-models.sh to upload models to GitHub Releases.

echo "       llama-server..."
if [ ! -f "$LLAMA_SERVER" ]; then
    echo "ERROR: llama-server not found at: $LLAMA_SERVER"
    echo "       Install with: brew install llama.cpp"
    exit 1
fi
cp "$LLAMA_SERVER" "${RESOURCES}/llama-server"
chmod +x "${RESOURCES}/llama-server"

# Helper: resolve and copy a dylib to Resources/lib-llama/
copy_dylib() {
    local src="$1" dst_name="$2"
    [ -f "${RESOURCES}/lib-llama/${dst_name}" ] && return 0
    if [ -L "$src" ]; then
        cp "$(readlink -f "$src")" "${RESOURCES}/lib-llama/${dst_name}"
    elif [ -f "$src" ]; then
        cp "$src" "${RESOURCES}/lib-llama/${dst_name}"
    fi
}

# Copy ggml backend plugins (.so) for llama
echo "       ggml backend plugins..."
GGML_LIBEXEC=$(find /opt/homebrew/Cellar/ggml/*/libexec -name "*.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
if [ -n "$GGML_LIBEXEC" ] && [ -d "$GGML_LIBEXEC" ]; then
    cp "$GGML_LIBEXEC"/*.so "${RESOURCES}/lib-llama/"
    # Copy libomp (needed by CPU backends)
    LIBOMP=$(find /opt/homebrew/Cellar/libomp/*/lib/libomp.dylib 2>/dev/null | head -1)
    if [ -n "$LIBOMP" ] && [ -f "$LIBOMP" ]; then
        cp "$(readlink -f "$LIBOMP")" "${RESOURCES}/lib-llama/libomp.dylib"
    fi
    # Fix dylib deps inside .so backends
    for so in "${RESOURCES}"/lib-llama/*.so; do
        install_name_tool -add_rpath @loader_path "${so}" 2>/dev/null || true
        otool -L "$so" 2>/dev/null | awk '{print $1}' | while read dep; do
            case "$dep" in
                /opt/homebrew/*)
                    dn=$(basename "$dep")
                    copy_dylib "$dep" "$dn"
                    install_name_tool -change "$dep" "@rpath/${dn}" "$so" 2>/dev/null || true
                    ;;
            esac
        done
    done
else
    echo "WARNING: ggml backend plugins not found in homebrew"
fi

# Copy and fix llama-server dylibs
echo "       llama-server dylibs..."

# Find and copy all dylib deps (both @rpath and absolute homebrew paths)
find_homebrew_lib() {
    local libname="$1"
    for d in /opt/homebrew/lib /opt/homebrew/opt/*/lib /opt/homebrew/Cellar/llama.cpp/*/lib /opt/homebrew/Cellar/ggml/*/lib; do
        [ -e "${d}/${libname}" ] && echo "${d}/${libname}" && return 0
    done
    return 1
}

# Collect all deps from llama-server
ALL_DEPS=$(otool -L "${RESOURCES}/llama-server" 2>/dev/null | tail -n +2 | awk '{print $1}')
for dep in $ALL_DEPS; do
    case "$dep" in
        @rpath/*)
            libname="${dep#@rpath/}"
            src=$(find_homebrew_lib "$libname" 2>/dev/null) && copy_dylib "$src" "$libname"
            ;;
        /opt/homebrew/*)
            libname=$(basename "$dep")
            copy_dylib "$dep" "$libname"
            install_name_tool -change "$dep" "@rpath/${libname}" "${RESOURCES}/llama-server" 2>/dev/null || true
            ;;
    esac
done

# Now fix transitive deps inside copied dylibs (2 passes)
for pass in 1 2; do
    for lib in "${RESOURCES}"/lib-llama/*.dylib; do
        [ -f "$lib" ] || continue
        bn=$(basename "$lib")
        # Fix install name
        cur_id=$(otool -D "$lib" 2>/dev/null | tail -1)
        case "$cur_id" in /opt/homebrew/*) install_name_tool -id "@rpath/${bn}" "$lib" 2>/dev/null || true ;; esac
        # Fix deps
        otool -L "$lib" 2>/dev/null | awk '{print $1}' | while read dep; do
            case "$dep" in
                /opt/homebrew/*)
                    dn=$(basename "$dep")
                    copy_dylib "$dep" "$dn"
                    install_name_tool -change "$dep" "@rpath/${dn}" "$lib" 2>/dev/null || true
                    ;;
            esac
        done
    done
done

# Fix rpaths inside llama dylibs (they reference each other)
for lib in "${RESOURCES}"/lib-llama/*.dylib; do
    install_name_tool -add_rpath @loader_path "${lib}" 2>/dev/null || true
done

install_name_tool -add_rpath @executable_path/lib-llama "${RESOURCES}/llama-server" 2>/dev/null || true

# qwen model NOT bundled — downloaded on first launch via ModelManager.

# Step 5: Generate Info.plist
PLIST_VERSION="${VERSION}"
[ "$MODE" = "dev" ] && PLIST_VERSION="${VERSION}+dev"
echo "[5/7] Generating Info.plist (v${PLIST_VERSION})..."
cat > "${CONTENTS}/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>VoiceInk</string>
    <key>CFBundleDisplayName</key>
    <string>VoiceInk</string>
    <key>CFBundleIdentifier</key>
    <string>com.voiceink.app</string>
    <key>CFBundleVersion</key>
    <string>${PLIST_VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${PLIST_VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>voiceink</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>VoiceInk needs microphone access for voice dictation.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Step 6: Code signing
# - dev mode: ad-hoc sign (any local Mac can launch)
# - release mode: Developer ID Application + hardened runtime + entitlements (notarization-ready)
DEVELOPER_ID="Developer ID Application: Paul Stupple (94QK2GK5GT)"
ENTITLEMENTS="${SCRIPT_DIR}/entitlements.plist"

if [ "$MODE" = "release" ]; then
    echo "[6/7] Code signing (Developer ID + hardened runtime)..."
    SIGN_IDENTITY="$DEVELOPER_ID"
    SIGN_OPTS="--force --sign \"$SIGN_IDENTITY\" --timestamp --options runtime --entitlements \"$ENTITLEMENTS\""
else
    echo "[6/7] Code signing (ad-hoc)..."
    SIGN_IDENTITY="-"
    SIGN_OPTS="--force --sign -"
fi

chmod -R u+rw "$BUNDLE"
xattr -cr "$BUNDLE" 2>/dev/null || true

# Sign dylibs and .so files first (deepest first), then executables, then bundle
sign_one() {
    local target="$1"
    if [ "$MODE" = "release" ]; then
        codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime --entitlements "$ENTITLEMENTS" "$target" 2>/dev/null || \
        codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime --entitlements "$ENTITLEMENTS" "$target"
    else
        codesign --force --sign - "$target" 2>/dev/null || true
    fi
}

for lib in "${RESOURCES}"/lib/*.dylib; do
    sign_one "$lib"
done
for lib in "${RESOURCES}"/lib-llama/*.dylib "${RESOURCES}"/lib-llama/*.so; do
    sign_one "$lib"
done
sign_one "${RESOURCES}/whisper-server"
sign_one "${RESOURCES}/llama-server"
sign_one "$BUNDLE"

# Step 7: Verify dylibs
echo "[7/7] Verifying dylib loading..."
if otool -L "${RESOURCES}/whisper-server" | grep -q '@rpath'; then
    echo "       whisper-server @rpath deps (lib/):"
    otool -L "${RESOURCES}/whisper-server" | grep '@rpath' | awk '{print "         "$1}'
fi
if otool -L "${RESOURCES}/llama-server" | grep -q '@rpath'; then
    echo "       llama-server @rpath deps (lib-llama/):"
    otool -L "${RESOURCES}/llama-server" | grep '@rpath' | awk '{print "         "$1}'
fi

# Copy final bundle back to project dir
rm -rf "$FINAL_BUNDLE"
cp -R "$BUNDLE" "$FINAL_BUNDLE"
rm -rf "$BUILD_DIR"

# Remove iCloud xattr that blocks app launch
xattr -dr com.apple.provenance "$FINAL_BUNDLE" 2>/dev/null || true

# Summary
BUNDLE="$FINAL_BUNDLE"
CONTENTS="${BUNDLE}/Contents"
RESOURCES="${CONTENTS}/Resources"
BINARY_SIZE=$(du -sh "${CONTENTS}/MacOS/voiceink" | cut -f1)
LIB_SIZE=$(du -sh "${RESOURCES}/lib/" | cut -f1)
LIB_LLAMA_SIZE=$(du -sh "${RESOURCES}/lib-llama/" | cut -f1)
TOTAL_SIZE=$(du -sh "$BUNDLE" | cut -f1)

echo ""
echo "=== Done! ==="
echo "  Binary:       ${BINARY_SIZE}"
echo "  Whisper libs: ${LIB_SIZE}"
echo "  Llama libs:   ${LIB_LLAMA_SIZE}"
echo "  Total:        ${TOTAL_SIZE}  (models downloaded on first launch)"
echo ""
echo "  ${BUNDLE}"
echo ""
echo "To run:  open ${APP_NAME}.app"

# Step 8: Build .dmg installer (release only)
if [ "$MODE" = "release" ]; then
    echo ""
    echo "=== Building DMG (v${VERSION}) ==="
    DMG_NAME="${APP_NAME}-${VERSION}.dmg"
    DMG_LATEST="${APP_NAME}.dmg"
    DMG_PATH="${SCRIPT_DIR}/${DMG_NAME}"
    DMG_TMP="/tmp/${DMG_NAME}"
    rm -f "$DMG_PATH" "$DMG_TMP"

    if command -v create-dmg &>/dev/null || [ -x /opt/homebrew/bin/create-dmg ]; then
        CREATE_DMG=$(command -v create-dmg || echo /opt/homebrew/bin/create-dmg)
        DMG_BG="${SCRIPT_DIR}/dmg_background.png"
        BG_ARGS=()
        if [ -f "$DMG_BG" ]; then
            BG_ARGS=(--background "$DMG_BG")
        fi
        "$CREATE_DMG" \
            --volname "${APP_NAME}" \
            --window-pos 200 120 \
            --window-size 600 400 \
            --icon-size 128 \
            --icon "${APP_NAME}.app" 150 185 \
            --app-drop-link 450 185 \
            "${BG_ARGS[@]}" \
            --no-internet-enable \
            "$DMG_TMP" \
            "$FINAL_BUNDLE" \
            2>&1 | grep -v "^$"

        cp "$DMG_TMP" "$DMG_PATH"
        rm -f "$DMG_TMP"
        # Also create/update symlink without version for convenience
        ln -sf "$DMG_NAME" "${SCRIPT_DIR}/${DMG_LATEST}"

        # Step 9: Notarize (required for distribution outside App Store)
        # Order: submit DMG → Apple notarizes the .app inside → staple .app →
        # rebuild DMG with stapled .app → sign & staple DMG
        echo ""
        echo "=== Notarizing ==="
        echo "[notary] Signing DMG for submission..."
        codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG_PATH"

        echo "[notary] Submitting to Apple notary service (this can take 1-5 minutes)..."
        if xcrun notarytool submit "$DMG_PATH" \
            --keychain-profile voiceink-notary \
            --wait 2>&1 | tee /tmp/voiceink-notary.log; then
            STATUS=$(grep -E "^\s*status:" /tmp/voiceink-notary.log | tail -1 | awk '{print $2}')
            if [ "$STATUS" = "Accepted" ]; then
                echo "[notary] Stapling .app..."
                xcrun stapler staple "$FINAL_BUNDLE"

                echo "[notary] Rebuilding DMG with stapled .app..."
                rm -f "$DMG_PATH" "$DMG_TMP"
                "$CREATE_DMG" \
                    --volname "${APP_NAME}" \
                    --window-pos 200 120 \
                    --window-size 600 400 \
                    --icon-size 128 \
                    --icon "${APP_NAME}.app" 150 185 \
                    --app-drop-link 450 185 \
                    "${BG_ARGS[@]}" \
                    --no-internet-enable \
                    "$DMG_TMP" \
                    "$FINAL_BUNDLE" \
                    2>&1 | grep -v "^$"
                cp "$DMG_TMP" "$DMG_PATH"
                rm -f "$DMG_TMP"

                echo "[notary] Signing final DMG..."
                codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG_PATH"

                echo "[notary] Submitting final DMG to notary service..."
                if xcrun notarytool submit "$DMG_PATH" \
                    --keychain-profile voiceink-notary \
                    --wait 2>&1 | tee /tmp/voiceink-notary2.log; then
                    STATUS2=$(grep -E "^\s*status:" /tmp/voiceink-notary2.log | tail -1 | awk '{print $2}')
                    if [ "$STATUS2" = "Accepted" ]; then
                        xcrun stapler staple "$DMG_PATH"
                        echo "[notary] OK — .app and DMG both notarized + stapled"
                    else
                        echo "[notary] WARNING — final DMG notarization status: $STATUS2"
                        echo "[notary] .app is stapled, DMG is not — should still work"
                    fi
                else
                    echo "[notary] WARNING — final DMG notarization failed, but .app is stapled"
                fi
            else
                echo "[notary] FAILED — status: $STATUS"
                SUBMISSION_ID=$(grep -E "^\s*id:" /tmp/voiceink-notary.log | head -1 | awk '{print $2}')
                if [ -n "$SUBMISSION_ID" ]; then
                    echo "[notary] Fetching log for submission $SUBMISSION_ID..."
                    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile voiceink-notary
                fi
                exit 1
            fi
        else
            echo "[notary] FAILED — see /tmp/voiceink-notary.log"
            exit 1
        fi

        DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
        DMG_SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
        echo ""
        echo "  DMG:          ${DMG_SIZE}  ${DMG_NAME}  (signed + notarized + stapled)"
        echo "  SHA256:       ${DMG_SHA256}"
        echo "  ${DMG_PATH}"
    else
        echo "  create-dmg not found, skipping DMG creation"
        echo "  Install with: brew install create-dmg"
    fi
else
    echo ""
    echo "  (dev mode — DMG skipped, use './build-app.sh release' for DMG)"
fi
