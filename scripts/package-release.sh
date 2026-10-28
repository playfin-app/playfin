#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build/Release"

# Version: VERSION variable (e.g. provided by the v1.2.0 tag in CI), otherwise the project's.
VERSION="${VERSION:-}"
VERSION_PARAMS=()
if [ -n "$VERSION" ]; then
    VERSION_PARAMS=("MARKETING_VERSION=$VERSION" "CURRENT_PROJECT_VERSION=${BUILD_NUMBER:-1}")
fi

# Signature: Developer ID identity if provided (SIGN_IDENTITY, ready for notarisation later);
# otherwise the local "Playfin Dev" certificate if it exists (avoids Keychain prompts); otherwise ad-hoc.
SIGN_ID="${SIGN_IDENTITY:--}"
if [ "$SIGN_ID" = "-" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"Playfin Dev"'; then
    SIGN_ID="Playfin Dev"
fi
TIMESTAMP_FLAG="--timestamp=none"
OPTIONS_FLAGS=()
if [ "${SIGN_IDENTITY:-}" != "" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    TIMESTAMP_FLAG="--timestamp"
    OPTIONS_FLAGS=("--options" "runtime")
fi

echo "▶ 1. Building the core and updating the XCFramework"
"$ROOT/scripts/build-xcframework.sh"

echo "▶ 2. Building the macOS app in Release"
mkdir -p "$BUILD_DIR"
cd "$ROOT/macos"

# Checks whether a universal binary is possible (depending on the rustup targets)
if rustup target list --installed 2>/dev/null | grep -q "x86_64-apple-darwin"; then
    ARCHS_PARAM=("ARCHS=arm64 x86_64" "ONLY_ACTIVE_ARCH=NO")
else
    ARCHS_PARAM=("ONLY_ACTIVE_ARCH=YES")
fi

xcodebuild -project Playfin.xcodeproj \
    -scheme Playfin \
    -configuration Release \
    -derivedDataPath "$ROOT/build/DerivedData" \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    CODE_SIGN_IDENTITY="$SIGN_ID" \
    "${ARCHS_PARAM[@]}" \
    ${VERSION_PARAMS[@]+"${VERSION_PARAMS[@]}"} \
    build

APP_PATH="$BUILD_DIR/Playfin.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: $APP_PATH not found."
    exit 1
fi

echo "▶ 3. Signing the frameworks and the app"
if [ -d "$APP_PATH/Contents/Frameworks" ]; then
    for item in "$APP_PATH/Contents/Frameworks"/*; do
        if [ -e "$item" ]; then
            codesign --force --sign "$SIGN_ID" "$TIMESTAMP_FLAG" ${OPTIONS_FLAGS[@]+"${OPTIONS_FLAGS[@]}"} "$item"
        fi
    done
fi
codesign --force --deep --sign "$SIGN_ID" "$TIMESTAMP_FLAG" ${OPTIONS_FLAGS[@]+"${OPTIONS_FLAGS[@]}"} "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

echo "▶ 4. Creating the ZIP archive for distribution (via ditto)"
cd "$BUILD_DIR"
ZIP_NAME="Playfin-macOS.zip"
rm -f "$ZIP_NAME"
ditto -c -k --keepParent "Playfin.app" "$ZIP_NAME"

# Notarisation (later, with an Apple Developer account): if NOTARY_PROFILE is set, we submit and staple.
if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$ZIP_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "Playfin.app"
    rm -f "$ZIP_NAME"
    ditto -c -k --keepParent "Playfin.app" "$ZIP_NAME"
fi

shasum -a 256 "$ZIP_NAME" | awk '{print $1}' > "$ZIP_NAME.sha256"

echo "✔ Archive ready for distribution:"
echo "  $BUILD_DIR/$ZIP_NAME (sha256 : $(cat "$ZIP_NAME.sha256"))"
echo ""
echo "Gatekeeper note: on another Mac, run:"
echo "  xattr -dr com.apple.quarantine /Applications/Playfin.app"

# The caches make rebuilds fast but grow over time: cleaned once they exceed 10 GB.
echo ""
"$ROOT/scripts/clean.sh" --if-over 10
