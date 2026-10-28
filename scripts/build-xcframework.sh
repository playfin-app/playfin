#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$ROOT/macos/Generated"
CORE_DIR="$ROOT/core"
TARGET_DIR="$CORE_DIR/target"
OUTPUT_XCFRAMEWORK="$ROOT/macos/PlayfinCore.xcframework"

export MACOSX_DEPLOYMENT_TARGET=14.0

cd "$CORE_DIR"

echo "▶ Building the Rust core"
if rustup target list --installed 2>/dev/null | grep -q "x86_64-apple-darwin"; then
    echo "  → arm64 and x86_64 targets detected, creating a universal binary"
    cargo build --release --target aarch64-apple-darwin
    cargo build --release --target x86_64-apple-darwin

    mkdir -p "$TARGET_DIR/universal"
    lipo -create \
        "$TARGET_DIR/aarch64-apple-darwin/release/libplayfin_core.a" \
        "$TARGET_DIR/x86_64-apple-darwin/release/libplayfin_core.a" \
        -output "$TARGET_DIR/universal/libplayfin_core.a"

    lipo -create \
        "$TARGET_DIR/aarch64-apple-darwin/release/libplayfin_core.dylib" \
        "$TARGET_DIR/x86_64-apple-darwin/release/libplayfin_core.dylib" \
        -output "$TARGET_DIR/universal/libplayfin_core.dylib"

    STATIC_LIB="$TARGET_DIR/universal/libplayfin_core.a"
    DYLIB="$TARGET_DIR/universal/libplayfin_core.dylib"
else
    echo "  → Local native target"
    cargo build --release
    STATIC_LIB="$TARGET_DIR/release/libplayfin_core.a"
    DYLIB="$TARGET_DIR/release/libplayfin_core.dylib"
fi

echo "▶ Generating the Swift bindings with UniFFI"
rm -rf "$GEN"
cargo run -q --features bindgen --bin uniffi-bindgen -- \
    generate --library "$DYLIB" --language swift --out-dir "$GEN"

mkdir -p "$GEN/include"
mv "$GEN/playfin_coreFFI.h" "$GEN/include/"
mv "$GEN/playfin_coreFFI.modulemap" "$GEN/include/module.modulemap"

echo "▶ Assembling PlayfinCore.xcframework"
install_name_tool -id "@rpath/libplayfin_core.dylib" "$DYLIB"
rm -rf "$OUTPUT_XCFRAMEWORK"
xcodebuild -create-xcframework \
    -library "$DYLIB" -headers "$GEN/include" \
    -output "$OUTPUT_XCFRAMEWORK"

if command -v xcodegen &> /dev/null; then
    echo "▶ Regenerating the Xcode project (xcodegen)"
    cd "$ROOT/macos" && xcodegen generate --quiet
fi

echo "✔ XCFramework ready: $OUTPUT_XCFRAMEWORK"
