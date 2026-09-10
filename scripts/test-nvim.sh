#!/usr/bin/env bash
# Launch nvim with isolated config, loading only the local pi-bridge.nvim plugin.
# Does not touch ~/.config/nvim or system config.
#
# Usage:
#   ./scripts/test-nvim.sh              # open current directory
#   ./scripts/test-nvim.sh somefile.lua # open specific file

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
INIT_FILE="$SCRIPT_DIR/test_init.lua"

echo "=== pi-bridge.nvim test harness ==="
echo "Plugin dir: $PLUGIN_DIR"
echo "Init file:  $INIT_FILE"
echo "==================================="

exec nvim --clean -u "$INIT_FILE" "$@"
