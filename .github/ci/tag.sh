#!/usr/bin/env bash
# Release-trigger helper. Run from repo root BEFORE pushing:
#   ./.github/ci/tag.sh <version>      e.g. ./.github/ci/tag.sh 0.1.0
# Creates an annotated tag and pushes it; the tag push triggers the
# GitHub Actions release job. DRY_RUN=1 prints actions instead of
# creating/pushing anything.
set -euo pipefail

cd "$(dirname "$0")/../.."

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: ./.github/ci/tag.sh <version>  (e.g. 0.1.0)" >&2
    exit 1
fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: '$VERSION' is not a valid semver (expected MAJOR.MINOR.PATCH)" >&2
    exit 1
fi

branch="$(git branch --show-current)"
if [ "$branch" != "main" ]; then
    echo "error: must run on main (current branch: '${branch:-detached HEAD}')" >&2
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree is not clean" >&2
    exit 1
fi

TAG="v$VERSION"
echo "==> running tests"
make test

echo "==> creating tag $TAG"
if [ -n "${DRY_RUN:-}" ]; then
    echo "DRY_RUN: git tag -a $TAG -m 'release $TAG'"
    echo "DRY_RUN: git push origin main $TAG"
    echo "done (dry run) — re-run without DRY_RUN to release"
    exit 0
fi
git tag -a "$TAG" -m "release $TAG"
git push origin main "$TAG"

echo "==> tag pushed; the release job is running"
echo "next steps:"
echo "  - check the Actions run for $TAG"
echo "  - if this cut changes the socket protocol (paired release with pi-bridge.ext"
echo "    at the same version), add the pairing line to BOTH release notes afterward"
