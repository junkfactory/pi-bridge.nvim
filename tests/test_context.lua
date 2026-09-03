local MiniTest = require("mini.test")
local expect = MiniTest.expect

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set()

T["context"] = MiniTest.new_set({
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

T["context"]["get returns file and cwd"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'line1', 'line2' })
		vim.api.nvim_buf_set_name(0, '/tmp/test_file.lua')
	]])
	local result = child.lua([[
		local ctx = require('pi-bridge.context')
		return ctx.get('normal')
	]])
	expect.equality(result.file:match("test_file%.lua$"), "test_file.lua")
	expect.equality(type(result.cwd), "string")
	expect.equality(#result.cwd > 0, true)
end

T["context"]["get normal mode returns metadata only"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', 'bbb', 'ccc' })
		vim.api.nvim_win_set_cursor(0, { 2, 1 })
	]])
	local result = child.lua([[
		return require('pi-bridge.context').get('normal')
	]])
	expect.equality(result.mode, "normal")
	expect.equality(result.content, nil)
	expect.equality(result.cursor, nil)
	expect.equality(result.current_line, nil)
	expect.equality(result.surrounding, nil)
end

T["context"]["get defaults to normal mode"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'only' })
	]])
	local result = child.lua([[
		return require('pi-bridge.context').get()
	]])
	expect.equality(result.mode, "normal")
	expect.equality(result.content, nil)
	expect.equality(result.current_line, nil)
end

T["context"]["get returns only metadata fields"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'line' })
		vim.bo.filetype = 'lua'
	]])
	local result = child.lua([[
		return require('pi-bridge.context').get('normal')
	]])
	expect.equality(result.file ~= nil, true)
	expect.equality(result.cwd ~= nil, true)
	expect.equality(result.mode, "normal")
	expect.equality(result.filetype, "lua")
	-- content-bearing fields should be absent
	expect.equality(result.content, nil)
	expect.equality(result.cursor, nil)
	expect.equality(result.current_line, nil)
	expect.equality(result.surrounding, nil)
end

T["context"]["get_visual_selection returns lines"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', 'bbb', 'ccc' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		vim.cmd('normal! v')
		vim.api.nvim_win_set_cursor(0, { 2, 2 })
	]])
	local lines = child.lua([[
		return require('pi-bridge.context').get_visual_selection()
	]])
	expect.equality(type(lines), "table")
	expect.equality(#lines >= 1, true)
end

T["context"]["get_visual_selection normalizes reversed selection"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', 'bbb', 'ccc' })
		vim.api.nvim_win_set_cursor(0, { 3, 0 })
		vim.cmd('normal! v')
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
	]])
	local lines = child.lua([[
		return require('pi-bridge.context').get_visual_selection()
	]])
	expect.equality(type(lines), "table")
	expect.equality(#lines >= 1, true)
end

T["context"]["get includes filetype"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'line' })
		vim.bo.filetype = 'lua'
	]])
	local result = child.lua([[
		return require('pi-bridge.context').get('normal')
	]])
	expect.equality(result.filetype, "lua")
end

T["context"]["get returns buffer_state saved for readable file"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'line' })
		vim.api.nvim_buf_set_name(0, '/tmp/pi_bridge_test_saved.lua')
		vim.cmd('write! /tmp/pi_bridge_test_saved.lua')
	]])
	local result = child.lua([[
		return require('pi-bridge.context').get('normal')
	]])
	expect.equality(result.buffer_state, "saved")
	-- cleanup
	vim.fn.delete('/tmp/pi_bridge_test_saved.lua')
end

T["context"]["get returns buffer_state nameless for empty name"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'line' })
		vim.api.nvim_buf_set_name(0, '')
	]])
	local result = child.lua([[
		return require('pi-bridge.context').get('normal')
	]])
	expect.equality(result.buffer_state, "nameless")
end

T["context"]["get returns buffer_state scratch for scratch path"] = function()
	child.lua([[
		local data_dir = vim.fn.stdpath('data')
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'line' })
		vim.api.nvim_buf_set_name(0, data_dir .. '/scratch/test-123.lua')
	]])
	local result = child.lua([[
		return require('pi-bridge.context').get('normal')
	]])
	expect.equality(result.buffer_state, "scratch")
end

T["context"]["get returns buffer_state unsaved for named but unreadable"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'line' })
		vim.api.nvim_buf_set_name(0, '/tmp/pi_bridge_test_unsaved_nonexistent.lua')
	]])
	local result = child.lua([[
		return require('pi-bridge.context').get('normal')
	]])
	expect.equality(result.buffer_state, "unsaved")
end

T["context"]["get returns buffer_state modified for modified buffer"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'line' })
		vim.api.nvim_buf_set_name(0, '/tmp/pi_bridge_test_modified.lua')
		vim.cmd('write! /tmp/pi_bridge_test_modified.lua')
		vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'extra line' })
	]])
	local result = child.lua([[
		return require('pi-bridge.context').get('normal')
	]])
	expect.equality(result.buffer_state, "modified")
	-- cleanup
	vim.fn.delete('/tmp/pi_bridge_test_modified.lua')
end

return T
