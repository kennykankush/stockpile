#!/bin/bash
# One-command ship: clean-tree check → release.sh (archive/sign/notarize/
# staple/zip) → GitHub release → cask bump → push.
set -euo pipefail

cd "$(dirname "$0")/.."

[ -z "$(git status --porcelain)" ] || { echo "error: working tree is dirty — commit first" >&2; exit 1; }

VERSION=$(grep -m1 MARKETING_VERSION project.yml | awk '{print $2}' | tr -d '"')
if git rev-parse "v$VERSION" >/dev/null 2>&1 || gh release view "v$VERSION" >/dev/null 2>&1; then
    echo "error: v$VERSION already released — bump MARKETING_VERSION in project.yml" >&2
    exit 1
fi

./scripts/release.sh
./scripts/update-cask.sh

echo "▸ Creating GitHub release v${VERSION}…"
gh release create "v$VERSION" "build/Stockpile-$VERSION.zip" \
    --title "Stockpile $VERSION" --generate-notes

git add Casks/stockpile.rb
git commit -m "cask: v$VERSION"
git push

echo "✅ Published v$VERSION — release live, cask updated, tap current."
