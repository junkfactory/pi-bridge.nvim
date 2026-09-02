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

T["context"]["get normal mode returns lightweight context"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', 'bbb', 'ccc' })
		vim.api.nvim_win_set_cursor(0, { 2, 1 })
	]])
	local result = child.lua([[
		return require('pi-bridge.context').get('normal')
	]])
	expect.equality(result.content, nil)
	expect.equality(result.mode, "normal")
	expect.equality(result.current_line, "bbb")
	expect.equality(type(result.cursor), "table")
	expect.equality(result.cursor.line, 2)
	expect.equality(type(result.surrounding), "string")
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
	expect.equality(result.current_line, "only")
end

T["context"]["get visual mode returns selection"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', 'bbb', 'ccc', 'ddd' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		vim.cmd('normal! v')
		vim.api.nvim_win_set_cursor(0, { 3, 999 })
	]])
	local result = child.lua([[
		return require('pi-bridge.context').get('visual')
	]])
	expect.equality(result.content:find("bbb") ~= nil, true)
	expect.equality(result.content:find("ccc") ~= nil, true)
	expect.equality(result.mode, "visual")
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

T["context"]["empty buffer returns empty surrounding"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, {})
	]])
	local result = child.lua([[
		return require('pi-bridge.context').get('normal')
	]])
	expect.equality(result.content, nil)
	expect.equality(result.surrounding, "")
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

T["context"]["visual mode sends content not surrounding"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', 'bbb', 'ccc' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		vim.cmd('normal! v')
		vim.api.nvim_win_set_cursor(0, { 2, 2 })
	]])
	local result = child.lua([[
		return require('pi-bridge.context').get('visual')
	]])
	expect.equality(type(result.content), "string")
	expect.equality(result.surrounding, nil)
	expect.equality(result.cursor, nil)
end

return T
