-- Fallback entry point for native packages and vim-plug.
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
