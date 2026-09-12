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
		-- Exit visual mode to set '< and '> marks (simulates keymap behavior)
		vim.cmd('normal! \27')
	]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("explain @selection")
	]])
	expect.equality(result:find("bbb") ~= nil, true)
end

T["placeholders"]["resolve keeps literal @selection when nothing is selected"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', 'bbb', 'ccc' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		vim.cmd('normal! \27')
	]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("check @selection here")
	]])
	expect.equality(result, "check @selection here")
end

T["placeholders"]["resolve replaces @selection while visual mode is still active"] = function()
	-- The keymap flow opens the prompt (nvim 0.12 cmdline-style ui.input)
	-- without exiting visual mode, so '< and '> are not set yet. resolve()
	-- must read the 'v and '.' marks in that state.
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', 'bbb', 'ccc' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
	]])
	-- Active charwise visual selection spanning "bbbccc" — resolve WITHOUT exiting.
	child.lua([[vim.cmd('normal! v')]])
	child.lua([[vim.api.nvim_win_set_cursor(0, { 3, 2 })]])
	expect.equality(child.fn.mode(), "v")
	local result = child.lua([[return require('pi-bridge.placeholders').resolve("x @selection y")]])
	expect.equality(result, "x bbb\nccc y")
end

T["placeholders"]["resolve replaces @selection with full lines while linewise visual is active"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', 'bbb', 'ccc' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
	]])
	-- Active linewise visual selection, cursor parked mid-line 3. Column
	-- trimming must not cut "ccc" even though the cursor is at col 1.
	child.lua([[vim.cmd('normal! V')]])
	child.lua([[vim.api.nvim_win_set_cursor(0, { 3, 1 })]])
	expect.equality(child.fn.mode(), "V")
	local result = child.lua([[return require('pi-bridge.placeholders').resolve("@selection")]])
	expect.equality(result, "bbb\nccc")
end

T["placeholders"]["resolve replaces @selection with full lines after linewise visual"] = function()
	-- Exited linewise visual: '< and '> marks must not column-trim lines.
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', 'bbb', 'ccc' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		vim.cmd('normal! V')
		vim.api.nvim_win_set_cursor(0, { 3, 0 })
		vim.cmd('normal! \\27')
	]])
	local result = child.lua([[return require('pi-bridge.placeholders').resolve("@selection")]])
	expect.equality(result, "bbb\nccc")
end

T["placeholders"]["resolve replaces @buffer with current buffer absolute path"] = function()
	-- Use a temp file so the buffer has a non-empty absolute name.
	-- Resolve via vim.loop.fs_realpath because macOS symlinks /var/folders
	-- to /private/var/folders; nvim_buf_get_name returns the resolved path
	-- while vim.fn.tempname may not.
	child.lua([[
		local tmp = vim.fn.tempname() .. "_pi_bridge_buf_test.txt"
		vim.fn.writefile({ "x" }, tmp)
		vim.cmd("edit " .. vim.fn.fnameescape(tmp))
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "hello", "world" })
		_G._pi_bridge_test_buf_path = vim.loop.fs_realpath(tmp) or tmp
	]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("path: @buffer")
	]])
	local expected = child.lua([[ return _G._pi_bridge_test_buf_path ]])
	expect.equality(result:find(expected, 1, true) ~= nil, true)
	expect.equality(result, "path: " .. expected)
end

T["placeholders"]["resolve replaces @buffers with newline-separated listed buffer paths"] = function()
	child.lua([[
		local tmp1 = vim.fn.tempname() .. "_pi_bridge_bufs_test_a.txt"
		local tmp2 = vim.fn.tempname() .. "_pi_bridge_bufs_test_b.txt"
		vim.fn.writefile({ "a" }, tmp1)
		vim.fn.writefile({ "b" }, tmp2)
		vim.cmd("edit " .. vim.fn.fnameescape(tmp1))
		vim.cmd("badd " .. vim.fn.fnameescape(tmp2))
		vim.cmd("buffer " .. vim.fn.fnameescape(tmp1))
		-- Resolve symlinks (macOS /var/folders -> /private/var/folders) since
		-- nvim_buf_get_name returns the resolved absolute path.
		_G._pi_bridge_test_buf_a = vim.loop.fs_realpath(tmp1) or tmp1
		_G._pi_bridge_test_buf_b = vim.loop.fs_realpath(tmp2) or tmp2
	]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("@buffers")
	]])
	local has_a = child.lua([[ return _G._pi_bridge_test_buf_a ]])
	local has_b = child.lua([[ return _G._pi_bridge_test_buf_b ]])
	expect.equality(result:find(has_a, 1, true) ~= nil, true)
	expect.equality(result:find(has_b, 1, true) ~= nil, true)
	-- Result is newline-separated paths.
	expect.equality(result:find("\n", 1, true) ~= nil, true)
end

T["placeholders"]["resolve replaces @content with buffer content"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "alpha", "beta", "gamma" })
	]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("@content")
	]])
	expect.equality(result, "alpha\nbeta\ngamma")
end

T["placeholders"]["resolve @content truncates large buffers with notice"] = function()
	-- Build a buffer that exceeds the 900 KiB cap. Each line is 1000 bytes
	-- and we use 1100 lines (~1.07 MiB total) to safely cross the threshold.
	child.lua([[
		local chunk = string.rep("x", 1000)
		local lines = {}
		for i = 1, 1100 do
			lines[i] = chunk
		end
		vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
	]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("@content")
	]])
	-- Truncation notice must be present.
	expect.equality(result:find("[truncated:", 1, true) ~= nil, true)
	expect.equality(result:find("~900KB of ~", 1, true) ~= nil, true)
	-- Total line count (1100) must appear in the notice.
	expect.equality(result:find("of 1100 lines", 1, true) ~= nil, true)
	-- Truncated payload must be smaller than the original by a wide margin.
	-- Original payload ~ 1,101,100 bytes; truncated well under that.
	expect.equality(#result < 1100000, true)
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
	expect.equality(result, "line 2: bbb and @selection")
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

T["placeholders"]["resolve keeps literal @buffer for unnamed buffer"] = function()
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("what is @buffer")
	]])
	expect.equality(result, "what is @buffer")
end

T["placeholders"]["resolve keeps literal @content for empty buffer"] = function()
	child.lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, {}) ]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("summarize @content")
	]])
	expect.equality(result, "summarize @content")
end

T["placeholders"]["resolve keeps literal placeholder when a resolver errors"] = function()
	child.lua([[
		-- Break the APIs the resolvers depend on; pcall must catch it and
		-- keep the literal instead of aborting the send.
		vim.api.nvim_buf_get_lines = function() error('boom') end
		vim.api.nvim_get_current_line = function() error('boom') end
	]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("see @content and @this")
	]])
	expect.equality(result, "see @content and @this")
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

T["placeholders"]["PLACEHOLDERS is a table with 6 entries"] = function()
	local result = child.lua([[
		local p = require('pi-bridge.placeholders')
		return #p.PLACEHOLDERS
	]])
	expect.equality(result, 6)
end

T["placeholders"]["PLACEHOLDERS contains expected names"] = function()
	local result = child.lua([[
		local p = require('pi-bridge.placeholders')
		local map = {}
		for _, name in ipairs(p.PLACEHOLDERS) do
			map[name] = true
		end
		return map
	]])
	expect.equality(result["this"], true)
	expect.equality(result["selection"], true)
	expect.equality(result["diagnostics"], true)
	expect.equality(result["buffer"], true)
	expect.equality(result["buffers"], true)
	expect.equality(result["content"], true)
end

T["placeholders"]["PLACEHOLDERS is sorted alphabetically"] = function()
	local result = child.lua([[
		local p = require('pi-bridge.placeholders')
		return p.PLACEHOLDERS
	]])
	expect.equality(result[1], "buffer")
	expect.equality(result[2], "buffers")
	expect.equality(result[3], "content")
	expect.equality(result[4], "diagnostics")
	expect.equality(result[5], "selection")
	expect.equality(result[6], "this")
end

T["placeholders"]["complete returns all placeholders for bare @"] = function()
	child.lua([[ require('pi-bridge') ]])
	local result = child.lua([[
		return _G._pi_bridge_complete("@", "", 0)
	]])
	-- Should return 6 items, alphabetically sorted
	expect.equality(#result, 6)
end

T["placeholders"]["complete filters by prefix"] = function()
	child.lua([[ require('pi-bridge') ]])
	local result = child.lua([[
		return _G._pi_bridge_complete("@th", "", 0)
	]])
	expect.equality(#result, 1)
	expect.equality(result[1], "@this")
end

T["placeholders"]["complete filters @sel to @selection"] = function()
	child.lua([[ require('pi-bridge') ]])
	local result = child.lua([[
		return _G._pi_bridge_complete("@sel", "", 0)
	]])
	expect.equality(#result, 1)
	expect.equality(result[1], "@selection")
end

T["placeholders"]["complete returns empty for unknown prefix"] = function()
	child.lua([[ require('pi-bridge') ]])
	local result = child.lua([[
		return _G._pi_bridge_complete("@xyz", "", 0)
	]])
	expect.equality(#result, 0)
end

T["placeholders"]["complete returns all for no @ in arglead"] = function()
	child.lua([[ require('pi-bridge') ]])
	local result = child.lua([[
		return _G._pi_bridge_complete("hello", "", 0)
	]])
	expect.equality(#result, 6)
end

return T
