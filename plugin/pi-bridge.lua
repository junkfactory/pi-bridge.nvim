-- Fallback entry point for native packages and vim-plug.
--
-- Design decision: why plugin/ exists alongside lazy-load support
--
--   Two paths to the same result — `vim.g.loaded_pi_bridge` prevents double
--   registration:
--
--   - lazy.nvim / packer: `cmd = "PiBridge"` and `keys = { "<leader>ai" }`
--     defer the plugin entirely. `plugin/` never runs. `setup()` registers
--     the command and keymaps on first trigger. True lazy-load.
--
--   - Native packages / vim-plug: `plugin/` runs at startup, registers
--     `:PiBridge`. User calls `setup()` for keymaps and config. No
--     lazy-load, but the command is always discoverable.
--
--   This file is a thin fallback — one command registration, guarded. The
--   expensive work (socket connect, context gather) is always deferred to
--   `prompt()`.
--
-- lazy.nvim/packer users: this file is never loaded — cmd/keys triggers load the plugin on demand.
if vim.g.loaded_pi_bridge then return end
vim.g.loaded_pi_bridge = true

vim.api.nvim_create_user_command("PiBridge", function(args)
	if args.args and args.args ~= "" then
		require("pi-bridge").prompt({ text = args.args })
	else
		require("pi-bridge").prompt()
	end
end, { nargs = "?" })

-- Cleanup on exit (fallback for users who never call setup())
vim.api.nvim_create_autocmd("VimLeavePre", {
	group = vim.api.nvim_create_augroup("pi-bridge", { clear = true }),
	callback = function()
		pcall(function() require("pi-bridge.socket").disconnect() end)
	end,
})
