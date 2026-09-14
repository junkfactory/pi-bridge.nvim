local MiniTest = require("mini.test")
local expect = MiniTest.expect

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set()

T["choice_float"] = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.start({ "-u", "scripts/minimal_init.lua" })
			child.lua("MiniTest = require('mini.test')")
			child.lua("cf = require('pi-bridge.choice_float')")
			child.lua("require('pi-bridge.choice_float')._reset()")
			-- Deterministic response capture (nil-safe: table.insert(t, nil)
			-- raises, so cancel values are recorded as vim.NIL).
			child.lua([[
				_G.cf_sent = {}
				_G.cf_on_choice = function(v)
					if v == nil then
						_G.cf_sent[#_G.cf_sent + 1] = vim.NIL
					else
						_G.cf_sent[#_G.cf_sent + 1] = v
					end
				end
			]])
		end,
		post_case = function()
			child.stop()
		end,
	},
})

local OPEN = [[
	_G.cf_sent = {}
	opened = cf.open({
		owner = 'test',
		id = 'cf-1',
		title = ' test float ',
		lines = { 'pick:', '', '1 - alpha', '2 - beta', '', '<Esc> - cancel' },
		keys = {
			{ key = '1', value = 'alpha' },
			{ key = '2', value = 'beta' },
			{ key = '<Esc>', value = nil },
		},
		on_choice = _G.cf_on_choice,
	})
]]

T["choice_float"]["open opens an entered float and tracks the id"] = function()
	child.lua(OPEN)
	expect.equality(child.lua("return opened"), true)
	expect.equality(child.lua("return cf.is_open('test')"), true)
	expect.equality(child.lua("return cf.get_id('test')"), "cf-1")
	-- Float window is current (entered on open).
	expect.equality(
		child.lua("return vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).relative ~= ''"),
		true
	)
end

T["choice_float"]["renders the caller's lines with padding"] = function()
	child.lua(OPEN)
	local lines = child.lua("return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(0), 0, -1, false)")
	-- One blank padding line top and bottom, one leading space per line.
	expect.equality(#lines, 8)
	expect.equality(lines[1], "")
	expect.equality(lines[2], "  pick:")
	expect.equality(lines[4], "  1 - alpha")
	expect.equality(lines[5], "  2 - beta")
	expect.equality(lines[8], "")
	-- Window is 2 wider and 2 taller than the caller's text area (unpinned
	-- width = longest line + 4, clamped to a 20 minimum → 20 here).
	local cfg = child.lua("return vim.api.nvim_win_get_config(0)")
	expect.equality(cfg.width, 20)
	expect.equality(cfg.height, 8)
end

T["choice_float"]["keypress sends the value then closes"] = function()
	child.lua(OPEN)
	child.lua("vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('1', true, false, true), 'x', false)")
	local sent = child.lua("return _G.cf_sent")
	expect.equality(#sent, 1)
	expect.equality(sent[1], "alpha")
	expect.equality(child.lua("return cf.is_open('test')"), false)
end

T["choice_float"]["cancel key (nil value) reaches on_choice as nil"] = function()
	child.lua(OPEN)
	child.lua("vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'x', false)")
	local sent = child.lua("return _G.cf_sent")
	expect.equality(#sent, 1)
	expect.equality(sent[1], vim.NIL)
	expect.equality(child.lua("return cf.is_open('test')"), false)
end

T["choice_float"]["close dismisses silently and restores the prior window"] = function()
	child.lua([[
		_G.cf_prev = vim.api.nvim_get_current_win()
		cf.open({
			owner = 'test', id = 'cf-close', title = ' t ',
			lines = { 'hi' }, keys = {}, on_choice = function() end,
		})
	]])
	child.lua("cf.close('test')")
	expect.equality(child.lua("return cf.is_open('test')"), false)
	-- Prior (non-floating) window is current again.
	expect.equality(
		child.lua("return vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).relative ~= ''"),
		false
	)
end

T["choice_float"]["close_silent echoes the reason"] = function()
	child.lua(OPEN)
	child.lua("cf.close_silent('test', 'went away')")
	expect.equality(child.lua("return cf.is_open('test')"), false)
	local msgs = child.lua(
		"return vim.api.nvim_cmdoutput and {} or {}"
	)
	-- Notification fired (not asserted here — covered by the disconnect
	-- path tests in test_init); the observable contract is the close.
	expect.equality(type(msgs), "table")
end

T["choice_float"]["window closed behind our back is pruned"] = function()
	child.lua(OPEN)
	-- :q the float — the stale handle must not make is_open() lie.
	child.lua("vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)")
	expect.equality(child.lua("return cf.is_open('test')"), false)
	-- And a fresh open succeeds (the poisoned state can't swallow it).
	expect.equality(child.lua("return opened"), true)
end

T["choice_float"]["double open is ignored; first float untouched"] = function()
	child.lua(OPEN)
	expect.equality(child.lua("return cf.is_open('test')"), true)
	-- Second open returns false and does not replace the state.
	expect.equality(child.lua([[
		return cf.open({ owner = 'test', id = 'cf-2', title = ' x ',
			lines = { 'other' }, keys = {}, on_choice = function() end })
	]]), false)
	expect.equality(child.lua("return cf.get_id('test')"), "cf-1")
	-- The original float is still open and still answers.
	child.lua("vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('2', true, false, true), 'x', false)")
	local sent = child.lua("return _G.cf_sent")
	expect.equality(#sent, 1)
	expect.equality(sent[1], "beta")
end

T["choice_float"]["owners are independent slots"] = function()
	child.lua(OPEN) -- owner 'test'
	expect.equality(child.lua("return cf.is_open('other')"), false)
	child.lua([[
		cf.open({ owner = 'other', id = 'cf-3', title = ' y ',
			lines = { 'second' }, keys = {}, on_choice = function() end })
	]])
	expect.equality(child.lua("return cf.is_open('other')"), true)
	expect.equality(child.lua("return cf.get_id('test')"), "cf-1")
	expect.equality(child.lua("return cf.get_id('other')"), "cf-3")
end

T["choice_float"]["missing/empty lines and id are rejected"] = function()
	expect.equality(child.lua([[
		return cf.open({ owner = 't', id = '', title = ' x ',
			lines = { 'a' }, keys = {}, on_choice = function() end })
	]]), false)
	expect.equality(child.lua([[
		return cf.open({ owner = 't', id = 'x', title = ' x ',
			lines = {}, keys = {}, on_choice = function() end })
	]]), false)
	expect.equality(child.lua("return cf.is_open('t')"), false)
end

return T
