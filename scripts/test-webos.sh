#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "▶ Checking hosts and IP allowlist"
"$ROOT/scripts/check-hosts.sh"

cd "$ROOT/webos"

echo "▶ Checking Rust formatting (webos)"
cargo fmt --check

echo "▶ Running Clippy across all targets (webos)"
cargo clippy --all-targets -- -D warnings

echo "▶ Running unit tests (webos)"
cargo test

echo "✔ All webOS host checks passed!"
