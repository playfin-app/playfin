#!/usr/bin/env bash
set -euo pipefail

# Builds and packages Playfin for LG webOS (armv7-unknown-linux-gnueabi, non-root Dev Mode .ipk).
# Requires WEBOS_SDK pointing at an extracted openlgtv/buildroot-nc4 SDK and ares-package on PATH.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEBOS_SDK="${WEBOS_SDK:-}"
OUT_DIR="${OUT_DIR:-$ROOT/build/webos}"
STAGE_DIR="$ROOT/build/webos-stage/com.playfin.webos"

if [[ -z "$WEBOS_SDK" || ! -d "$WEBOS_SDK/bin" ]]; then
    echo "ERROR: WEBOS_SDK must point to an extracted openlgtv/buildroot-nc4 SDK." >&2
    exit 1
fi
if ! command -v ares-package >/dev/null 2>&1; then
    echo "ERROR: ares-package (@webos-tools/cli) is required but not installed." >&2
    exit 1
fi

SYSROOT="$WEBOS_SDK/arm-webos-linux-gnueabi/sysroot"
if [[ ! -d "$SYSROOT/usr/lib" ]]; then
    echo "ERROR: Expected sysroot at $SYSROOT/usr/lib" >&2
    exit 1
fi

export PATH="$WEBOS_SDK/bin:$PATH"
export WEBOS_SYSROOT="$SYSROOT"
export SDL2_INCLUDE_PATH="$SYSROOT/usr/include/SDL2"
export BINDGEN_EXTRA_CLANG_ARGS_armv7_unknown_linux_gnueabi="--sysroot=$SYSROOT -mfloat-abi=softfp"
export CC_armv7_unknown_linux_gnueabi="$WEBOS_SDK/bin/arm-webos-linux-gnueabi-gcc"
export CXX_armv7_unknown_linux_gnueabi="$WEBOS_SDK/bin/arm-webos-linux-gnueabi-g++"
export AR_armv7_unknown_linux_gnueabi="$WEBOS_SDK/bin/arm-webos-linux-gnueabi-ar"
export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABI_LINKER="$WEBOS_SDK/bin/arm-webos-linux-gnueabi-gcc"

if [[ -z "${LIBCLANG_PATH:-}" ]]; then
    for candidate in /usr/lib/llvm-*/lib /usr/lib/x86_64-linux-gnu; do
        if [[ -e "$candidate/libclang.so" || -e "$candidate/libclang.so.1" ]]; then
            export LIBCLANG_PATH="$candidate"
            break
        fi
    done
fi

echo "▶ Building playfin_webos for armv7-unknown-linux-gnueabi (--features webos)"
cargo build \
    --manifest-path "$ROOT/webos/Cargo.toml" \
    --release \
    --target armv7-unknown-linux-gnueabi \
    --features webos

BIN="$ROOT/webos/target/armv7-unknown-linux-gnueabi/release/playfin_webos"
if [[ ! -f "$BIN" ]]; then
    echo "ERROR: Expected binary at $BIN" >&2
    exit 1
fi

echo "▶ Verifying dynamic dependencies, glibc versions, and rpath"
DYN_INFO="$("$WEBOS_SDK/bin/arm-webos-linux-gnueabi-readelf" -d "$BIN")"
printf '%s\n' "$DYN_INFO" | grep -E "NEEDED|RPATH|RUNPATH"
printf '%s\n' "$DYN_INFO" | grep -q "libSDL2-2.0.so.0"
# The TV's /usr/lib/libSDL2 must be the one loaded (the sysroot copy has stub exported-window
# functions, so video plays with sound but no picture). Fail if an rpath could override it.
if printf '%s\n' "$DYN_INFO" | grep -Eq '(RUNPATH|RPATH)'; then
    echo "ERROR: binary has an RPATH/RUNPATH; the TV's own libSDL2 must be used." >&2
    exit 1
fi
"$WEBOS_SDK/bin/arm-webos-linux-gnueabi-readelf" -V "$BIN" | grep -E "Name: GLIBC" | sort -u || true
"$WEBOS_SDK/bin/arm-webos-linux-gnueabi-readelf" -d "$SYSROOT/usr/lib/libSDL2-2.0.so.0" | grep -E "NEEDED|SONAME"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR" "$OUT_DIR"

cp "$BIN" "$STAGE_DIR/playfin_webos"
"$WEBOS_SDK/bin/arm-webos-linux-gnueabi-strip" "$STAGE_DIR/playfin_webos"
chmod +x "$STAGE_DIR/playfin_webos"

cp "$ROOT/webos/packaging/appinfo.json" "$STAGE_DIR/"
cp "$ROOT/webos/packaging/icon.png" "$STAGE_DIR/"
cp "$ROOT/webos/packaging/largeIcon.png" "$STAGE_DIR/"

# libSDL2 is NOT bundled: the TV's /usr/lib copy has the real webOS video plane.

echo "▶ Packaging .ipk via ares-package"
ares-package "$STAGE_DIR" -o "$OUT_DIR"
ls -lh "$OUT_DIR"/*.ipk
