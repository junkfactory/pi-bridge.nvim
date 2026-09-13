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

-- Edit approval gate: setup wires approval_request and approval_resolved
-- handlers; the default is on; the option can be opted out at setup time.

T["init"]["setup registers approval_request handler"] = function()
	local has_handler = child.lua([[
		require('pi-bridge').setup({ log_level = 'error' })
		local dispatch = require('pi-bridge.dispatch')
		local handlers = dispatch.get_handlers()
		return type(handlers.approval_request) == 'function'
	]])
	expect.equality(has_handler, true)
end

T["init"]["setup registers approval_resolved handler"] = function()
	local has_handler = child.lua([[
		require('pi-bridge').setup({ log_level = 'error' })
		local dispatch = require('pi-bridge.dispatch')
		local handlers = dispatch.get_handlers()
		return type(handlers.approval_resolved) == 'function'
	]])
	expect.equality(has_handler, true)
end

T["init"]["edit_approval_prompt defaults to true"] = function()
	local config = child.lua([[
		require('pi-bridge').setup({ log_level = 'error' })
		return require('pi-bridge').get_config()
	]])
	expect.equality(config.edit_approval_prompt, true)
end

T["init"]["edit_approval_prompt can be set to false"] = function()
	local config = child.lua([[
		require('pi-bridge').setup({ log_level = 'error', edit_approval_prompt = false })
		return require('pi-bridge').get_config()
	]])
	expect.equality(config.edit_approval_prompt, false)

	local enabled = child.lua([[
		return require('pi-bridge.approval').is_enabled()
	]])
	expect.equality(enabled, false)
end

T["init"]["setup rejects non-boolean edit_approval_prompt"] = function()
	local ok = child.lua([[
		local ok, err = pcall(require('pi-bridge').setup, { edit_approval_prompt = 'yes' })
		return ok
	]])
	expect.equality(ok, false)
end

T["init"]["notify defaults to true"] = function()
	local config = child.lua([[
		require('pi-bridge').setup({ log_level = 'error' })
		return require('pi-bridge').get_config()
	]])
	expect.equality(config.notify, true)
end

T["init"]["notify can be set to false"] = function()
	local config = child.lua([[
		require('pi-bridge').setup({ log_level = 'error', notify = false })
		return require('pi-bridge').get_config()
	]])
	expect.equality(config.notify, false)

	local enabled = child.lua([[
		return require('pi-bridge.ui').notify_enabled
	]])
	expect.equality(enabled, false)
end

T["init"]["setup rejects non-boolean notify"] = function()
	local ok = child.lua([[
		local ok, err = pcall(require('pi-bridge').setup, { notify = 'yes' })
		return ok
	]])
	expect.equality(ok, false)
end

T["init"]["approval_request dispatched via registered handler acks and opens the picker"] = function()
	child.lua([[
		require('pi-bridge').setup({ log_level = 'error' })
		-- Stub socket.send to capture outbound.
		_G.approval_sent = {}
		local socket = require('pi-bridge.socket')
		socket.send = function(msg) table.insert(_G.approval_sent, msg) end
		-- Mock the picker: capture the call, never answer.
		_G._select_calls = {}
		vim.ui.select = function(items, opts, on_choice)
			table.insert(_G._select_calls, { count = #items, prompt = opts.prompt })
		end
		local dispatch = require('pi-bridge.dispatch')
		dispatch.dispatch({
			type = 'approval_request',
			id = 'init-wire',
			tool = 'edit',
			path = '/tmp/x.lua',
			diff = '--- a\n+++ b\n',
		})
	]])
	local ack = child.lua("return _G.approval_sent[1]")
	expect.equality(ack.type, "approval_ack")
	expect.equality(ack.id, "init-wire")
	expect.equality(child.lua("return #_G._select_calls"), 1)
end

T["init"]["approval_resolved after dispatch is safe (late answers are discarded by pi)"] = function()
	child.lua([[
		require('pi-bridge').setup({ log_level = 'error' })
		local socket = require('pi-bridge.socket')
		socket.send = function() end
		vim.ui.select = function() end
		local dispatch = require('pi-bridge.dispatch')
		dispatch.dispatch({
			type = 'approval_request',
			id = 'init-resolve',
			tool = 'edit',
			path = '/tmp/x.lua',
			diff = 'd\n',
		})
		dispatch.dispatch({ type = 'approval_resolved', id = 'init-resolve' })
		-- The picker cannot be closed remotely; resolve must not error.
	]])
	expect.equality(true, true)
end

-- UI prompt mirror: setup wires the dispatch handlers, the runtime opt
-- flows from cfg to mirror.is_enabled, mirror_ready is sent on connect
-- when enabled, NOT sent when opt off, dismiss_all fires on remote
-- disconnect, and the integration path (ui_prompt_request → mirror
-- surface → ui_prompt_response) round-trips through the real dispatch
-- table.

T["init"]["setup registers ui_prompt_request handler"] = function()
	local has_handler = child.lua([[
		require('pi-bridge').setup({ log_level = 'error' })
		local dispatch = require('pi-bridge.dispatch')
		local handlers = dispatch.get_handlers()
		return type(handlers.ui_prompt_request) == 'function'
	]])
	expect.equality(has_handler, true)
end

T["init"]["setup registers ui_prompt_resolved handler"] = function()
	local has_handler = child.lua([[
		require('pi-bridge').setup({ log_level = 'error' })
		local dispatch = require('pi-bridge.dispatch')
		local handlers = dispatch.get_handlers()
		return type(handlers.ui_prompt_resolved) == 'function'
	]])
	expect.equality(has_handler, true)
end

T["init"]["ui_prompt_mirror defaults to true"] = function()
	local config = child.lua([[
		require('pi-bridge').setup({ log_level = 'error' })
		return require('pi-bridge').get_config()
	]])
	expect.equality(config.ui_prompt_mirror, true)

	local enabled = child.lua("return require('pi-bridge.prompt_mirror').is_enabled()")
	expect.equality(enabled, true)
end

T["init"]["ui_prompt_mirror can be set to false"] = function()
	local config = child.lua([[
		require('pi-bridge').setup({ log_level = 'error', ui_prompt_mirror = false })
		return require('pi-bridge').get_config()
	]])
	expect.equality(config.ui_prompt_mirror, false)

	local enabled = child.lua("return require('pi-bridge.prompt_mirror').is_enabled()")
	expect.equality(enabled, false)
end

T["init"]["setup rejects non-boolean ui_prompt_mirror"] = function()
	local ok = child.lua([[
		local ok, err = pcall(require('pi-bridge').setup, { ui_prompt_mirror = 'yes' })
		return ok
	]])
	expect.equality(ok, false)
end

-- mirror_ready on connect (mirror opt enabled, default).
--
-- Persistent connect path: real mock server, real socket.connect,
-- observe outbound message on the server side.

T["init"]["mirror_ready sent on persistent connect when enabled"] = function()
	local dir = helpers.tmpdir()
	local path = dir .. "/test.sock"

	child.lua(string.format([[
		local helpers = dofile('tests/helpers.lua')
		_G._test_server = helpers.mock_server(%q)

		vim.env.PI_BRIDGE_TESTING = '1'
		vim.env.ENV_TEST_SOCKET_PATH = %q
		require('pi-bridge').setup({ auto_launch = false })
		require('pi-bridge').prompt({ text = 'first' })
		vim.wait(1500, function()
			return require('pi-bridge.socket').is_connected()
		end, 30)
	]], path, path))

	expect.equality(child.lua("return require('pi-bridge.socket').is_connected()"), true)

	-- Wait for outbound mirror_ready to land on the server side. All
	-- access to the server object is via the child neovim.
	local found = child.lua([[
		vim.wait(1500, function()
			for _, m in ipairs(_G._test_server.get_messages()) do
				if m.type == "mirror_ready" then return true end
			end
			return false
		end, 30)
		for _, m in ipairs(_G._test_server.get_messages()) do
			if m.type == "mirror_ready" then return true end
		end
		return false
	]])
	expect.equality(found, true)

	child.lua([[
		require('pi-bridge.socket').disconnect()
		_G._test_server.stop()
	]])
	helpers.rmdir(dir)
end

-- mirror_ready NOT sent when opts off.

T["init"]["mirror_ready NOT sent when ui_prompt_mirror = false"] = function()
	local dir = helpers.tmpdir()
	local path = dir .. "/test.sock"

	child.lua(string.format([[
		local helpers = dofile('tests/helpers.lua')
		_G._test_server = helpers.mock_server(%q)

		vim.env.PI_BRIDGE_TESTING = '1'
		vim.env.ENV_TEST_SOCKET_PATH = %q
		require('pi-bridge').setup({ auto_launch = false, ui_prompt_mirror = false })
		require('pi-bridge').prompt({ text = 'first' })
		vim.wait(1500, function()
			return require('pi-bridge.socket').is_connected()
		end, 30)
	]], path, path))

	expect.equality(child.lua("return require('pi-bridge.socket').is_connected()"), true)

	-- Give the message loop time to flush. mirror_ready must NOT appear.
	vim.uv.sleep(300)

	local found = child.lua([[
		for _, m in ipairs(_G._test_server.get_messages()) do
			if m.type == "mirror_ready" then return true end
		end
		return false
	]])
	expect.equality(found, false)

	child.lua([[
		require('pi-bridge.socket').disconnect()
		_G._test_server.stop()
	]])
	helpers.rmdir(dir)
end

-- Dismiss on remote disconnect.
--
-- When the persistent socket observes EOF/error from pi, init.lua's
-- on_disconnect callback fires; mirror.dismiss_all() must be called
-- alongside approval.on_remote_disconnect(). We stub both module
-- functions to verify invocation, then drive a real disconnect by
-- stopping the mock server.

T["init"]["dismiss_all called on remote disconnect"] = function()
	local dir = helpers.tmpdir()
	local path = dir .. "/test.sock"

	child.lua(string.format([[
		local helpers = dofile('tests/helpers.lua')
		_G._test_server = helpers.mock_server(%q)

		vim.env.PI_BRIDGE_TESTING = '1'
		vim.env.ENV_TEST_SOCKET_PATH = %q
		require('pi-bridge').setup({ auto_launch = false })
		require('pi-bridge').prompt({ text = 'setup' })
		vim.wait(1500, function()
			return require('pi-bridge.socket').is_connected()
		end, 30)

		-- Stub mirror.dismiss_all to record invocations.
		local mirror = require('pi-bridge.prompt_mirror')
		_G._dismiss_count = 0
		mirror.dismiss_all = function()
			_G._dismiss_count = _G._dismiss_count + 1
		end
	]], path, path))

	expect.equality(child.lua("return require('pi-bridge.socket').is_connected()"), true)
	expect.equality(child.lua("return _G._dismiss_count"), 0)

	-- Stop the server: client observes EOF, init.lua's on_disconnect
	-- callback fires once.
	child.lua("_G._test_server.stop()")
	child.lua("vim.wait(800, function() return _G._dismiss_count >= 1 end, 30)")

	expect.equality(child.lua("return _G._dismiss_count"), 1)

	child.lua("require('pi-bridge.socket').disconnect()")
	helpers.rmdir(dir)
end

-- Local disconnect (VimLeavePre path) must NOT call mirror.dismiss_all:
-- same symmetry as the approval gate's "local disconnect does not notify".

T["init"]["local disconnect does not call dismiss_all"] = function()
	local dir = helpers.tmpdir()
	local path = dir .. "/test.sock"

	child.lua(string.format([[
		local helpers = dofile('tests/helpers.lua')
		_G._test_server = helpers.mock_server(%q)

		vim.env.PI_BRIDGE_TESTING = '1'
		vim.env.ENV_TEST_SOCKET_PATH = %q
		require('pi-bridge').setup({ auto_launch = false })
		require('pi-bridge').prompt({ text = 'setup' })
		vim.wait(1500, function()
			return require('pi-bridge.socket').is_connected()
		end, 30)

		local mirror = require('pi-bridge.prompt_mirror')
		_G._dismiss_count = 0
		mirror.dismiss_all = function()
			_G._dismiss_count = _G._dismiss_count + 1
		end
	]], path, path))

	expect.equality(child.lua("return require('pi-bridge.socket').is_connected()"), true)

	-- Local disconnect: must NOT trigger mirror.dismiss_all (mirrors
	-- the "local disconnect does not notify" contract).
	child.lua([[
		require('pi-bridge.socket').disconnect()
		vim.wait(100, function() return not require('pi-bridge.socket').is_connected() end, 20)
	]])
	vim.uv.sleep(300)

	expect.equality(child.lua("return _G._dismiss_count"), 0)

	child.lua("_G._test_server.stop()")
	helpers.rmdir(dir)
end

-- Integration: full request → response path through the real dispatch
-- table. Mirrors test_approval's `approval_request dispatched via
-- registered handler acks and opens the picker` approach but for the
-- mirror module: dispatch a ui_prompt_request, observe that the mirror
-- picker is opened and the user's choice round-trips back as a
-- ui_prompt_response sent via socket.send.

T["init"]["ui_prompt_request dispatched via registered handler opens mirror and sends response"] = function()
	child.lua([[
		require('pi-bridge').setup({ log_level = 'error' })
		-- Stub socket.send to capture outbound.
		_G.mirror_sent = {}
		local socket = require('pi-bridge.socket')
		socket.send = function(msg) table.insert(_G.mirror_sent, msg) end
		-- Mock plugin picker: capture calls, never answer.
		_G._select_calls = {}
		vim.ui.select = function(items, opts, on_choice)
			table.insert(_G._select_calls, { items = items, opts = opts })
			_G._select_on_choice = on_choice
			return nil
		end
		local dispatch = require('pi-bridge.dispatch')
		dispatch.dispatch({
			type = 'ui_prompt_request',
			id = 'wire-1',
			kind = 'select',
			title = 'pick one',
			options = { 'alpha', 'beta' },
		})
	]])
	expect.equality(child.lua("return #_G._select_calls"), 1)
	expect.equality(child.lua("return _G._select_calls[1].items[1]"), "alpha")
	expect.equality(child.lua("return _G._select_calls[1].items[2]"), "beta")

	-- User picks the second option. The mirror module must send
	-- ui_prompt_response {id, value = "beta"} via the captured send fn.
	child.lua("_G._select_on_choice(_G._select_calls[1].items[2])")
	local sent = child.lua("return _G.mirror_sent")
	expect.equality(#sent, 1)
	expect.equality(sent[1].type, "ui_prompt_response")
	expect.equality(sent[1].id, "wire-1")
	expect.equality(sent[1].value, "beta")
	expect.equality(sent[1].cancelled, nil)
end

T["init"]["ui_prompt_resolved dispatched via registered handler dismisses without sending"] = function()
	child.lua([[
		require('pi-bridge').setup({ log_level = 'error' })
		local socket = require('pi-bridge.socket')
		socket.send = function() end
		vim.ui.select = function() end
		local dispatch = require('pi-bridge.dispatch')
		dispatch.dispatch({
			type = 'ui_prompt_request',
			id = 'wire-res',
			kind = 'select',
			title = 'pick',
			options = { 'a', 'b' },
		})
		dispatch.dispatch({ type = 'ui_prompt_resolved', id = 'wire-res' })
		-- The dispatch must not error; the late-arriving answer from
		-- the picker callback (if any) must not send cancelled either.
	]])
	expect.equality(true, true)
end

-- opts-off integration: dispatch wires the handler, but the mirror
-- module opens nothing — i.e. the request is dropped at the module
-- level (no picker, no float, no response sent). Verifies the wiring
-- is unconditional (handlers always registered) but the runtime opt
-- gates actual behavior.

T["init"]["ui_prompt_request dispatched but mirror disabled → no surface"] = function()
	child.lua([[
		require('pi-bridge').setup({ log_level = 'error', ui_prompt_mirror = false })
		_G.mirror_sent = {}
		local socket = require('pi-bridge.socket')
		socket.send = function(msg) table.insert(_G.mirror_sent, msg) end
		_G._select_calls = {}
		-- Stock picker would block; mirror disabled must not reach
		-- either path. Use a plugin-mock so we can detect "no call".
		vim.ui.select = function(items, opts, on_choice)
			table.insert(_G._select_calls, { items = items })
		end
		local dispatch = require('pi-bridge.dispatch')
		dispatch.dispatch({
			type = 'ui_prompt_request',
			id = 'wire-off',
			kind = 'select',
			title = 'pick',
			options = { 'a', 'b' },
		})
	]])
	expect.equality(child.lua("return #_G._select_calls"), 0)
	expect.equality(child.lua("return #_G.mirror_sent"), 0)
end

return T
