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
	expect.equality(notifs[1].msg, "𝜋 test message")
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
	expect.equality(notifs[1].msg, "𝜋 warn msg")
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
	expect.equality(notifs[1].msg, "𝜋 thinking...")
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
	expect.equality(notifs[1].msg, "𝜋 completed")
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

T["ui"]["on_agent_end runs checktime after notification"] = function()
	child.lua([[
		_G.cmd_calls = {}
		vim.cmd = function(cmd)
			table.insert(_G.cmd_calls, cmd)
		end
		_G.notifications = {}
		vim.notify = function(msg, level)
			table.insert(_G.notifications, { msg = msg, level = level })
		end
		require('pi-bridge.ui').on_agent_end({ type = 'agent_end', message = 'done' })
	]])
	local calls = child.lua("return _G.cmd_calls")
	local notifs = child.lua("return _G.notifications")
	expect.equality(#notifs, 1)
	expect.equality(notifs[1].msg, "𝜋 done")
	expect.equality(calls[1], 'checktime')
end

T["ui"]["notify is suppressed when notify_enabled is false"] = function()
	child.lua([[
		_G.notifications = {}
		vim.notify = function(msg, level)
			table.insert(_G.notifications, { msg = msg, level = level })
		end
		local ui = require('pi-bridge.ui')
		ui.notify_enabled = false
		ui.notify('hidden message')
		ui.on_agent_start({ type = 'agent_start', message = 'working...' })
		ui.on_agent_end({ type = 'agent_end', message = 'done' })
		ui.notify_enabled = true
	]])
	local notifs = child.lua("return _G.notifications")
	expect.equality(#notifs, 0)
end

T["ui"]["on_agent_end still runs checktime when notify is disabled"] = function()
	child.lua([[
		_G.cmd_calls = {}
		vim.cmd = function(cmd)
			table.insert(_G.cmd_calls, cmd)
		end
		_G.notifications = {}
		vim.notify = function(msg, level)
			table.insert(_G.notifications, { msg = msg, level = level })
		end
		local ui = require('pi-bridge.ui')
		ui.notify_enabled = false
		ui.on_agent_end({ type = 'agent_end', message = 'done' })
		ui.notify_enabled = true
	]])
	child.lua("vim.wait(500)")
	local calls = child.lua("return _G.cmd_calls")
	local notifs = child.lua("return _G.notifications")
	expect.equality(#notifs, 0)
	expect.equality(calls[1], 'checktime')
end

T["ui"]["on_agent_end checktime reloads buffer from disk"] = function()
	local tmpfile = child.lua("return vim.fn.tempname()")
	child.lua(string.format([[
		local path = %q
		_G._test_tmpfile = path

		-- Write initial content
		vim.fn.writefile({ 'line1', 'line2' }, path)

		-- Load file into a buffer
		vim.cmd('edit ' .. vim.fn.fnameescape(path))
		local buf = vim.api.nvim_get_current_buf()
		vim.bo[buf].modified = false

		-- Sleep to ensure different mtime (filesystem second resolution)
		vim.uv.sleep(1100)

		-- Write new content out-of-band
		vim.fn.writefile({ 'line1', 'line2', 'line3' }, path)

		require('pi-bridge.ui').on_agent_end({ type = 'agent_end', message = 'done' })
	]], tmpfile))

	-- Let scheduled checktime run
	child.lua("vim.wait(500)")

	local lines = child.lua("return vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)")
	expect.equality(#lines, 3)
	expect.equality(lines[1], 'line1')
	expect.equality(lines[2], 'line2')
	expect.equality(lines[3], 'line3')

	-- cleanup
	child.lua("vim.fn.delete(_G._test_tmpfile)")
end

T["ui"]["on_error shows notification with ERROR level"] = function()
	child.lua([[
		_G.notifications = {}
		vim.notify = function(msg, level)
			table.insert(_G.notifications, { msg = msg, level = level })
		end
		require('pi-bridge.ui').on_error({ message = 'Failed to deliver message to pi', code = 'stale_context' })
	]])
	local notifs = child.lua("return _G.notifications")
	expect.equality(#notifs, 1)
	expect.equality(notifs[1].msg, "𝜋 Failed to deliver message to pi")
	expect.equality(notifs[1].level, vim.log.levels.ERROR)
end

-- Border accent resolver: each case resets PiBridgeFloatBorder so the
-- previous case's own definition does not leak in.
T["ui"]["border_hl links Comment when no snacks and no user override"] = function()
	child.lua("vim.api.nvim_set_hl(0, 'PiBridgeFloatBorder', {})")
	local name = child.lua("return require('pi-bridge.ui').border_hl()")
	expect.equality(name, "PiBridgeFloatBorder")
	local def = child.lua("return vim.api.nvim_get_hl(0, { name = 'PiBridgeFloatBorder' })")
	expect.equality(def.link, "Comment")
end

T["ui"]["border_hl follows the snacks border when its group is themed"] = function()
	child.lua("vim.api.nvim_set_hl(0, 'PiBridgeFloatBorder', {})")
	-- Simulate an active snacks: the group exists, themed by the colorscheme.
	child.lua("vim.api.nvim_set_hl(0, 'SnacksInputBorder', { fg = '#e0af68' })")
	child.lua("return require('pi-bridge.ui').border_hl()")
	local def = child.lua("return vim.api.nvim_get_hl(0, { name = 'PiBridgeFloatBorder' })")
	expect.equality(def.link, "SnacksInputBorder")
end

T["ui"]["border_hl leaves a user definition with concrete colors alone"] = function()
	child.lua("vim.api.nvim_set_hl(0, 'SnacksInputBorder', { fg = '#e0af68' })")
	child.lua("vim.api.nvim_set_hl(0, 'PiBridgeFloatBorder', { fg = '#ff0000' })")
	local name = child.lua("return require('pi-bridge.ui').border_hl()")
	expect.equality(name, "PiBridgeFloatBorder")
	local def = child.lua("return vim.api.nvim_get_hl(0, { name = 'PiBridgeFloatBorder' })")
	expect.equality(def.fg, 0xff0000)
	expect.equality(def.link, nil)
end

T["ui"]["border_hl resolves again when the user override is only a link"] = function()
	-- A bare link definition is not protected: it is re-resolved, so a
	-- colorscheme switch (or user link) between opens does not pin an
	-- old accent. Users who want a pinned accent set concrete colors.
	child.lua("vim.api.nvim_set_hl(0, 'PiBridgeFloatBorder', { default = true, link = 'Comment' })")
	child.lua("return require('pi-bridge.ui').border_hl()")
	local def = child.lua("return vim.api.nvim_get_hl(0, { name = 'PiBridgeFloatBorder' })")
	expect.equality(def.link, "Comment") -- fallback: no SnacksInputBorder in this child
end

T["ui"]["on_error uses default message when empty"] = function()
	child.lua([[
		_G.notifications = {}
		vim.notify = function(msg, level)
			table.insert(_G.notifications, { msg = msg, level = level })
		end
		require('pi-bridge.ui').on_error({})
	]])
	local notifs = child.lua("return _G.notifications")
	expect.equality(#notifs, 1)
	expect.equality(notifs[1].msg, "𝜋 delivery error")
	expect.equality(notifs[1].level, vim.log.levels.ERROR)
end

return T
