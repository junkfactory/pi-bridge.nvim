local MiniTest = require("mini.test")
local expect = MiniTest.expect

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set()

T["placeholders"] = MiniTest.new_set({
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

T["placeholders"]["resolve replaces @this with current line"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', 'bbb', 'ccc' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
	]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("look at @this")
	]])
	expect.equality(result:find("line 2: bbb") ~= nil, true)
end

T["placeholders"]["resolve replaces @selection with selected text"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', 'bbb', 'ccc' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		vim.cmd('normal! V')
		vim.api.nvim_win_set_cursor(0, { 3, 999 })
	]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("explain @selection")
	]])
	expect.equality(result:find("bbb") ~= nil, true)
end

T["placeholders"]["resolve replaces @selection with empty string in normal mode"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', 'bbb', 'ccc' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		vim.cmd('normal! \27')
	]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("check @selection here")
	]])
	expect.equality(result, "check  here")
end

T["placeholders"]["resolve replaces @diagnostics with formatted output"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'local x = 1' })
		local ns = vim.api.nvim_create_namespace('test_placeholders_diag')
		vim.diagnostic.set(ns, 0, {
			{ lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = 'unused variable' },
		})
	]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("fix @diagnostics")
	]])
	expect.equality(result:find("L1:C1 [ERROR] unused variable", 1, true) ~= nil, true)
end

T["placeholders"]["resolve leaves unknown @tokens unchanged"] = function()
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("use @unknown token")
	]])
	expect.equality(result, "use @unknown token")
end

T["placeholders"]["resolve handles multiple placeholders"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', 'bbb' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		vim.cmd('normal! \27')
	]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("@this and @selection")
	]])
	expect.equality(result:find("line 2: bbb") ~= nil, true)
	expect.equality(result, "line 2: bbb and ")
end

T["placeholders"]["resolve handles no diagnostics gracefully"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'local x = 1' })
		local ns = vim.api.nvim_create_namespace('test_placeholders_no_diag')
		vim.diagnostic.reset(ns)
	]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("check @diagnostics")
	]])
	expect.equality(result, "check No diagnostics")
end

T["placeholders"]["resolve handles empty text"] = function()
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("")
	]])
	expect.equality(result, "")
end

T["placeholders"]["resolve handles nil input"] = function()
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve(nil)
	]])
	expect.equality(result, "")
end

return T
