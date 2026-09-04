#!/usr/bin/env bash
# CI build/test entry point. Usage: build.sh [nvim-version]
# NVIM_VERSION defaults to "stable". Installs the requested Neovim
# (linux x86_64 tarball) if the local nvim doesn't satisfy the request,
# then runs the test suite.
set -euo pipefail

cd "$(dirname "$0")/../.."

NVIM_VERSION="${1:-${NVIM_VERSION:-stable}}"

need_install=0
if command -v nvim >/dev/null 2>&1; then
    installed="$(nvim --version | head -1 | awk '{print $NF}')"
    if [ "$NVIM_VERSION" = "stable" ] || [ "$installed" = "v$NVIM_VERSION" ]; then
        echo "using installed nvim $installed"
    else
        need_install=1
    fi
else
    need_install=1
fi

if [ "$need_install" -eq 1 ]; then
    echo "installing nvim $NVIM_VERSION"
    # Resolve the release tag via git ls-remote (the releases/latest redirect
    # is unreliable on CI runners): stable → highest v* tag; MAJOR.MINOR
    # (e.g. 0.12) → highest matching v$MAJOR.$MINOR.* tag.
    if [ "$NVIM_VERSION" = "stable" ]; then
        NVIM_VERSION="$(git ls-remote --tags --refs https://github.com/neovim/neovim \
            'v*' | awk -F/ '{print $NF}' | sed 's/^v//' | sort -V | tail -1)"
        echo "resolved stable to nvim $NVIM_VERSION"
    elif [ "$(printf %s "$NVIM_VERSION" | tr -cd . | wc -c)" -eq 1 ]; then  # MAJOR.MINOR
        NVIM_VERSION="$(git ls-remote --tags --refs https://github.com/neovim/neovim \
            "v${NVIM_VERSION}.*" | awk -F/ '{print $NF}' | sort -V | tail -1 | sed 's/^v//')"
        if [ -z "$NVIM_VERSION" ]; then
            echo "no nvim release found for the requested series" >&2
            exit 1
        fi
        echo "resolved to nvim $NVIM_VERSION"
    fi
    curl -fsSL "https://github.com/neovim/neovim/releases/download/v${NVIM_VERSION}/nvim-linux-x86_64.tar.gz" \
        -o /tmp/nvim.tar.gz
    mkdir -p /tmp/nvim-ci
    tar -xzf /tmp/nvim.tar.gz -C /tmp/nvim-ci --strip-components=1
    export PATH="/tmp/nvim-ci/bin:$PATH"
    nvim --version | head -1
fi

# Test dependency: mini.nvim (gitignored, fetched once)
if [ ! -d .deps/mini.nvim ]; then
    echo "fetching mini.nvim test dependency"
    git clone --depth 1 https://github.com/echasnovski/mini.nvim .deps/mini.nvim
fi

make test
