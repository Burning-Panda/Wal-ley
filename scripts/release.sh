#!/bin/bash
# Usage: scripts/release.sh <major|minor|patch> [notes]
# Bumps VERSION, commits it, creates an annotated tag whose message is the
# notes, and pushes. The Release workflow runs on the tag and publishes it.
set -euo pipefail
cd "$(dirname "$0")/.."

kind="${1:-}"
notes="${2:-}"

IFS=. read -r major minor patch < VERSION
case "$kind" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
  *) echo "usage: $0 <major|minor|patch> [notes]" >&2; exit 1 ;;
esac
new="$major.$minor.$patch"
tag="v$new"

[ -z "$(git status --porcelain)" ] || { echo "Working tree not clean; commit or stash first." >&2; exit 1; }
[ "$(git branch --show-current)" = main ] || { echo "Release from main." >&2; exit 1; }
git fetch --quiet origin main --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main is not in sync with origin/main." >&2; exit 1; }
! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || { echo "Tag $tag already exists." >&2; exit 1; }

echo "$new" > VERSION
git add VERSION
git commit -m "Release $tag"
git tag -a "$tag" -m "${notes:-Release $tag}"
git push origin main "$tag"
echo "Pushed $tag. Watch the Release workflow on GitHub."
