#!/usr/bin/env bash
# Release-trigger helper. Run from repo root before pushing.
# Usage: ./.github/ci/tag.sh <version>   (e.g. 0.1.0)
# Set DRY_RUN=1 to run checks and skip tag/push mutations.
set -euo pipefail

cd "$(dirname "$0")/../.."

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: $0 <version> (semver, e.g. 0.1.0)" >&2
  exit 1
fi

BOOKMARKS="$(jj bookmark list main)"
if [[ "$BOOKMARKS" != main:* ]]; then
  echo "Local main bookmark not found. Aborting." >&2
  exit 1
fi

STATUS="$(jj status)"
if [[ "$STATUS" != *"working copy has no changes"* ]]; then
  echo "Working copy not clean. Aborting." >&2
  exit 1
fi

TAG="v$VERSION"
TAGS="$(jj tag list)"
if [[ "$TAGS" =~ (^|[[:space:]])${TAG}([[:space:]]|$) ]]; then
  echo "Tag $TAG already exists. Aborting." >&2
  exit 1
fi

echo "==> running build checks"
./.github/ci/build.sh

if [[ -n "${DRY_RUN:-}" ]]; then
  echo "DRY_RUN: jj tag set $TAG -r main"
  echo "DRY_RUN: jj git push --bookmark main --tag $TAG"
else
  jj tag set "$TAG" -r main
  jj git push --bookmark main --tag "$TAG"
fi

echo "Done. The $TAG push triggers the release job."
echo "Next steps: check the release notes; on protocol-change cuts, add the pairing line to the release notes afterward."
