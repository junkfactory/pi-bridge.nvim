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
local setup_opts = {
  auto_launch = false, -- don't auto-launch pi in test harness
  log_level = "debug",
  keymaps = {
    prompt = "<leader>ai",
  },
}

-- Generic env-override convention: any env var named like a snake_case
-- option identifier is coerced ("true"/"false" → boolean, numeric
-- strings → number) and passed into setup as an override, e.g.:
--   ui_prompt_mirror=false ./scripts/test-nvim.sh
--   auto_launch=true ./scripts/test-nvim.sh
-- Shell-standard vars are uppercase, so they never match the pattern.
-- NOTE: vim.fn.environ(), not pairs(vim.env) — the latter does not
-- enumerate externally-set vars (found live: opt silently ignored).
for key, value in pairs(vim.fn.environ()) do
  if key:match("^[a-z][a-z0-9_]*$") then
    local v = value
    if v == "true" then
      v = true
    elseif v == "false" then
      v = false
    else
      local n = tonumber(v)
      if n ~= nil then
        v = n
      end
    end
    setup_opts[key] = v
  end
end

require("pi-bridge").setup(setup_opts)

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
