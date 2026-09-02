local MiniTest = require("mini.test")
local expect = MiniTest.expect
local helpers = dofile("tests/helpers.lua")

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set()

T["socket"] = MiniTest.new_set({
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

T["socket"]["connect to valid socket"] = function()
	local dir = helpers.tmpdir()
	local path = dir .. "/test.sock"
	local server = helpers.mock_server(path)

	child.lua(string.format(
		"require('pi-bridge.socket').connect(%q, function() end)",
		path
	))
	vim.uv.sleep(200)

	local connected = child.lua("return require('pi-bridge.socket').is_connected()")
	expect.equality(connected, true)

	child.lua("require('pi-bridge.socket').disconnect()")
	server.stop()
	helpers.rmdir(dir)
end

T["socket"]["connect to nonexistent socket"] = function()
	child.lua([[
		require('pi-bridge.socket').connect('/nonexistent/path.sock', function() end)
	]])
	vim.uv.sleep(300)
	local connected = child.lua("return require('pi-bridge.socket').is_connected()")
	expect.equality(connected, false)
end

T["socket"]["send delivers message to server"] = function()
	local dir = helpers.tmpdir()
	local path = dir .. "/test.sock"
	local server = helpers.mock_server(path)

	child.lua(string.format(
		"require('pi-bridge.socket').connect(%q, function() end)",
		path
	))
	vim.uv.sleep(200)

	child.lua([[
		require('pi-bridge.socket').send({
			type = 'prompt',
			text = 'hello from nvim',
			context = { file = '/tmp/test.lua', cwd = '/tmp', content = 'code', mode = 'normal' },
		})
	]])
	vim.uv.sleep(200)

	local messages = server.get_messages()
	expect.equality(#messages >= 1, true)
	expect.equality(messages[1].type, "prompt")
	expect.equality(messages[1].text, "hello from nvim")
	expect.equality(messages[1].context.file, "/tmp/test.lua")

	child.lua("require('pi-bridge.socket').disconnect()")
	server.stop()
	helpers.rmdir(dir)
end

T["socket"]["receives NDJSON from server"] = function()
	local dir = helpers.tmpdir()
	local path = dir .. "/test.sock"
	local server = helpers.mock_server(path)

	child.lua(string.format(
		[[
		_G.test_messages = {}
		require('pi-bridge.socket').connect(%q, function(msg)
			table.insert(_G.test_messages, msg)
		end)
		]],
		path
	))
	vim.uv.sleep(200)

	server.send({ type = "agent_start", data = "test" })
	vim.uv.sleep(200)

	local messages = child.lua("return _G.test_messages")
	expect.equality(#messages >= 1, true)
	expect.equality(messages[1].type, "agent_start")

	child.lua("require('pi-bridge.socket').disconnect()")
	server.stop()
	helpers.rmdir(dir)
end

T["socket"]["handles partial NDJSON frames"] = function()
	local dir = helpers.tmpdir()
	local path = dir .. "/test.sock"
	local server = helpers.mock_server(path)

	child.lua(string.format(
		[[
		_G.test_messages = {}
		require('pi-bridge.socket').connect(%q, function(msg)
			table.insert(_G.test_messages, msg)
		end)
		]],
		path
	))
	vim.uv.sleep(200)

	-- send partial frame via server's raw write
	server.send_raw('{"type":"partial"')
	vim.uv.sleep(100)
	-- send remainder
	server.send_raw(',"data":"ok"}\n')
	vim.uv.sleep(200)

	local messages = child.lua("return _G.test_messages")
	expect.equality(#messages >= 1, true)
	expect.equality(messages[1].type, "partial")
	expect.equality(messages[1].data, "ok")

	child.lua("require('pi-bridge.socket').disconnect()")
	server.stop()
	helpers.rmdir(dir)
end

T["socket"]["disconnect cleans up state"] = function()
	local dir = helpers.tmpdir()
	local path = dir .. "/test.sock"
	local server = helpers.mock_server(path)

	child.lua(string.format(
		"require('pi-bridge.socket').connect(%q, function() end)",
		path
	))
	vim.uv.sleep(200)

	child.lua("require('pi-bridge.socket').disconnect()")
	local connected = child.lua("return require('pi-bridge.socket').is_connected()")
	expect.equality(connected, false)

	server.stop()
	helpers.rmdir(dir)
end

T["socket"]["send returns false when not connected"] = function()
	local ok = child.lua([[
		return require('pi-bridge.socket').send({ type = 'test' })
	]])
	expect.equality(ok, false)
end

T["socket"]["reconnect after disconnect"] = function()
	local dir = helpers.tmpdir()
	local path = dir .. "/test.sock"
	local server = helpers.mock_server(path)

	child.lua(string.format(
		"require('pi-bridge.socket').connect(%q, function() end)",
		path
	))
	vim.uv.sleep(200)
	child.lua("require('pi-bridge.socket').disconnect()")

	child.lua(string.format(
		"require('pi-bridge.socket').connect(%q, function() end)",
		path
	))
	vim.uv.sleep(200)
	local connected = child.lua("return require('pi-bridge.socket').is_connected()")
	expect.equality(connected, true)

	child.lua("require('pi-bridge.socket').disconnect()")
	server.stop()
	helpers.rmdir(dir)
end

-- Remote disconnect callback
--
-- EOF on the read pipe indicates the peer closed the connection
-- unexpectedly. The on_disconnect callback fires once for that event;
-- an explicit local disconnect() does not fire it. A subsequent
-- remote EOF after a manual reconnect is a fresh event.

T["socket"]["on_disconnect fires on remote EOF"] = function()
	local dir = helpers.tmpdir()
	local path = dir .. "/test.sock"
	local server = helpers.mock_server(path)

	child.lua(string.format(
		[[
		_G._disconnect_count = 0
		require('pi-bridge.socket').connect(%q, function() end, function()
			_G._disconnect_count = _G._disconnect_count + 1
		end)
		]],
		path
	))
	vim.uv.sleep(200)
	expect.equality(child.lua("return _G._disconnect_count"), 0)

	-- Stop the server side: client observes EOF on its read pipe.
	server.stop()
	vim.uv.sleep(300)

	expect.equality(child.lua("return _G._disconnect_count"), 1)
	expect.equality(child.lua("return require('pi-bridge.socket').is_connected()"), false)

	helpers.rmdir(dir)
end

T["socket"]["on_disconnect does not fire on local disconnect"] = function()
	local dir = helpers.tmpdir()
	local path = dir .. "/test.sock"
	local server = helpers.mock_server(path)

	child.lua(string.format(
		[[
		_G._disconnect_count = 0
		require('pi-bridge.socket').connect(%q, function() end, function()
			_G._disconnect_count = _G._disconnect_count + 1
		end)
		]],
		path
	))
	vim.uv.sleep(200)

	-- Local disconnect must NOT trigger the remote-disconnect callback.
	child.lua("require('pi-bridge.socket').disconnect()")
	vim.uv.sleep(200)

	expect.equality(child.lua("return _G._disconnect_count"), 0)

	server.stop()
	helpers.rmdir(dir)
end

T["socket"]["on_disconnect fires exactly once per connection loss"] = function()
	local dir = helpers.tmpdir()
	local path = dir .. "/test.sock"
	local server = helpers.mock_server(path)

	child.lua(string.format(
		[[
		_G._disconnect_count = 0
		require('pi-bridge.socket').connect(%q, function() end, function()
			_G._disconnect_count = _G._disconnect_count + 1
		end)
		]],
		path
	))
	vim.uv.sleep(200)

	-- Stop the server, then wait long enough for both EOF and any
	-- follow-up callbacks to land. The guard inside socket.lua must
	-- keep the counter at exactly 1.
	server.stop()
	vim.uv.sleep(500)

	expect.equality(child.lua("return _G._disconnect_count"), 1)

	helpers.rmdir(dir)
end

T["socket"]["on_disconnect optional argument is backward compatible"] = function()
	local dir = helpers.tmpdir()
	local path = dir .. "/test.sock"
	local server = helpers.mock_server(path)

	-- Old call shape: only path + on_message. Must still work.
	child.lua(string.format(
		"require('pi-bridge.socket').connect(%q, function() end)",
		path
	))
	vim.uv.sleep(200)
	expect.equality(child.lua("return require('pi-bridge.socket').is_connected()"), true)

	server.stop()
	vim.uv.sleep(200)
	expect.equality(child.lua("return require('pi-bridge.socket').is_connected()"), false)

	helpers.rmdir(dir)
end

return T
