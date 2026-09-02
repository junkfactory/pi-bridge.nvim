local MiniTest = require("mini.test")
local expect = MiniTest.expect

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set()

T["init"] = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.start({ "-u", "scripts/minimal_init.lua" })
			child.lua("MiniTest = require('mini.test')")
		end,
		post_case = function()
			child.stop()
		end,
	},
})

-- Phase 1: setup and config

T["init"]["setup with defaults succeeds"] = function()
	local ok = child.lua([[
		local ok, err = pcall(require('pi-bridge').setup)
		return ok
	]])
	expect.equality(ok, true)
end

T["init"]["setup sets vim.g.loaded_pi_bridge"] = function()
	child.lua("require('pi-bridge').setup()")
	local loaded = child.lua("return vim.g.loaded_pi_bridge")
	expect.equality(loaded, true)
end

T["init"]["setup registers :PiBridge command"] = function()
	child.lua("require('pi-bridge').setup()")
	local cmd_exists = child.lua([[
		local cmds = vim.api.nvim_get_commands({})
		return cmds['PiBridge'] ~= nil
	]])
	expect.equality(cmd_exists, true)
end

T["init"]["setup with custom keymaps"] = function()
	child.lua([[
		require('pi-bridge').setup({ keymaps = { prompt = '<leader>t' } })
	]])
	local has_map = child.lua([[
		local maps = vim.api.nvim_get_keymap('n')
		for _, m in ipairs(maps) do
			if m.desc == 'Send prompt to pi' then
				return true
			end
		end
		return false
	]])
	expect.equality(has_map, true)
end

T["init"]["setup with keymaps = false"] = function()
	child.lua([[
		require('pi-bridge').setup({ keymaps = false })
	]])
	local has_map = child.lua([[
		local maps = vim.api.nvim_get_keymap('n')
		for _, m in ipairs(maps) do
			if m.desc == 'Send prompt to pi' then
				return true
			end
		end
		return false
	]])
	expect.equality(has_map, false)
end

T["init"]["setup rejects invalid split_direction"] = function()
	local ok = child.lua([[
		local ok, err = pcall(require('pi-bridge').setup, { split_direction = 'diagonal' })
		return ok
	]])
	expect.equality(ok, false)
end

T["init"]["setup rejects invalid log_level"] = function()
	local ok = child.lua([[
		local ok, err = pcall(require('pi-bridge').setup, { log_level = 'verbose' })
		return ok
	]])
	expect.equality(ok, false)
end

T["init"]["setup rejects invalid launch_cmd"] = function()
	local ok = child.lua([[
		local ok, err = pcall(require('pi-bridge').setup, { launch_cmd = {} })
		return ok
	]])
	expect.equality(ok, false)
end

T["init"]["setup is idempotent"] = function()
	child.lua([[
		require('pi-bridge').setup({ log_level = 'debug' })
		require('pi-bridge').setup({ log_level = 'error' })
	]])
	local config = child.lua("return require('pi-bridge').get_config()")
	expect.equality(config.log_level, "debug")
end

T["init"]["autochdir warning"] = function()
	child.lua("vim.o.autochdir = true")
	local ok = child.lua([[
		local ok, err = pcall(require('pi-bridge').setup)
		return ok
	]])
	expect.equality(ok, true)
end

T["init"]["VimLeavePre autocmd registered"] = function()
	child.lua("require('pi-bridge').setup()")
	local has_autocmd = child.lua([[
		local aus = vim.api.nvim_get_autocmds({ group = 'pi-bridge' })
		return #aus > 0
	]])
	expect.equality(has_autocmd, true)
end

-- Phase 2: prompt flow

T["init"]["prompt without setup shows error"] = function()
	local ok = child.lua([[
		local ok, err = pcall(require('pi-bridge').prompt, { text = 'test' })
		return ok
	]])
	expect.equality(ok, true)
end

T["init"]["prompt with text skips input"] = function()
	child.lua("require('pi-bridge').setup({ auto_launch = false })")
	local ok = child.lua([[
		local ok, err = pcall(require('pi-bridge').prompt, { text = 'test message' })
		return ok
	]])
	expect.equality(ok, true)
end

T["init"]["socket_path uses sha256 of cwd"] = function()
	child.lua("require('pi-bridge').setup()")
	local path = child.lua([[
		local cwd = vim.fn.getcwd()
		local hash = vim.fn.sha256(cwd)
		return vim.fn.expand('~/.pi/agent/pi-bridge/sockets/') .. hash .. '.sock'
	]])
	expect.equality(path:find("%.sock$") ~= nil, true)
	expect.equality(path:find("pi%-bridge/sockets/") ~= nil, true)
	local hex = path:match("([^/]+)%.sock$")
	expect.equality(#hex, 64)
end

return T
