#!/usr/bin/env bash
# Launch nvim with isolated config, loading only the local pi-bridge.nvim plugin.
# Does not touch ~/.config/nvim or system config.
#
# Usage:
#   ./scripts/test-nvim.sh              # open current directory
#   ./scripts/test-nvim.sh somefile.lua # open specific file
#   XDG_STATE_HOME=/tmp/x ./scripts/test-nvim.sh  # override state dir

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
INIT_FILE="$SCRIPT_DIR/test_init.lua"

# Isolated nvim state (shada, undo, etc. — pairs with the pi harness's log
# path in /tmp/diff-fix-test); explicit env wins
export XDG_STATE_HOME="${XDG_STATE_HOME:-/tmp/bridge-repro/nvim-state}"
mkdir -p "$XDG_STATE_HOME"

echo "=== pi-bridge.nvim test harness ==="
echo "Plugin dir: $PLUGIN_DIR"
echo "Init file:  $INIT_FILE"
echo "State dir:  $XDG_STATE_HOME"
echo "==================================="

exec nvim --clean -u "$INIT_FILE" "$@"
