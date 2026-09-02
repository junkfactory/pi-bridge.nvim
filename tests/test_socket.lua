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

return T
