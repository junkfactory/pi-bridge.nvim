-- Minimal init for interactive testing of pi-bridge.nvim.
-- Does not touch system nvim config.
--
-- Usage:
--   nvim --clean -u scripts/test_init.lua
--
-- Or use the wrapper script:
--   ./scripts/test-nvim.sh

-- Resolve plugin directory (parent of scripts/)
local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")

-- Add plugin to runtimepath
vim.opt.rtp:prepend(plugin_dir)

-- Set leader to space (common modern default)
vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- Disable netrw, filetype plugins, etc. for clean slate
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

-- Basic settings
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.undofile = false

-- Setup pi-bridge with test-friendly defaults
require("pi-bridge").setup({
  auto_launch = false, -- don't auto-launch pi in test harness
  log_level = "debug",
  keymaps = {
    prompt = "<leader>ai",
  },
})

-- Print status
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    print("pi-bridge.nvim test harness loaded")
    print("Plugin dir: " .. plugin_dir)
    print("Use <leader>ai or :PiBridge to send messages")
    print("Connect to pi running with: ./scripts/test-pi.sh")
  end,
})
