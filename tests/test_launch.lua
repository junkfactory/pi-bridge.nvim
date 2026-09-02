local MiniTest = require("mini.test")
local expect = MiniTest.expect

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set()

T["launch"] = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.start({ "-u", "scripts/minimal_init.lua" })
			child.lua("MiniTest = require('mini.test')")
		end,
		post_case = function()
			-- best-effort cleanup of any test server still running in child
			local cleanup_ok, cleanup_err = pcall(function()
				child.lua([[
					if _G._test_server then _G._test_server.stop(); _G._test_server = nil end
				]])
			end)
			if not cleanup_ok then
				print("cleanup error:", cleanup_err)
			end
			child.stop()
		end,
	},
})

-- Spawn a mock server inside the child and return the path.
-- The mock server runs in the child's libuv loop, so its accept callback
-- fires regardless of parent activity.
local function spawn_mock_at_socket_path()
	local path = child.lua([[
		local helpers = dofile('tests/helpers.lua')
		-- mirror the path init.lua computes
		local cwd = vim.fn.getcwd()
		local hash = vim.fn.sha256(cwd)
		local path = vim.fn.expand('~/.pi/agent/pi-bridge/sockets/') .. hash .. '.sock'
		vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
		local server = helpers.mock_server(path)
		_G._test_server = server
		return path
	]])
	return path
end

-- is_pi_split_valid

T["launch"]["is_pi_split_valid returns false initially"] = function()
	child.lua("require('pi-bridge').setup({ auto_launch = false })")
	local valid = child.lua([[
		return require('pi-bridge.launch').is_pi_split_valid()
	]])
	expect.equality(valid, false)
end

-- prompt_launch: user declines (sync — no polling needed)

T["launch"]["user declines returns false, no split opened"] = function()
	child.lua([[
		require('pi-bridge').setup({ auto_launch = true, launch_timeout = 1 })
		_G._orig_ui_select = vim.ui.select
		_G._orig_cmd = vim.cmd
		vim.ui.select = function(items, opts, on_choice) on_choice(items[2]) end
		vim.cmd = function() _G._cmd_called = true end
		_G._cmd_called = false

		_G._result = nil
		require('pi-bridge.launch').prompt_launch(
			require('pi-bridge').get_config(),
			'/tmp/pi-bridge-decline.sock',
			function(ok) _G._result = ok end
		)
		vim.wait(300, function() return _G._result ~= nil end, 20)
	]])

	local result = child.lua("return { result = _G._result, cmd_called = _G._cmd_called }")
	expect.equality(result.result, false)
	expect.equality(result.cmd_called, false)
end

-- prompt_launch: user accepts, socket ready (mock server runs in child)

T["launch"]["user accepts with socket ready returns true"] = function()
	local path = spawn_mock_at_socket_path()

	child.lua(string.format([[
		require('pi-bridge').setup({ auto_launch = true, launch_timeout = 2 })
		vim.ui.select = function(items, opts, on_choice) on_choice(items[1]) end
		vim.cmd = function() end
		_G._result = nil
		require('pi-bridge.launch').prompt_launch(
			require('pi-bridge').get_config(),
			%q,
			function(ok) _G._result = ok end
		)
		vim.wait(1500, function() return _G._result ~= nil end, 50)
	]], path))

	local result = child.lua("return _G._result")
	expect.equality(result, true)
end

-- prompt_launch: timeout

T["launch"]["timeout returns false when socket never appears"] = function()
	child.lua([[
		require('pi-bridge').setup({ auto_launch = true, launch_timeout = 0.2 })
		vim.ui.select = function(items, opts, on_choice) on_choice(items[1]) end
		vim.cmd = function() end
		_G._result = nil
		require('pi-bridge.launch').prompt_launch(
			require('pi-bridge').get_config(),
			'/tmp/pi-bridge-never-appears.sock',
			function(ok) _G._result = ok end
		)
		vim.wait(1500, function() return _G._result ~= nil end, 50)
	]])

	expect.equality(child.lua("return _G._result"), false)
end

-- prompt_launch: queues concurrent calls (single mock server)

T["launch"]["concurrent calls both receive the same result"] = function()
	local path = spawn_mock_at_socket_path()

	child.lua(string.format([[
		require('pi-bridge').setup({ auto_launch = true, launch_timeout = 2 })
		vim.ui.select = function(items, opts, on_choice) on_choice(items[1]) end
		vim.cmd = function() end
		_G._r1, _G._r2 = nil, nil
		local function cb(name)
			return function(ok)
				if name == 'a' then _G._r1 = ok else _G._r2 = ok end
			end
		end
		require('pi-bridge.launch').prompt_launch(
			require('pi-bridge').get_config(), %q, cb('a')
		)
		require('pi-bridge.launch').prompt_launch(
			require('pi-bridge').get_config(), %q, cb('b')
		)
		vim.wait(1500, function() return _G._r1 ~= nil and _G._r2 ~= nil end, 50)
	]], path, path))

	local results = child.lua("return { r1 = _G._r1, r2 = _G._r2 }")
	expect.equality(results.r1, true)
	expect.equality(results.r2, true)
end

-- ensure_connection integration: socket already exists → connect succeeds → send fires

T["launch"]["ensure_connection sends on existing socket without launch"] = function()
	local path = spawn_mock_at_socket_path()

	child.lua(string.format([[
		require('pi-bridge').setup({ auto_launch = true, launch_timeout = 2 })
		vim.ui.select = function(items, opts, on_choice)
			_G._ui_called = true
			on_choice(items[1])
		end
		vim.cmd = function() end
		_G._ui_called = false
		_G._sent_msg = nil
		local s = require('pi-bridge.socket')
		s.send = function(msg) _G._sent_msg = msg; return true end
		require('pi-bridge').prompt({ text = 'hello world' })
		vim.wait(2000, function() return _G._sent_msg ~= nil end, 50)
	]], path))

	local sent = child.lua("return _G._sent_msg")
	expect.equality(type(sent), "table")
	expect.equality(sent.type, "prompt")
	expect.equality(sent.text, "hello world")
	-- UI should NOT be called because connect succeeded on first try
	expect.equality(child.lua("return _G._ui_called"), false)
end

-- ensure_connection integration: socket doesn't exist, launch triggers, then send fires

T["launch"]["ensure_connection launches then connects and sends"] = function()
	-- No pre-existing socket. auto_launch=true. After launch is triggered,
	-- a delayed mock server starts listening at the expected socket path
	-- so the retry connect succeeds. We stub vim.cmd to avoid actually
	-- opening a terminal — the "launch" is effectively a no-op, but the
	-- poll timer fires and sees the mock server's socket file.
	child.lua([[
		require('pi-bridge').setup({ auto_launch = true, launch_timeout = 3 })
		vim.cmd = function() end
		vim.ui.select = function(items, opts, on_choice) on_choice(items[1]) end
		_G._sent_msg = nil
		local s = require('pi-bridge.socket')
		s.send = function(msg) _G._sent_msg = msg; return true end

		-- compute the socket path we'll fake
		local sock = vim.fn.expand('~/.pi/agent/pi-bridge/sockets/')
			.. vim.fn.sha256(vim.fn.getcwd()) .. '.sock'
		vim.fn.mkdir(vim.fn.fnamemodify(sock, ':h'), 'p')

		-- start a delayed mock server that will create the socket file
		-- after a short delay (mimicking pi startup time)
		vim.defer_fn(function()
			local helpers = dofile('tests/helpers.lua')
			_G._test_server2 = helpers.mock_server(sock)
		end, 400)

		require('pi-bridge').prompt({ text = 'launch me' })
		vim.wait(4000, function() return _G._sent_msg ~= nil end, 50)
	]])

	local sent = child.lua("return _G._sent_msg")
	expect.equality(type(sent), "table")
	expect.equality(sent.text, "launch me")
end

-- ensure_connection integration: skips launch when auto_launch = false

T["launch"]["ensure_connection skips launch when auto_launch is false"] = function()
	child.lua([[
		require('pi-bridge').setup({ auto_launch = false })
		vim.ui.select = function(items, opts, on_choice)
			_G._ui_called = true
			on_choice(items[1])
		end
		vim.cmd = function() end
		_G._ui_called = false
		_G._sent_msg = nil
		local s = require('pi-bridge.socket')
		s.send = function(msg) _G._sent_msg = msg; return true end
		require('pi-bridge').prompt({ text = 'test' })
		vim.wait(1500, function() return _G._ui_called or _G._sent_msg ~= nil end, 50)
	]])

	local result = child.lua([[
		return { ui_called = _G._ui_called, sent = _G._sent_msg }
	]])

	expect.equality(result.ui_called, false)
	expect.equality(result.sent, nil)
end

return T
