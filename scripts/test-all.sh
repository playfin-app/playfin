#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "=========================================="
echo " 0a. Checking hosts and IP addresses (check-hosts)"
echo "=========================================="
"$ROOT/scripts/check-hosts.sh"

echo ""
echo "=========================================="
echo " 0b. Secrets scan (gitleaks)"
echo "=========================================="
if ! command -v gitleaks &> /dev/null; then
    echo "ERROR: gitleaks is required but not installed." >&2
    exit 1
fi
gitleaks detect --source "$ROOT" --verbose

echo ""
echo "=========================================="
echo " 0c. Linting Swift (swiftlint)"
echo "=========================================="
if ! command -v swiftlint &> /dev/null; then
    echo "ERROR: swiftlint is required but not installed." >&2
    exit 1
fi
cd "$ROOT"
swiftlint lint --strict

echo ""
echo "=========================================="
echo " 1. Rust unit tests (cargo test)"
echo "=========================================="
cd "$ROOT/core"
cargo test

echo ""
echo "=========================================="
echo " 2. Linting Rust (cargo clippy)"
echo "=========================================="
cargo clippy -- -D warnings

echo ""
echo "=========================================="
echo " 3. Formatting Rust (cargo fmt)"
echo "=========================================="
cargo fmt --check

echo ""
echo "=========================================="
echo " 4. Unit tests and macOS build (Xcode)"
echo "=========================================="
cd "$ROOT/macos"
if ! command -v xcodebuild &> /dev/null; then
    echo "ERROR: xcodebuild is required but not installed (the Swift tests cannot run)." >&2
    exit 1
fi
xcodebuild -project Playfin.xcodeproj \
    -scheme Playfin \
    -destination "platform=macOS" \
    -derivedDataPath "$HOME/Library/Caches/Playfin/DerivedData" \
    test

echo ""
echo "✔ All tests and checks passed!"

# The caches make rebuilds fast but grow over time: cleaned once they exceed 10 GB.
"$ROOT/scripts/clean.sh" --if-over 10
