-- Minimal init for running tests with mini.test
-- Usage: nvim --headless --noplugin -u scripts/minimal_init.lua -c "lua MiniTest.run()"

-- Add plugin to rtp
local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(plugin_dir)

-- Add mini.nvim to rtp (test dependency)
vim.opt.rtp:prepend(plugin_dir .. "/.deps/mini.nvim")

-- Make mini.test available globally
MiniTest = require("mini.test")

-- Require plugin modules so they're available in tests
require("pi-bridge.log")
