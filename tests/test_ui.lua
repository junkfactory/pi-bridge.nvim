local MiniTest = require("mini.test")
local expect = MiniTest.expect

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set()

T["ui"] = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.start({ "-u", "scripts/minimal_init.lua" })
			child.lua("MiniTest = require('mini.test')")
			child.lua("require('pi-bridge.ui')")
		end,
		post_case = function()
			child.stop()
		end,
	},
})

T["ui"]["notify sends prefixed message"] = function()
	child.lua([[
		_G.notifications = {}
		vim.notify = function(msg, level)
			table.insert(_G.notifications, { msg = msg, level = level })
		end
		require('pi-bridge.ui').notify('test message')
	]])
	local notifs = child.lua("return _G.notifications")
	expect.equality(#notifs, 1)
	expect.equality(notifs[1].msg, "pi-bridge: test message")
	expect.equality(notifs[1].level, vim.log.levels.INFO)
end

T["ui"]["notify respects custom level"] = function()
	child.lua([[
		_G.notifications = {}
		vim.notify = function(msg, level)
			table.insert(_G.notifications, { msg = msg, level = level })
		end
		require('pi-bridge.ui').notify('warn msg', vim.log.levels.WARN)
	]])
	local notifs = child.lua("return _G.notifications")
	expect.equality(#notifs, 1)
	expect.equality(notifs[1].msg, "pi-bridge: warn msg")
	expect.equality(notifs[1].level, vim.log.levels.WARN)
end

T["ui"]["on_agent_start shows notification"] = function()
	child.lua([[
		_G.notifications = {}
		vim.notify = function(msg, level)
			table.insert(_G.notifications, { msg = msg, level = level })
		end
		require('pi-bridge.ui').on_agent_start({ type = 'agent_start', message = 'thinking...' })
	]])
	local notifs = child.lua("return _G.notifications")
	expect.equality(#notifs, 1)
	expect.equality(notifs[1].msg:find("thinking%.%.%.") ~= nil, true)
	expect.equality(notifs[1].msg:find("▸") ~= nil, true)
end

T["ui"]["on_agent_start uses default message when empty"] = function()
	child.lua([[
		_G.notifications = {}
		vim.notify = function(msg, level)
			table.insert(_G.notifications, msg)
		end
		require('pi-bridge.ui').on_agent_start({ type = 'agent_start' })
	]])
	local notifs = child.lua("return _G.notifications")
	expect.equality(#notifs, 1)
	expect.equality(notifs[1]:find("working%.%.%.") ~= nil, true)
end

T["ui"]["on_agent_end shows notification"] = function()
	child.lua([[
		_G.notifications = {}
		vim.notify = function(msg, level)
			table.insert(_G.notifications, { msg = msg, level = level })
		end
		require('pi-bridge.ui').on_agent_end({ type = 'agent_end', message = 'completed' })
	]])
	local notifs = child.lua("return _G.notifications")
	expect.equality(#notifs, 1)
	expect.equality(notifs[1].msg:find("completed") ~= nil, true)
	expect.equality(notifs[1].msg:find("▪") ~= nil, true)
end

T["ui"]["on_agent_end uses default message when empty"] = function()
	child.lua([[
		_G.notifications = {}
		vim.notify = function(msg, level)
			table.insert(_G.notifications, msg)
		end
		require('pi-bridge.ui').on_agent_end({ type = 'agent_end' })
	]])
	local notifs = child.lua("return _G.notifications")
	expect.equality(#notifs, 1)
	expect.equality(notifs[1]:find("done") ~= nil, true)
end

T["ui"]["on_file_edited highlights buffer for matching file"] = function()
	child.lua([[
		-- create a buffer with a known name
		local buf = vim.api.nvim_create_buf(true, false)
		local test_file = vim.fn.tempname() .. '.lua'
		vim.api.nvim_buf_set_name(buf, test_file)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'line1', 'line2', 'line3' })

		require('pi-bridge.ui').on_file_edited({ type = 'file_edited', file = test_file })

		-- check extmarks exist
		local ns = vim.api.nvim_create_namespace('pi-bridge')
		local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
		_G.mark_count = #marks
	]])
	local count = child.lua("return _G.mark_count")
	expect.equality(count, 3)
end

T["ui"]["on_file_edited does nothing for non-matching file"] = function()
	child.lua([[
		-- create a buffer with a different name
		local buf = vim.api.nvim_create_buf(true, false)
		local test_file = vim.fn.tempname() .. '.lua'
		vim.api.nvim_buf_set_name(buf, test_file)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'line1' })

		require('pi-bridge.ui').on_file_edited({ type = 'file_edited', file = '/tmp/nonexistent.lua' })

		local ns = vim.api.nvim_create_namespace('pi-bridge')
		local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
		_G.mark_count = #marks
	]])
	local count = child.lua("return _G.mark_count")
	expect.equality(count, 0)
end

T["ui"]["on_file_edited handles missing file field"] = function()
	child.lua([[
		-- should not error
		require('pi-bridge.ui').on_file_edited({ type = 'file_edited' })
	]])
end

return T
