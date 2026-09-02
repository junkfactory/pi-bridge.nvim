local MiniTest = require("mini.test")
local expect = MiniTest.expect

local child = MiniTest.new_child_neovim()
local helpers = dofile("tests/helpers.lua")

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
	local dir = helpers.tmpdir()
	local path = dir .. "/test.sock"

	child.lua(string.format([[
		vim.env.PI_BRIDGE_TESTING = '1'
		vim.env.ENV_TEST_SOCKET_PATH = %q
		require('pi-bridge').setup({ auto_launch = false })
	]], path))
	local ok = child.lua([[
		local ok, err = pcall(require('pi-bridge').prompt, { text = 'test message' })
		return ok
	]])
	expect.equality(ok, true)

	helpers.rmdir(dir)
end

T["init"]["resolve.socket_path_for_dir uses sha256 of cwd"] = function()
	child.lua("require('pi-bridge').setup()")
	local result = child.lua([[
		local resolve = require('pi-bridge.resolve')
		local cwd = vim.fn.getcwd()
		local path = resolve.socket_path_for_dir(cwd)
		local hex = path:match('([^/]+)%.sock$')
		return { path = path, hex_len = #hex, has_sock_dir = path:find('pi%-bridge/sockets/') ~= nil }
	]])
	expect.equality(result.path:find("%.sock$") ~= nil, true)
	expect.equality(result.has_sock_dir, true)
	expect.equality(result.hex_len, 16)
end

-- Remote disconnect notification
--
-- When the persistent socket observes an unexpected EOF/error from the
-- pi side, init.lua must surface a notification but must NOT auto-launch
-- a new pi from the callback. VimLeavePre cleanup is a local disconnect
-- and must not trigger a notification.

T["init"]["remote disconnect surfaces a notification"] = function()
	-- Stub helpers.lua-style mock_server in the child, connect via real
	-- socket.connect(), then stop the server to simulate remote EOF.
	local dir = helpers.tmpdir()
	local path = dir .. "/test.sock"

	child.lua(string.format([[
		local helpers = dofile('tests/helpers.lua')
		_G._test_server = helpers.mock_server(%q)

		-- capture notifications
		_G._notifications = {}
		vim.notify = function(msg, level)
			table.insert(_G._notifications, { msg = msg, level = level })
		end

		vim.env.PI_BRIDGE_TESTING = '1'
		vim.env.ENV_TEST_SOCKET_PATH = %q
		require('pi-bridge').setup({ auto_launch = false })
		require('pi-bridge').prompt({ text = 'first' })
		vim.wait(1500, function()
			return require('pi-bridge.socket').is_connected()
		end, 30)
	]], path, path))

	expect.equality(child.lua("return require('pi-bridge.socket').is_connected()"), true)

	-- Stop the server: remote EOF. init.lua's callback must fire once.
	child.lua("_G._test_server.stop()")
	child.lua("vim.wait(400)")

	local notifications = child.lua([[
		return vim.tbl_map(function(n) return n.msg end, _G._notifications)
	]])
	local saw_disconnect = false
	for _, msg in ipairs(notifications) do
		if msg:match("pi session disconnected") then
			saw_disconnect = true
			break
		end
	end
	expect.equality(saw_disconnect, true)

	-- Notification must NOT auto-launch: a subsequent prompt with no
	-- server and auto_launch=false must fail with the standard
	-- "no active pi" path, not silently relaunch.
	child.lua([[
		require('pi-bridge.socket').disconnect()
		_G._notifications = {}
		-- Stub launch so any accidental relaunch would be visible.
		local launch = require('pi-bridge.launch')
		_G._launch_called = false
		launch.prompt_launch = function(_, _, cb)
			_G._launch_called = true
			cb(false)
		end
	]])

	local launch_called = child.lua([[
		-- resolve must not find a socket (we stopped it) and auto_launch=false
		require('pi-bridge').prompt({ text = 'no server' })
		vim.wait(800, function()
			return #_G._notifications > 0 or _G._launch_called
		end, 30)
		return _G._launch_called
	]])
	expect.equality(launch_called, false)

	helpers.rmdir(dir)
end

T["init"]["local disconnect does not notify"] = function()
	local dir = helpers.tmpdir()
	local path = dir .. "/test.sock"

	child.lua(string.format([[
		local helpers = dofile('tests/helpers.lua')
		_G._test_server = helpers.mock_server(%q)

		_G._notifications = {}
		vim.notify = function(msg, level)
			table.insert(_G._notifications, { msg = msg, level = level })
		end

		vim.env.PI_BRIDGE_TESTING = '1'
		vim.env.ENV_TEST_SOCKET_PATH = %q
		require('pi-bridge').setup({ auto_launch = false })
		require('pi-bridge').prompt({ text = 'setup' })
		vim.wait(1500, function()
			return require('pi-bridge.socket').is_connected()
		end, 30)
	]], path, path))

	expect.equality(child.lua("return require('pi-bridge.socket').is_connected()"), true)

	-- Simulate the VimLeavePre autocmd handler: explicit local
	-- disconnect(). Must NOT produce a "pi session disconnected"
	-- notification.
	child.lua([[
		require('pi-bridge.socket').disconnect()
		vim.wait(100, function() return not require('pi-bridge.socket').is_connected() end, 20)
	]])
	vim.uv.sleep(200)

	local saw_disconnect = false
	local notifications = child.lua("return _G._notifications or {}")
	for _, n in ipairs(notifications) do
		if n.msg and n.msg:match("pi session disconnected") then
			saw_disconnect = true
			break
		end
	end
	expect.equality(saw_disconnect, false)

	child.lua("_G._test_server.stop()")
	helpers.rmdir(dir)
end

return T
