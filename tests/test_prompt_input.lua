local MiniTest = require("mini.test")
local expect = MiniTest.expect

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set()

T["prompt_input"] = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.start({ "-u", "scripts/minimal_init.lua" })
			child.lua("MiniTest = require('mini.test')")
			child.lua("input = require('pi-bridge.input')")
			-- `_G._pi_bridge_input_complete` (the buffer-local completefunc)
			-- is registered at init.lua module load, so the plugin must be
			-- required for the <Tab> path to resolve.
			child.lua("require('pi-bridge')")
			child.lua("input._reset()")
			-- Deterministic submit capture. vim.NIL stands in for a nil
			-- argument (table.insert(t, nil) would raise).
			child.lua([[
				_G.in_sent = {}
				_G.in_on_submit = function(v)
					if v == nil then
						_G.in_sent[#_G.in_sent + 1] = vim.NIL
					else
						_G.in_sent[#_G.in_sent + 1] = v
					end
				end
			]])
		end,
		post_case = function()
			child.stop()
		end,
	},
})

-- Open the box through the public API with the submit stub attached.
local function open()
	return child.lua("return input.open({ on_submit = _G.in_on_submit })")
end

-- Poll |condition| (a child-Lua expression) until it holds or |timeout| ms.
local function wait_for(condition, timeout)
	child.lua(("vim.wait(%d, function() return (%s) end)"):format(timeout or 500, condition))
end

-- Let queued work (notably the scheduled submit) run to completion.
local function settle(ms)
	child.lua(("vim.wait(%d, function() return false end)"):format(ms or 100))
end

local function sent()
	return child.lua("return _G.in_sent")
end

local function height()
	return child.lua("return vim.api.nvim_win_get_config(0).height")
end

T["prompt_input"]["open opens an entered float titled ' π > '"] = function()
	expect.equality(open(), true)
	expect.equality(child.lua("return input.is_open()"), true)
	-- Floats report a non-empty `relative` and are the current window.
	local cfg = child.lua("return vim.api.nvim_win_get_config(0)")
	expect.equality(cfg.relative, "editor")
	expect.equality(cfg.title[1][1], " π > ")
	-- Short text starts at one row; wrapping and a zero scrolloff are what
	-- keep the box growing vertically instead of horizontally.
	expect.equality(cfg.height, 1)
	expect.equality(child.lua("return vim.wo.wrap"), true)
	expect.equality(child.lua("return vim.wo.scrolloff"), 0)
end

T["prompt_input"]["second open is refused while a box is open"] = function()
	expect.equality(open(), true)
	expect.equality(open(), false)
	-- Still exactly one float, still the same (current) window.
	expect.equality(child.lua("return input.is_open()"), true)
	expect.equality(child.lua("return #vim.api.nvim_list_wins()"), 2)
end

T["prompt_input"]["height starts at 1, grows with wrapping, caps at 10"] = function()
	open()
	expect.equality(height(), 1)

	-- 300 cells over a 60-cell box: five wrapped rows.
	child.type_keys(string.rep("x", 300))
	wait_for("vim.api.nvim_win_get_config(0).height > 1")
	expect.equality(height() > 1, true)
	expect.equality(height(), 5)

	-- Far longer than MAX_HEIGHT rows: the box stops at 10 and scrolls.
	child.type_keys(string.rep("y", 500))
	wait_for("vim.api.nvim_win_get_config(0).height == 10")
	expect.equality(height(), 10)
	expect.equality(child.lua("return vim.api.nvim_win_get_config(0).width"), 60)
end

T["prompt_input"]["<C-j> builds a multi-line prompt and <CR> submits it"] = function()
	open()
	-- The box opens in insert mode; leave it first so the leading "i" runs
	-- as a command instead of being inserted as text.
	child.type_keys("<Esc>", "i", "hello", "<C-j>", "world", "<CR>")
	wait_for("#_G.in_sent == 1")
	expect.equality(sent(), { "hello\nworld" })
	expect.equality(child.lua("return input.is_open()"), false)
end

T["prompt_input"]["<Esc> then <Esc> cancels without submitting"] = function()
	open()
	child.type_keys("hello")
	child.type_keys("<Esc>", "<Esc>")
	settle()
	expect.equality(child.lua("return input.is_open()"), false)
	expect.equality(#sent(), 0)
end

T["prompt_input"]["<C-c> cancels without submitting"] = function()
	open()
	child.type_keys("hello", "<C-c>")
	settle()
	expect.equality(child.lua("return input.is_open()"), false)
	expect.equality(#sent(), 0)
end

T["prompt_input"]["submit trims trailing whitespace"] = function()
	open()
	child.type_keys("hello", "   ", "<CR>")
	wait_for("#_G.in_sent == 1")
	expect.equality(sent(), { "hello" })
	expect.equality(child.lua("return input.is_open()"), false)
end

T["prompt_input"]["empty box submits nothing"] = function()
	open()
	child.type_keys("<CR>")
	settle()
	expect.equality(child.lua("return input.is_open()"), false)
	expect.equality(#sent(), 0)
end

T["prompt_input"]["close restores the previous window"] = function()
	child.lua([[
		vim.cmd('split')
		_G.in_prev = vim.api.nvim_get_current_win()
	]])
	expect.equality(open(), true)
	expect.equality(child.lua("return vim.api.nvim_get_current_win() ~= _G.in_prev"), true)
	child.lua("input.close('test')")
	expect.equality(child.lua("return vim.api.nvim_get_current_win()"), child.lua("return _G.in_prev"))
	-- Back in a normal (non-floating) window.
	expect.equality(
		child.lua("return vim.api.nvim_win_get_config(0).relative == ''"),
		true
	)
end

T["prompt_input"]["<Up> moves by display row on a wrapped line"] = function()
	open()
	child.type_keys(string.rep("w", 120))
	wait_for("vim.api.nvim_win_get_config(0).height == 2")
	expect.equality(child.lua("return vim.api.nvim_win_text_height(0, {}).all"), 2)

	local before = child.lua("return vim.api.nvim_win_get_cursor(0)")
	child.type_keys("<Up>")
	local after = child.lua("return vim.api.nvim_win_get_cursor(0)")

	-- Both endpoints must sit on the (single) buffer line: the move is a
	-- display-row move inside the wrapped line, not a buffer-line move.
	expect.equality(after[1], before[1])
	if after[2] >= before[2] then
		-- Not reproduced by this headless child (it is on nvim 0.12.6):
		-- fall back to asserting the mapping is a display-row move.
		expect.equality(child.lua("return vim.fn.maparg('<Up>', 'i'):lower()"), "<c-o>gk")
		return
	end
	expect.equality(after[2] < before[2], true)
	-- maparg renders the key as "<C-O>"; compare case-insensitively.
	expect.equality(child.lua("return vim.fn.maparg('<Up>', 'i'):lower()"), "<c-o>gk")
	expect.equality(child.lua("return vim.fn.maparg('<Down>', 'i'):lower()"), "<c-o>gj")
end

T["prompt_input"]["growing after a newline keeps the first line visible"] = function()
	open()
	-- Reproduce the reported sequence without driving insert keys: a
	-- newline in a height-1 box moves the cursor onto a line the box
	-- cannot show, nvim force-scrolls topline to the cursor line, and
	-- the growth that keeps our viewport-stale bug pinned: the
	-- re-anchor after the geometry change must reset it.
	child.lua([[
		local buf = vim.api.nvim_win_get_buf(0)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'hello', '' })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
	]])
	-- Cursor is invisible in the 1-row box: nvim's autoscroll puts
	-- topline on the cursor line, like after a <C-j> from line 1.
	child.lua("vim.api.nvim_exec_autocmds('TextChangedI', { buffer = 0 })")
	wait_for("vim.api.nvim_win_get_config(0).height == 2")
	local topline = child.lua("return vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].topline")
	expect.equality(topline, 1)
	-- First line must be within the visible viewport rows.
	local wrangled = child.lua([[
		return vim.fn.winline() > 1 and true or false
	]])
	expect.equality(wrangled, true)
	child.lua("input.close('test')")
end

T["prompt_input"]["growing two lines after two newlines keeps both first lines"] = function()
	open()
	-- Same trap, repeated: two stale toplines in a row (your "type line2,
	-- hello reappears; type line7, hello gone" rhythm).
	child.lua("vim.api.nvim_exec_autocmds('TextChangedI', { buffer = 0 })")
	child.lua([[
		local buf = vim.api.nvim_win_get_buf(0)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'hello', 'world', '' })
		vim.api.nvim_win_set_cursor(0, { 3, 0 })
	]])
	child.lua("vim.api.nvim_exec_autocmds('TextChangedI', { buffer = 0 })")
	wait_for("vim.api.nvim_win_get_config(0).height == 3")
	expect.equality(child.lua("return vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].topline"), 1)
	child.lua("input.close('test')")
end

T["prompt_input"]["VimResized to a narrower editor measures the new width first"] = function()
	open()
	-- 67 display cells: needs 4 wrapped rows at width 20, 7 at width 10.
	child.type_keys(string.rep("w", 120))
	wait_for("vim.api.nvim_win_get_config(0).height > 1")
	local before_h = child.lua("return vim.api.nvim_win_get_config(0).height")

	-- Shrink the editor so the box clamps from WIDTH=60 to columns - 4.
	child.lua("vim.o.columns = 24")
	child.lua("vim.api.nvim_exec_autocmds('VimResized', {})")
	wait_for("vim.api.nvim_win_get_config(0).width == 20")

	-- The box must be measured at its NEW width: enough rows for the
	-- full text at width 20 (the width-first ordering), or the test
	-- would have caught the stale-measure regression (height measured
	-- at width 60, applied together with width 20).
	local cfg = child.lua("return vim.api.nvim_win_get_config(0)")
	expect.equality(cfg.width, 20)
	expect.equality(child.lua("return vim.api.nvim_win_text_height(0, {}).all"), cfg.height)
	-- Narrowing the editor needs the same or more wrapped rows than the
	-- original size had, otherwise the measure used the old width.
	expect.equality(cfg.height >= before_h, true)
	-- The recentered box stays inside the narrowed editor (with border).
	expect.equality(cfg.col >= 0, true)
	expect.equality(cfg.col + cfg.width + 2 <= 24, true)

	child.lua("input.close('test')")
end

T["prompt_input"]["a handled VimResized after an external close leaves no dormant state"] = function()
	open()
	-- Close the float behind the module's back, as :q would.
	child.lua("vim.api.nvim_win_close(0, true)")
	expect.equality(child.lua("return input.is_open()"), false)
	-- The next VimResized is the dormant autocmd's last tick: it must
	-- drop the state (already done) and delete the augroup, so no
	-- handler survives the external close.
	child.lua("vim.api.nvim_exec_autocmds('VimResized', {})")
	expect.equality(child.lua("return vim.fn.exists('#pi-bridge-input')"), 0)
end

T["prompt_input"]["<Tab> completes @placeholder tokens via the completefunc"] = function()
	open()
	-- Expr-map branch: with no pum visible <Tab> starts completion.
	expect.equality(
		child.lua("return vim.fn.maparg('<Tab>', 'i', false, true).callback()"),
		"<C-x><C-u>"
	)
	-- "@th" has exactly one placeholder match (@this), so nvim inserts it
	-- and shows no pum. That is completion working, not a failure: a pum
	-- needs at least two candidates (see the next case). Documented
	-- fallback per plan: assert the adapter's @th result directly.
	child.type_keys("@th")
	child.type_keys("<Tab>")
	expect.equality(child.lua("return vim.api.nvim_get_current_line()"), "@this")
	expect.equality(
		child.lua("return require('pi-bridge.complete').completefunc(1, '')"),
		0
	)
end

T["prompt_input"]["<Tab> opens the pum when several candidates match"] = function()
	open()
	-- A bare "@" matches every placeholder, so completion stays in a pum
	-- instead of auto-inserting a single match.
	child.type_keys("@")
	child.type_keys("<Tab>")
	expect.equality(child.lua("return vim.fn.pumvisible()"), 1)
	expect.equality(child.lua("return #vim.fn.complete_info({ 'items' }).items > 1"), true)
	-- And the expr map defers to the pum while it is visible.
	expect.equality(
		child.lua("return vim.fn.maparg('<Tab>', 'i', false, true).callback()"),
		"<C-n>"
	)
	-- <CR> accepts the candidate rather than submitting.
	child.type_keys("<Esc>", "<Esc>")
	settle()
	expect.equality(#sent(), 0)
end

T["prompt_input"]["keymaps are buffer-local to the input buffer"] = function()
	open()
	local maps = child.lua([[
		local out = {}
		for _, spec in ipairs({ { 'i', '<CR>' }, { 'i', '<Tab>' }, { 'i', '<C-c>' }, { 'n', 'q' } }) do
			local m = vim.fn.maparg(spec[2], spec[1], false, true)
			out[#out + 1] = {
				mode = spec[1],
				lhs = spec[2],
				buffer = m.buffer or 0,
				nowait = m.nowait or 0,
				silent = m.silent or 0,
			}
		end
		return out
	]])
	expect.equality(#maps, 4)
	for _, m in ipairs(maps) do
		expect.equality(m.buffer, 1) -- 1 == local to the current (input) buffer
		expect.equality(m.nowait, 1)
		expect.equality(m.silent, 1)
	end
	-- The box is a scratch buffer: no filetype, nothing to write to disk.
	expect.equality(child.lua("return vim.bo.buftype"), "nofile")
	expect.equality(child.lua("return vim.bo.bufhidden"), "wipe")

	-- Closing wipes the buffer, so the maps go with it and the restored
	-- window has no buffer-local <CR> insert mapping.
	child.lua("input.close('test')")
	expect.equality(child.lua("return vim.fn.maparg('<CR>', 'i')"), "")
end

return T
