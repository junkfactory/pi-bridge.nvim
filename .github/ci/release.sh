#!/usr/bin/env bash
# Runs inside GitHub Actions on a tag push. Creates the GitHub release
# with generated notes. Pairing lines for protocol-change cuts are
# added manually afterward, not here.
set -euo pipefail

TAG="${GITHUB_REF_NAME:-}"
if ! [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: GITHUB_REF_NAME '$TAG' is not a vMAJOR.MINOR.PATCH tag" >&2
    exit 1
fi

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "release $TAG already exists; nothing to do"
    exit 0
fi

gh release create "$TAG" --generate-notes --title "$TAG"
