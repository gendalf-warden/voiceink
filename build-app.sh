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
# Build outside iCloud Drive. EVERYTHING related to the bundle stays in /tmp —
# .app construction, signing, stapling, and DMG creation. iCloud Drive's File
# Provider re-attaches `com.apple.FinderInfo` + `com.apple.fileprovider.fpfs#P`
# to anything that lands inside iCloud, which trips `codesign --strict` and
# triggers the unfriendly Gatekeeper dialog at first launch. Only the final
# DMG is copied into iCloud (the project repo) at the very end; the .app is
# also mirrored there for dev convenience but is NOT what ships to users.
BUILD_DIR="/tmp/voiceink-build"
BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${BUNDLE}/Contents"
RESOURCES="${CONTENTS}/Resources"
# FINAL_BUNDLE lives in /tmp during build (same dir tree, separate from BUILD_DIR
# so that the existing post-build steps which reference it for DMG creation,
# stapling, etc. keep working without iCloud contamination). It's mirrored to
# iCloud at the end of the script (line ~end of file).
FINAL_BUNDLE="/tmp/voiceink-final/${APP_NAME}.app"
ICLOUD_BUNDLE_MIRROR="${SCRIPT_DIR}/${APP_NAME}.app"

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
mkdir -p "${CONTENTS}/Frameworks"
mkdir -p "${RESOURCES}/lib"
mkdir -p "${RESOURCES}/lib-llama"

# Step 3: Copy binary
echo "[3/7] Copying binary..."
cp "$BINARY" "${CONTENTS}/MacOS/voiceink"

# Sparkle.framework lives in Contents/Frameworks/. The linker leaves the @rpath
# reference but doesn't know what the framework's runtime location will be, so
# we add the standard Mac app rpath here. Without this, dyld fails to load
# Sparkle at launch (crash type 309, "Library not loaded: @rpath/Sparkle.framework/...").
# Must happen BEFORE codesigning — modifying a signed binary invalidates the signature.
install_name_tool -add_rpath @executable_path/../Frameworks "${CONTENTS}/MacOS/voiceink"

# Copy SwiftPM-generated resource bundle (Localizable.strings for en/ru, Info.plist).
# StringLocalizer.findResourceBundle() locates this in Contents/Resources/ at runtime.
# We can't put it at the .app root (where SwiftPM's Bundle.module expects) because
# extra dirs at the .app root break codesigning.
SPM_BUNDLE="/tmp/voiceink-build-scratch/arm64-apple-macosx/release/VoiceInk_VoiceInkLib.bundle"
if [ ! -d "$SPM_BUNDLE" ]; then
    echo "ERROR: SwiftPM resource bundle not found at: $SPM_BUNDLE"
    exit 1
fi
mkdir -p "${RESOURCES}"
cp -R "$SPM_BUNDLE" "${RESOURCES}/"

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

# Sparkle.framework for auto-updates. Resolved via SPM, lives in .build/artifacts/
# (inside iCloud Drive, which decorates every file with com.apple.FinderInfo and
# friends). Those xattrs are "disallowed detritus" for codesign --strict and make
# macOS Gatekeeper show the unfriendly "Apple could not verify" first-launch
# dialog (instead of the friendly "downloaded from Internet — Open?" one), even
# though spctl and notarytool accept the bundle.
#
# `ditto --noextattr` copies the bytes + symlinks but skips every extended
# attribute, so the destination starts clean. We follow up with a recursive
# `xattr -c` sweep as a safety belt — system xattrs (FinderInfo, provenance)
# are sometimes re-applied by the filesystem even right after a clean copy.
echo "       Sparkle.framework..."
SPARKLE_SRC="${SCRIPT_DIR}/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "$SPARKLE_SRC" ]; then
    echo "ERROR: Sparkle.framework not found at: $SPARKLE_SRC"
    echo "       Run 'swift package resolve' to fetch the Sparkle SPM artefact."
    exit 1
fi
ditto --noextattr --noacl "$SPARKLE_SRC" "${CONTENTS}/Frameworks/Sparkle.framework"
# Defense in depth: clear xattrs again after ditto (and on every nested file/dir
# individually — `xattr -cr` is unreliable on deeply-nested signed code).
find "${CONTENTS}/Frameworks/Sparkle.framework" \( -type f -o -type d \) -exec xattr -c {} \; 2>/dev/null || true

# Step 5: Generate Info.plist (and copy app icon)
PLIST_VERSION="${VERSION}"
[ "$MODE" = "dev" ] && PLIST_VERSION="${VERSION}+dev"
echo "[5/7] Generating Info.plist (v${PLIST_VERSION})..."

# Copy app icon if present
if [ -f "${SCRIPT_DIR}/AppIcon.icns" ]; then
    cp "${SCRIPT_DIR}/AppIcon.icns" "${RESOURCES}/AppIcon.icns"
fi

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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>VoiceInk needs microphone access for voice dictation.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>SUFeedURL</key>
    <string>https://gendalf-warden.github.io/voiceink/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>h4npNcO5Ft60v0dq3Nxs/un8eRGmdxhjhkfi0MKos3s=</string>
    <key>SUEnableAutomaticChecks</key>
    <false/>
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

# Sign WITHOUT our entitlements — used for Sparkle.framework internals.
# Sparkle's XPC services, Updater.app, and Autoupdate have their own designed
# entitlements (or none) and should NOT inherit ours. Overriding them with our
# entitlements (audio-input, JIT, etc.) causes macOS to neuter the processes —
# e.g. Autoupdate can't create its install cache directory ("Operation not
# permitted") because the audio-input entitlement requires an
# NSMicrophoneUsageDescription that's not in the framework's Info.plist.
sign_no_ent() {
    local target="$1"
    if [ "$MODE" = "release" ]; then
        codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$target" 2>/dev/null || \
        codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$target"
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

# Sparkle.framework — sign innermost components first (XPC services + Updater.app),
# then the framework itself. Order matters for hardened-runtime + notarization.
# Crucially, sign WITHOUT our entitlements (use sign_no_ent) — see comment on
# sign_no_ent above.
SPARKLE_FW="${CONTENTS}/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
    # Strip stale xattrs (com.apple.FinderInfo etc.) that ditto preserved from
    # the SPM artefact in iCloud Drive. These break codesign --deep --strict.
    xattr -cr "$SPARKLE_FW" 2>/dev/null || true

    for xpc in "${SPARKLE_FW}/Versions/B/XPCServices/"*.xpc; do
        [ -d "$xpc" ] && sign_no_ent "$xpc"
    done
    if [ -d "${SPARKLE_FW}/Versions/B/Updater.app" ]; then
        sign_no_ent "${SPARKLE_FW}/Versions/B/Updater.app"
    fi
    if [ -f "${SPARKLE_FW}/Versions/B/Autoupdate" ]; then
        sign_no_ent "${SPARKLE_FW}/Versions/B/Autoupdate"
    fi
    sign_no_ent "$SPARKLE_FW"
fi

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

# Move the freshly-signed bundle from BUILD_DIR to FINAL_BUNDLE — both in /tmp.
# We deliberately do NOT touch iCloud Drive here. The DMG is built from
# FINAL_BUNDLE (also in /tmp), then notarized + stapled, and only the .dmg
# file is copied into iCloud at the very end (see end of script).
rm -rf "$FINAL_BUNDLE"
mkdir -p "$(dirname "$FINAL_BUNDLE")"
ditto --noextattr --noacl "$BUNDLE" "$FINAL_BUNDLE"
rm -rf "$BUILD_DIR"

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

    # create-dmg uses AppleScript via Finder to style the DMG window (drag arrow,
    # background image, icon positions). Macs running this build script need
    # "Automation → Finder" granted under Privacy & Security; without it,
    # AppleScript fails with `-1743 Not authorized to send Apple events to Finder`
    # and the styled DMG never gets written. Probe ahead of time so we can fall
    # back to a plain `hdiutil create` DMG (no fancy window, no drag arrow) when
    # the permission is missing. The plain DMG still installs fine — the user
    # drags the .app to /Applications themselves.
    HAVE_FINDER_AUTOMATION=0
    if osascript -e 'tell application "Finder" to count items of (computer container)' >/dev/null 2>&1; then
        HAVE_FINDER_AUTOMATION=1
    else
        echo "  NOTE: AppleScript→Finder is blocked by TCC. Using plain hdiutil DMG (no styled background)."
        echo "        To get the styled DMG, grant 'Claude' / your terminal Automation→Finder permission"
        echo "        in System Settings → Privacy & Security → Automation."
    fi

    # Pretty DMG via create-dmg, or plain DMG via hdiutil. Caller writes to $DMG_TMP.
    make_dmg() {
        local out="$1"
        rm -f "$out"
        if [ "$HAVE_FINDER_AUTOMATION" = 1 ] && [ -n "$CREATE_DMG" ]; then
            "$CREATE_DMG" \
                --volname "${APP_NAME}" \
                --window-pos 200 120 \
                --window-size 600 400 \
                --icon-size 128 \
                --icon "${APP_NAME}.app" 150 185 \
                --app-drop-link 450 185 \
                "${BG_ARGS[@]}" \
                --no-internet-enable \
                "$out" \
                "$FINAL_BUNDLE" \
                2>&1 | grep -v "^$"
            [ -f "$out" ] && return 0
            echo "  create-dmg failed to produce '$out' — falling back to hdiutil"
        fi
        # hdiutil fallback: plain compressed DMG, no styling
        hdiutil create -fs HFS+ -volname "${APP_NAME}" \
            -srcfolder "$FINAL_BUNDLE" -ov -format UDZO "$out" \
            >/dev/null
    }

    if command -v create-dmg &>/dev/null || [ -x /opt/homebrew/bin/create-dmg ]; then
        CREATE_DMG=$(command -v create-dmg || echo /opt/homebrew/bin/create-dmg)
        DMG_BG="${SCRIPT_DIR}/dmg_background.png"
        BG_ARGS=()
        if [ -f "$DMG_BG" ]; then
            BG_ARGS=(--background "$DMG_BG")
        fi
        make_dmg "$DMG_TMP"

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
                make_dmg "$DMG_TMP"
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

# Mirror the final .app from /tmp into iCloud (project root) for dev convenience.
# `open VoiceInk.app`, swift run, smoke tests etc. expect it next to the repo.
# For release builds, by the time we get here the DMG is already built +
# notarized + stapled, so iCloud xattrs on this mirrored copy CANNOT affect
# distribution — only this mirror sees them. For dev builds, the .app never
# leaves the local machine, so xattrs are harmless.
echo ""
echo "Mirroring .app to project dir (iCloud) for dev use..."
rm -rf "$ICLOUD_BUNDLE_MIRROR"
ditto --noextattr --noacl "$FINAL_BUNDLE" "$ICLOUD_BUNDLE_MIRROR"
echo "  ${ICLOUD_BUNDLE_MIRROR}"
