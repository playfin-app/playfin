#!/bin/bash
# Writes the Homebrew cask of a version: scripts/update-cask.sh <version> <sha256> <owner/repo> <output file>
set -euo pipefail
VERSION="$1"; SHA="$2"; SLUG="$3"; OUT="$4"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OWNER="${SLUG%%/*}"; REPO="${SLUG##*/}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "invalid version: $VERSION" >&2; exit 1; }
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "invalid sha256" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA/" -e "s/__OWNER__/$OWNER/g" -e "s/__REPO__/$REPO/g" \
    "$ROOT/packaging/homebrew/playfin.rb.template" > "$OUT"
echo "Cask written: $OUT"
