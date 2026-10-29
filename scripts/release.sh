#!/bin/bash
# Publishes a version in one command: scripts/release.sh <version> [--dry-run]
#
# On the dev branch, with nothing left to commit: writes the version everywhere (core, Xcode project, decision 0011),
# commits "chore: version X.Y.Z", moves main to dev, creates the tag vX.Y.Z and pushes all three. The tag starts the
# Release workflow (tests, universal app, GitHub release, Homebrew cask). If GitHub has not started it a minute after
# the push, it is started by hand (gh). --dry-run: checks and shows the changes, commits and pushes nothing.
set -euo pipefail

VERSION="${1:-}"
DRY_RUN=false
[ "${2:-}" = "--dry-run" ] && DRY_RUN=true
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { echo "❌ $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: scripts/release.sh X.Y.Z [--dry-run]"
TAG="v$VERSION"
[ "$(git branch --show-current)" = "dev" ] || fail "run it on the dev branch"
[ -z "$(git status --porcelain)" ] || fail "commit or put aside the changes first"
git fetch --quiet origin --tags
git rev-parse -q --verify "refs/tags/$TAG" > /dev/null && fail "the tag $TAG already exists"
git merge-base --is-ancestor origin/main dev || fail "main has commits that dev does not have"
git merge-base --is-ancestor origin/dev dev || fail "pull dev first (origin/dev has commits that are not here)"

CURRENT="$(sed -n 's/^version = "\(.*\)"/\1/p' core/Cargo.toml | head -1)"
[ "$CURRENT" != "$VERSION" ] || fail "the version is already $VERSION"
echo "▶ Version $CURRENT → $VERSION"

sed -i '' "s/^version = \"$CURRENT\"/version = \"$VERSION\"/" core/Cargo.toml
(cd core && cargo update --quiet -p playfin_core --offline)
sed -i '' "s/MARKETING_VERSION: \"$CURRENT\"/MARKETING_VERSION: \"$VERSION\"/" macos/project.yml
sed -i '' "s/MARKETING_VERSION = $CURRENT;/MARKETING_VERSION = $VERSION;/" macos/Playfin.xcodeproj/project.pbxproj
sed -i '' "s/- \*\*Version\*\*: $CURRENT /- **Version**: $VERSION /" docs/decisions/0011-final-name-language-and-distribution.md

# Every file must have changed: otherwise its format moved and this script must be updated.
for file in core/Cargo.toml core/Cargo.lock macos/project.yml macos/Playfin.xcodeproj/project.pbxproj \
    docs/decisions/0011-final-name-language-and-distribution.md; do
    git diff --quiet -- "$file" && { git checkout -- .; fail "the version was not found in $file"; }
done
git --no-pager diff --stat

if $DRY_RUN; then
    git checkout -- .
    echo "✔ Dry run: everything is ready, nothing was committed or pushed."
    exit 0
fi

git commit --quiet -am "chore: version $VERSION"
git checkout --quiet main
git merge --quiet --ff-only dev
git checkout --quiet dev
git tag -a "$TAG" -m "Playfin $VERSION"
git push --quiet origin dev main "$TAG"
echo "▶ Pushed: dev, main and $TAG"

# The tag push should start the Release workflow by itself; otherwise it is started here.
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
for _ in 1 2 3 4 5 6; do
    sleep 10
    if [ -n "$(gh run list --repo "$REPO" --workflow Release --branch "$TAG" --json databaseId --jq '.[0].databaseId // empty')" ]; then
        echo "✔ Release started by the push of $TAG"
        break
    fi
done
if [ -z "$(gh run list --repo "$REPO" --workflow Release --branch "$TAG" --json databaseId --jq '.[0].databaseId // empty')" ]; then
    echo "▶ GitHub did not start the release after the push: started by hand"
    gh workflow run Release --repo "$REPO" --ref "$TAG"
fi
echo "Follow it with: gh run list --repo $REPO --workflow Release --limit 1"
