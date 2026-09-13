local MiniTest = require("mini.test")
local expect = MiniTest.expect

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set()

T["fallback-select"] = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.start({ "-u", "scripts/minimal_init.lua" })
			child.lua("MiniTest = require('mini.test')")
			child.lua("fsel = require('pi-bridge.fallback-select')")
			child.lua("require('pi-bridge.fallback-select')._reset()")
			-- Deterministic response capture.
			child.lua([[
				_G.approval_sent = {}
				_G.fake_send = function(msg) table.insert(_G.approval_sent, msg) end
			]])
		end,
		post_case = function()
			child.stop()
		end,
	},
})

local SHOW = [[
	fsel.show({ type='approval_request', id='%s', tool='edit', path='/tmp/example.lua', diff='x' }, fake_send)
]]

T["fallback-select"]["show opens the float and focuses it"] = function()
	child.lua(string.format(SHOW, "fs-1"))
	expect.equality(child.lua("return fsel.is_open()"), true)
	-- Float window is current (focus entered on open).
	expect.equality(
		child.lua("return vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).relative ~= ''"),
		true
	)
end

T["fallback-select"]["show renders the prompt and three choices"] = function()
	child.lua(string.format(SHOW, "fs-2"))
	local lines = child.lua("return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(vim.fn.bufwinid('^/tmp/example.lua$') ~= -1 and vim.api.nvim_win_get_buf(0) or 0), 0, -1, false)")
	-- Simpler: read the current window's buffer directly.
	lines = child.lua("return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(0), 0, -1, false)")
	expect.equality(#lines, 5)
	expect.equality(lines[1], "approve edit: /tmp/example.lua")
	expect.equality(lines[3], "y — approve this edit")
	expect.equality(lines[4], "a — approve all edits to this file (this session)")
	expect.equality(lines[5], "n — reject this edit")
end

T["fallback-select"]["prompt notes buffer-modified warning"] = function()
	child.lua([[
		local file = vim.fn.tempname() .. '.lua'
		vim.fn.writefile({ 'old' }, file)
		_G._fsel_target = file
		local buf = vim.fn.bufadd(file)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'dirty' })
	]])
	child.lua([[
		fsel.show({ type='approval_request', id='fs-warn', tool='edit', path=_G._fsel_target, diff='x' }, fake_send)
	]])
	local lines = child.lua("return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(0), 0, -1, false)")
	expect.equality(lines[1]:find("buffer has unsaved changes", 1, true) ~= nil, true)
end

T["fallback-select"]["'y' sends yes and closes"] = function()
	child.lua(string.format(SHOW, "fs-y"))
	child.lua("vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('y', true, false, true), 'x', false)")
	local sent = child.lua("return _G.approval_sent")
	expect.equality(#sent, 1)
	expect.equality(sent[1].type, "approval_response")
	expect.equality(sent[1].id, "fs-y")
	expect.equality(sent[1].decision, "yes")
	expect.equality(child.lua("return fsel.is_open()"), false)
end

T["fallback-select"]["'a' sends all"] = function()
	child.lua(string.format(SHOW, "fs-a"))
	child.lua("vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('a', true, false, true), 'x', false)")
	local sent = child.lua("return _G.approval_sent")
	expect.equality(#sent, 1)
	expect.equality(sent[1].decision, "all")
end

T["fallback-select"]["'n' sends no"] = function()
	child.lua(string.format(SHOW, "fs-n"))
	child.lua("vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('n', true, false, true), 'x', false)")
	local sent = child.lua("return _G.approval_sent")
	expect.equality(#sent, 1)
	expect.equality(sent[1].decision, "no")
end

T["fallback-select"]["Esc sends no (dismiss-as-reject)"] = function()
	child.lua(string.format(SHOW, "fs-esc"))
	child.lua("vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'x', false)")
	local sent = child.lua("return _G.approval_sent")
	expect.equality(#sent, 1)
	expect.equality(sent[1].decision, "no")
end

T["fallback-select"]["close() is silent: no response, no notification"] = function()
	child.lua(string.format(SHOW, "fs-close"))
	child.lua("fsel.close()")
	expect.equality(child.lua("return fsel.is_open()"), false)
	expect.equality(child.lua("return #_G.approval_sent"), 0)
end

T["fallback-select"]["close_silent notifies and sends nothing"] = function()
	child.lua(string.format(SHOW, "fs-silent"))
	child.lua([[
		_G._notified = {}
		vim.notify = function(msg, level)
			table.insert(_G._notified, { msg = msg, level = level })
		end
		fsel.close_silent("pi disconnected")
	]])
	expect.equality(child.lua("return fsel.is_open()"), false)
	expect.equality(child.lua("return #_G.approval_sent"), 0)
	local notified = child.lua("return _G._notified")
	expect.equality(#notified, 1)
	expect.equality(notified[1].msg, "pi-bridge: pi disconnected")
end

T["fallback-select"]["second show while open is ignored"] = function()
	child.lua(string.format(SHOW, "fs-dup1"))
	child.lua(string.format(SHOW, "fs-dup2"))
	-- Still the first request's float: answering resolves fs-dup1.
	child.lua("vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('y', true, false, true), 'x', false)")
	local sent = child.lua("return _G.approval_sent")
	expect.equality(#sent, 1)
	expect.equality(sent[1].id, "fs-dup1")
end

T["fallback-select"]["missing id is dropped without opening"] = function()
	child.lua("fsel.show({ type='approval_request', tool='edit', path='/tmp/x.lua' }, fake_send)")
	expect.equality(child.lua("return fsel.is_open()"), false)
	expect.equality(child.lua("return #_G.approval_sent"), 0)
end

T["fallback-select"]["focus returns to the previous window on close"] = function()
	-- Split so there is a distinct previous window.
	child.lua("vim.cmd('vsplit')")
	local prev_win = child.lua("return vim.api.nvim_get_current_win()")
	child.lua(string.format(SHOW, "fs-focus"))
	expect.equality(child.lua("return vim.api.nvim_get_current_win()") ~= prev_win, true)
	child.lua("fsel.close()")
	expect.equality(child.lua("return vim.api.nvim_get_current_win()"), prev_win)
end

return T
