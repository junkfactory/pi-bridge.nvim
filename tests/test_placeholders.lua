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
		vim.bo.filetype = 'lua'
	]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("look at @this")
	]])
	expect.equality(result, "look at \n\n```lua\nbbb\n```\n\n")
end

T["placeholders"]["resolve_with_range reports @this row number"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', 'bbb', 'ccc' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
	]])
	local range = child.lua([[
		return select(2, require('pi-bridge.placeholders').resolve_with_range("@this"))
	]])
	expect.equality(range, "2")
end

T["placeholders"]["resolve keeps surrounding text outside the fence"] = function()
	-- User's edge case: text before AND after @this must remain outside
	-- the fence (separate paragraphs in markdown).
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', 'bbb', 'ccc' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
	]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("in @this replace foo with boo")
	]])
	expect.equality(result, "in \n\n```text\nbbb\n```\n\n replace foo with boo")
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
	expect.equality(result, "explain \n\n```text\nbbb\nccc\n```\n\n")
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
	expect.equality(result, "x \n\n```text\nbbb\nccc\n```\n\n y")
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
	expect.equality(result, "\n\n```text\nbbb\nccc\n```\n\n")
end

T["placeholders"]["resolve replaces @selection with block columns while blockwise visual is active"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'world', 'funky', 'zzzz' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		vim.cmd('normal! \22')
		vim.api.nvim_win_set_cursor(0, { 3, 2 })
	]])
	expect.equality(child.fn.mode(), "\22")
	local result = child.lua([[return require('pi-bridge.placeholders').resolve("@selection")]])
	-- Lines 2-3, columns 1-3: "fun" (from "funky") and "zzz" (from "zzzz").
	expect.equality(result, "\n\n```text\nfun\nzzz\n```\n\n")
end

T["placeholders"]["resolve replaces @selection with block columns after blockwise visual"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'world', 'funky', 'zzzz' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		vim.cmd('normal! \22')
		vim.api.nvim_win_set_cursor(0, { 3, 2 })
		vim.cmd('normal! \27')
	]])
	local result = child.lua([[return require('pi-bridge.placeholders').resolve("@selection")]])
	expect.equality(result, "\n\n```text\nfun\nzzz\n```\n\n")
end

T["placeholders"]["resolve block selection skips lines shorter than the block"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'abcdefghij', 'x', 'abcdefghij' })
		vim.api.nvim_win_set_cursor(0, { 1, 2 })
		vim.cmd('normal! \22')
		vim.api.nvim_win_set_cursor(0, { 3, 4 })
		vim.cmd('normal! \27')
	]])
	local result = child.lua([[return require('pi-bridge.placeholders').resolve("@selection")]])
	-- Columns 3-5 on lines 1 and 3; "x" is too short and is dropped.
	expect.equality(result, "\n\n```text\ncde\ncde\n```\n\n")
end

T["placeholders"]["resolve block selection normalizes right-to-left drag"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'world', 'funky', 'zzzz' })
		vim.api.nvim_win_set_cursor(0, { 3, 3 })
		vim.cmd('normal! \22')
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		vim.cmd('normal! \27')
	]])
	local result = child.lua([[return require('pi-bridge.placeholders').resolve("@selection")]])
	-- Corners (3,4) and (2,1): lines 2-3, columns 1-4 -> "funk" (from
	-- "funky") and "zzzz"; line 1 "world" is outside the block.
	expect.equality(result, "\n\n```text\nfunk\nzzzz\n```\n\n")
end

T["placeholders"]["resolve block selection over box-drawing chars keeps whole chars"] = function()
	-- ┌ ─ │ are 3 bytes each in UTF-8 but one screen col wide. A block
	-- over them must slice by virtcol, not bytecol — the old code would
	-- extract only 2 chars per line and/or produce invalid UTF-8 when the
	-- byte col landed inside a 3-byte char.
	-- Block from (line 2, col 0) to (line 3, byte col 5): line 3's
	-- 4th char `i` sits at byte col 5 (0-indexed), giving end_vcol=4.
	-- Yields screen cols 1-4: line 2's first 4 chars ┌───, line 3's
	-- first 4 chars │ pi.
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { '```text', '┌──────────────┐', '│ pi (TUI)', '```' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		vim.cmd('normal! \22')
		vim.api.nvim_win_set_cursor(0, { 3, 5 })
	]])
	expect.equality(child.fn.mode(), "\22")
	local result = child.lua([[return require('pi-bridge.placeholders').resolve("@selection")]])
	expect.equality(result, "\n\n```text\n┌───\n│ pi\n```\n\n")
end

T["placeholders"]["resolve block selection after exit covers box-drawing chars"] = function()
	-- Same shape as the active test above, but Esc is pressed before
	-- resolve so '< and '> marks drive the read. Virtcol conversion must
	-- apply to the marks path too.
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { '```text', '┌──────────────┐', '│ pi (TUI)', '```' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		vim.cmd('normal! \22')
		vim.api.nvim_win_set_cursor(0, { 3, 5 })
		vim.cmd('normal! \27')
	]])
	local result = child.lua([[return require('pi-bridge.placeholders').resolve("@selection")]])
	expect.equality(result, "\n\n```text\n┌───\n│ pi\n```\n\n")
end

T["placeholders"]["resolve block selection includes whole multibyte char at right edge"] = function()
	-- Single-line block whose right edge lands ON the closing │ (a 3-byte
	-- UTF-8 char). The bytecol on │'s first byte would slice the char
	-- in half if used directly with string.sub — virtcol conversion +
	-- whole-char walk must keep the closing │ intact.
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { '│ pi (TUI)     │' })
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		vim.cmd('normal! \22')
		-- Byte col 17 = first byte of the closing │ (5 spaces between
		-- ')' and '│' push its start to byte 18 in 1-indexed = 17 in
		-- 0-indexed). virtcol there is 16.
		vim.api.nvim_win_set_cursor(0, { 1, 17 })
	]])
	expect.equality(child.fn.mode(), "\22")
	local result = child.lua([[return require('pi-bridge.placeholders').resolve("@selection")]])
	-- Whole line, closing │ included (no mid-char truncation).
	expect.equality(result, "\n\n```text\n│ pi (TUI)     │\n```\n\n")
end

T["placeholders"]["resolve block selection handles wide CJK chars at edge"] = function()
	-- 日 / 本 / 語 are displaywidth 2 each. Block cols 1-3 must include
	-- 本 (starts at virtcol 3, equals end_vcol) whole — not be cut off
	-- at col 2 where 日 ends.
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { '日本語 テスト' })
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		vim.cmd('normal! \22')
		-- Byte col 3 (0-indexed) = first byte of 本; virtcol there is 3.
		vim.api.nvim_win_set_cursor(0, { 1, 3 })
	]])
	expect.equality(child.fn.mode(), "\22")
	local result = child.lua([[return require('pi-bridge.placeholders').resolve("@selection")]])
	expect.equality(result, "\n\n```text\n日本\n```\n\n")
end

T["placeholders"]["resolve charwise selection over multibyte keeps whole chars"] = function()
	-- Charwise v from char 1 to char 3 of 日本語テスト. The '.' mark's
	-- bytecol sits on 語's first byte; converting to charcol gives 3,
	-- and strcharpart slices by whole chars — producing 日本語, not a
	-- half-byte prefix.
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { '日本語テスト' })
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		vim.cmd('normal! v')
		-- 0-indexed byte col 6 = 語's first byte; charwise selects
		-- chars 1-3.
		vim.api.nvim_win_set_cursor(0, { 1, 6 })
	]])
	expect.equality(child.fn.mode(), "v")
	local result = child.lua([[return require('pi-bridge.placeholders').resolve("@selection")]])
	expect.equality(result, "\n\n```text\n日本語\n```\n\n")
end

T["placeholders"]["resolve replaces @selection with full lines after linewise visual"] = function()
	-- Exited linewise visual: '< and '> marks must not column-trim lines.
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', 'bbb', 'ccc' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		vim.cmd('normal! V')
		vim.api.nvim_win_set_cursor(0, { 3, 0 })
		vim.cmd('normal! \27')
	]])
	local result = child.lua([[return require('pi-bridge.placeholders').resolve("@selection")]])
	expect.equality(result, "\n\n```text\nbbb\nccc\n```\n\n")
end

T["placeholders"]["resolve_with_range reports multi-line selection range"] = function()
	-- Charwise v from row 2 over rows 2-4 (cursor col 0 on row 4 includes
	-- one char of it) -> range "2-4".
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', 'bbb', 'ccc', 'ddd' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		vim.cmd('normal! v')
		vim.api.nvim_win_set_cursor(0, { 4, 0 })
	]])
	local range = child.lua([[
		return select(2, require('pi-bridge.placeholders').resolve_with_range("@selection"))
	]])
	expect.equality(range, "2-4")
end

T["placeholders"]["resolve_with_range reports linewise selection range from '<' to '>'"] = function()
	-- Linewise V from row 1 to row 3 -> '< and '> mark rows normalize.
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', 'bbb', 'ccc' })
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		vim.cmd('normal! V')
		vim.api.nvim_win_set_cursor(0, { 3, 0 })
		vim.cmd('normal! \27')
	]])
	local range = child.lua([[
		return select(2, require('pi-bridge.placeholders').resolve_with_range("@selection"))
	]])
	expect.equality(range, "1-3")
end

T["placeholders"]["resolve_with_range reports block selection range"] = function()
	-- Block (\22) from row 2 col 1 to row 3 col 4.
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'world', 'funky', 'zzzz' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		vim.cmd('normal! \22')
		vim.api.nvim_win_set_cursor(0, { 3, 3 })
		vim.cmd('normal! \27')
	]])
	local range = child.lua([[
		return select(2, require('pi-bridge.placeholders').resolve_with_range("@selection"))
	]])
	expect.equality(range, "2-3")
end

T["placeholders"]["resolve preserves empty line inside multi-line selection fence"] = function()
	-- Empty lines inside @selection must be preserved verbatim inside the
	-- fence (no special handling required — markdown fences pass empty
	-- lines through).
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', '', 'ccc' })
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		vim.cmd('normal! v')
		vim.api.nvim_win_set_cursor(0, { 3, 999 })
	]])
	local result = child.lua([[return require('pi-bridge.placeholders').resolve("@selection")]])
	expect.equality(result, "\n\n```text\naaa\n\nccc\n```\n\n")
end

T["placeholders"]["resolve lengthens opening fence to survive backtick runs in content"] = function()
	-- Content with a 4-backtick run would close a 3-backtick fence early.
	-- fence_marker must open with run+1 (= 5 here). The closing fence can
	-- stay the same length; CommonMark's "longer run ends" rule keeps it
	-- from accidentally closing the longer opening.
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'normal', '````hidden', 'also normal' })
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		vim.cmd('normal! V')
		vim.api.nvim_win_set_cursor(0, { 3, 999 })
		vim.cmd('normal! \27')
	]])
	local result = child.lua([[return require('pi-bridge.placeholders').resolve("@selection")]])
	-- Opening is 5 backticks; closing is 5 backticks (longer run rule).
	expect.equality(result, "\n\n`````text\nnormal\n````hidden\nalso normal\n`````\n\n")
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
	expect.equality(result, "\n\n```text\nalpha\nbeta\ngamma\n```\n\n")
end

T["placeholders"]["resolve_with_range returns nil for @content-only prompts"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "alpha", "beta", "gamma" })
	]])
	local range = child.lua([[
		return select(2, require('pi-bridge.placeholders').resolve_with_range("@content"))
	]])
	expect.equality(range, vim.NIL)
end

T["placeholders"]["resolve @content uses buffer filetype as fence language"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x = 1" })
		vim.bo.filetype = 'python'
	]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("@content")
	]])
	expect.equality(result, "\n\n```python\nx = 1\n```\n\n")
end

T["placeholders"]["resolve @content falls back to 'text' when filetype is empty"] = function()
	-- Default child nvim buffer has no filetype set; language must be "text".
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x = 1" })
		vim.bo.filetype = ''
	]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("@content")
	]])
	expect.equality(result, "\n\n```text\nx = 1\n```\n\n")
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
	-- The notice must remain inside the fence — look for the closing fence
	-- AFTER the notice line.
	local notice_pos = result:find("[truncated:", 1, true)
	local fence_close = result:find("```\n\n", notice_pos, true)
	expect.equality(fence_close ~= nil, true)
end

T["placeholders"]["resolve_with_range returns nil range for truncated @content"] = function()
	child.lua([[
		local chunk = string.rep("x", 1000)
		local lines = {}
		for i = 1, 1100 do
			lines[i] = chunk
		end
		vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
	]])
	local range = child.lua([[
		return select(2, require('pi-bridge.placeholders').resolve_with_range("@content"))
	]])
	expect.equality(range, vim.NIL)
end

T["placeholders"]["resolve lengthens opening fence to survive backtick runs in @content"] = function()
	-- @content with a 4-backtick line forces the opening fence to 5 backticks.
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'normal', '````hidden', 'also normal' })
	]])
	local result = child.lua([[return require('pi-bridge.placeholders').resolve("@content")]])
	expect.equality(result, "\n\n`````text\nnormal\n````hidden\nalso normal\n`````\n\n")
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
	-- @this fires and gets fenced; @selection in normal mode has no marks
	-- to read so it keeps the literal (pre-existing guard).
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', 'bbb' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		vim.cmd('normal! \27')
	]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve("@this and @selection")
	]])
	expect.equality(result:find("\n\n```text\nbbb\n```\n\n") ~= nil, true)
	expect.equality(result, "\n\n```text\nbbb\n```\n\n and @selection")
end

T["placeholders"]["resolve_with_range joins multiple ranged placeholders sorted"] = function()
	-- Two @this placeholders in one prompt must produce a sorted,
	-- comma-joined range string.
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'aaa', 'bbb' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
	]])
	-- First @this fires (row 2); second @this also fires (cursor parked
	-- on row 2) — duplicate row must dedupe.
	local range = child.lua([[
		return select(2, require('pi-bridge.placeholders').resolve_with_range("@this and @this"))
	]])
	expect.equality(range, "2")
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

T["placeholders"]["PLACEHOLDERS is a table with 7 entries"] = function()
	local result = child.lua([[
		local p = require('pi-bridge.placeholders')
		return #p.PLACEHOLDERS
	]])
	expect.equality(result, 7)
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
	expect.equality(result["marks"], true)
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
	expect.equality(result[5], "marks")
	expect.equality(result[6], "selection")
	expect.equality(result[7], "this")
end

T["placeholders"]["complete returns all placeholders for bare @"] = function()
	child.lua([[ require('pi-bridge') ]])
	local result = child.lua([[
		return _G._pi_bridge_complete("@", "", 0)
	]])
	-- Should return 7 items, alphabetically sorted
	expect.equality(#result, 7)
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
	expect.equality(#result, 7)
end

T["marks"] = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.start({ "-u", "scripts/minimal_init.lua" })
			-- minimal_init.lua does NOT isolate ShaDa: global marks set by a
			-- previous test child are restored in this one. Clear all marks
			-- so every case starts from a clean slate.
			child.lua([[
				for c in ('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'):gmatch('%w') do
					pcall(vim.cmd, 'silent! delmarks ' .. c)
				end
			]])
		end,
		post_case = function()
			child.stop()
		end,
	},
})

T["marks"]["@marks renders one block per set global mark, skips unset"] = function()
	child.lua([[
		local tmp1 = vim.fn.tempname() .. '_marks_a.lua'
		local tmp2 = vim.fn.tempname() .. '_marks_d.lua'
		vim.fn.writefile({ 'alpha', 'beta', 'gamma' }, tmp1)
		vim.fn.writefile({ 'delta', 'echo' }, tmp2)
		vim.cmd('edit ' .. vim.fn.fnameescape(tmp2))
		vim.bo.filetype = 'lua'
		vim.fn.setpos("'D", { 0, 2, 1, 0 })
		vim.cmd('edit ' .. vim.fn.fnameescape(tmp1))
		vim.bo.filetype = 'lua'
		vim.fn.setpos("'A", { 0, 1, 1, 0 })
		_G._marks_a = vim.loop.fs_realpath(tmp1) or tmp1
		_G._marks_d = vim.loop.fs_realpath(tmp2) or tmp2
	]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve('@marks')
	]])
	local a = child.lua([[ return _G._marks_a ]])
	local d = child.lua([[ return _G._marks_d ]])
	local expected = "Vim mark A - " .. a .. ":1:"
		.. "\n\n```lua\nalpha\n```\n\n"
		.. "\nVim mark D - " .. d .. ":2:"
		.. "\n\n```lua\necho\n```\n\n"
	expect.equality(result, expected)
end

T["marks"]["@marks includes lowercase buffer-local marks, skips digits"] = function()
	child.lua([[
		local tmp = vim.fn.tempname() .. '_marks_lower.lua'
		vim.fn.writefile({ 'p', 'q' }, tmp)
		vim.cmd('edit ' .. vim.fn.fnameescape(tmp))
		vim.bo.filetype = 'lua'
		vim.fn.setpos("'b", { 0, 2, 1, 0 })
		vim.fn.setpos("'3", { 0, 1, 1, 0 })
		_G._marks_lower = vim.loop.fs_realpath(tmp) or tmp
	]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve('@marks')
	]])
	local p = child.lua([[ return _G._marks_lower ]])
	expect.equality(result, "Vim mark b - " .. p .. ":2:\n\n```lua\nq\n```\n\n")
end

T["marks"]["@marks stays literal when no marks are set"] = function()
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve('compare @marks')
	]])
	expect.equality(result, "compare @marks")
end

T["marks"]["@mA resolves a mark set in another buffer"] = function()
	child.lua([[
		local tmp1 = vim.fn.tempname() .. '_mA_cur.lua'
		local tmp2 = vim.fn.tempname() .. '_mA_mark.lua'
		vim.fn.writefile({ 'x', 'y' }, tmp1)
		vim.fn.writefile({ 'markline' }, tmp2)
		vim.cmd('edit ' .. vim.fn.fnameescape(tmp1))
		vim.cmd('edit ' .. vim.fn.fnameescape(tmp2))
		vim.bo.filetype = 'lua'
		vim.fn.setpos("'A", { 0, 1, 1, 0 })
		vim.cmd('edit ' .. vim.fn.fnameescape(tmp1))
		_G._marks_mA_path = vim.loop.fs_realpath(tmp2) or tmp2
	]])
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve('explain @mA')
	]])
	local p = child.lua([[ return _G._marks_mA_path ]])
	expect.equality(result, "explain Vim mark A - " .. p .. ":1:\n\n```lua\nmarkline\n```\n\n")
end

T["marks"]["@mA stays literal when the mark is unset"] = function()
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve('use @mA')
	]])
	expect.equality(result, "use @mA")
end

T["marks"]["@mb and @m3 resolve lowercase/digit marks in unnamed buffer"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'one', 'two' })
		vim.bo.filetype = 'lua'
		vim.fn.setpos("'b", { 0, 2, 1, 0 })
		vim.fn.setpos("'3", { 0, 1, 1, 0 })
	]])
	local b = child.lua([[
		return require('pi-bridge.placeholders').resolve('@mb')
	]])
	local digit = child.lua([[
		return require('pi-bridge.placeholders').resolve('@m3')
	]])
	expect.equality(b, "Vim mark b - [No Name]:2:\n\n```lua\ntwo\n```\n\n")
	expect.equality(digit, "Vim mark 3 - [No Name]:1:\n\n```lua\none\n```\n\n")
end

T["marks"]["@m alone and unset @mx stay literal"] = function()
	local result = child.lua([[
		return require('pi-bridge.placeholders').resolve('@m and @mx')
	]])
	expect.equality(result, "@m and @mx")
end

T["marks"]["@marks is listed for autocomplete, dynamic @mN is not"] = function()
	child.lua([[ require('pi-bridge') ]])
	local listed = child.lua([[
		return vim.tbl_contains(require('pi-bridge.placeholders').PLACEHOLDERS, 'marks')
	]])
	expect.equality(listed, true)
	-- typing @m suggests only the static placeholder
	local result = child.lua([[
		return _G._pi_bridge_complete("@m", "", 0)
	]])
	expect.equality(#result, 1)
	expect.equality(result[1], "@marks")
end

T["marks"]["mark placeholders report no line range"] = function()
	child.lua([[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'only' })
		vim.fn.setpos("'A", { 0, 1, 1, 0 })
	]])
	local no_range = child.lua([[
		return select(2, require('pi-bridge.placeholders').resolve_with_range('@mA')) == nil
	]])
	expect.equality(no_range, true)
end

return T
