local MiniTest = require("mini.test")
local expect = MiniTest.expect

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set()

T["mirror"] = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.start({ "-u", "scripts/minimal_init.lua" })
			child.lua("MiniTest = require('mini.test')")
			child.lua("mirror = require('pi-bridge.prompt_mirror')")
			-- Reset module state between cases.
			child.lua("require('pi-bridge.prompt_mirror')._reset()")
			-- Common capture scaffolding. Note: no vim.ui.select mock
			-- here — installing one would flip is_stock_picker() to false
			-- and the stock-picker tests would route through the plugin
			-- path. Tests that need to mock vim.ui.select install the
			-- mock locally after mirror.setup.
			child.lua([[
				_G.mirror_sent = {}
				_G.fake_send = function(msg) table.insert(_G.mirror_sent, msg) end
				_G._select_calls = {}
				_G._install_mock_select = function()
					local stock = vim.ui.select
					vim.ui.select = function(items, opts, on_choice)
						table.insert(_G._select_calls, { items = items, opts = opts })
						_G._select_on_choice = on_choice
						return nil
					end
					return stock
				end
				_G._restore_select = function(orig)
					if orig then vim.ui.select = orig end
				end
			]])
		end,
		post_case = function()
			child.stop()
		end,
	},
})

-- Helper: install a plugin-picker mock for vim.ui.select. Returns the
-- original so callers can restore.
local INSTALL_MOCK = [[
	local _stock = _G._install_mock_select()
]]

local RESTORE_MOCK = [[
	_G._restore_select(_stock)
]]

-- ---------------------------------------------------------------------------
-- Setup / opt / constants
-- ---------------------------------------------------------------------------

T["mirror"]["is_enabled reflects setup option"] = function()
	child.lua("mirror.setup({ ui_prompt_mirror = true })")
	expect.equality(child.lua("return mirror.is_enabled()"), true)
	child.lua("mirror.setup({ ui_prompt_mirror = false })")
	expect.equality(child.lua("return mirror.is_enabled()"), false)
end

T["mirror"]["is_enabled defaults to true"] = function()
	child.lua("mirror.setup({})")
	expect.equality(child.lua("return mirror.is_enabled()"), true)
end

T["mirror"]["TRIM_LEN is 80"] = function()
	expect.equality(child.lua("return mirror.TRIM_LEN"), 80)
end

T["mirror"]["trim_label leaves short strings untouched"] = function()
	local s = child.lua([[ return mirror.trim_label('hello world') ]])
	expect.equality(s, "hello world")
end

T["mirror"]["trim_label renders long strings as first-77 + '...'"] = function()
	local s = child.lua([[
		local long = string.rep('x', 200)
		return mirror.trim_label(long)
	]])
	expect.equality(#s, 80)
	expect.equality(s:sub(1, 77), string.rep('x', 77))
	expect.equality(s:sub(78), "...")
end

T["mirror"]["trim_label returns input unchanged at exactly TRIM_LEN"] = function()
	local s = child.lua([[ return mirror.trim_label(string.rep('y', 80)) ]])
	expect.equality(#s, 80)
	expect.equality(s, string.rep('y', 80))
end

T["mirror"]["trim_label tolerates non-string input"] = function()
	-- Defensive: callers should always pass strings, but if a nil
	-- sneaks in (option label missing), trim_label must not crash.
	local s_nil = child.lua("return mirror.trim_label(nil)")
	expect.equality(s_nil, "")
	local s_num = child.lua("return mirror.trim_label(42)")
	expect.equality(s_num, "42")
end

T["mirror"]["send_ready emits the hello message"] = function()
	child.lua("mirror.setup({ ui_prompt_mirror = true })")
	child.lua("mirror.send_ready(fake_send)")
	local sent = child.lua("return _G.mirror_sent")
	expect.equality(#sent, 1)
	expect.equality(sent[1].type, "mirror_ready")
end

T["mirror"]["send_ready is a no-op without a send function"] = function()
	child.lua("mirror.setup({ ui_prompt_mirror = true })")
	local ok = child.lua([[
		local ok, err = pcall(mirror.send_ready, nil)
		return ok
	]])
	expect.equality(ok, true)
end

-- ---------------------------------------------------------------------------
-- Select path (plugin picker): value sent untrimmed; format_item trims display.
-- ---------------------------------------------------------------------------

T["mirror"]["select request opens picker and sends value on choice"] = function()
	child.lua(INSTALL_MOCK)
	child.lua([[
		mirror.setup({ ui_prompt_mirror = true })
		mirror._handle_request({
			type = 'ui_prompt_request',
			id = 'sel-1',
			kind = 'select',
			title = 'pick one',
			options = { 'short', 'also short' },
		}, fake_send)
	]])
	local calls = child.lua("return #_G._select_calls")
	expect.equality(calls, 1)
	-- Items passed to picker are the ORIGINAL full labels (no trimming).
	local items = child.lua("return _G._select_calls[1].items")
	expect.equality(items[1], "short")
	expect.equality(items[2], "also short")
	local prompt = child.lua("return _G._select_calls[1].opts.prompt")
	expect.equality(prompt, "pick one")
	-- on_choice gets the original item, mirror sends the full label as value.
	child.lua("_G._select_on_choice(_G._select_calls[1].items[1])")
	local sent = child.lua("return _G.mirror_sent")
	expect.equality(#sent, 1)
	expect.equality(sent[1].type, "ui_prompt_response")
	expect.equality(sent[1].id, "sel-1")
	expect.equality(sent[1].value, "short")
	expect.equality(sent[1].cancelled, nil)
	child.lua(RESTORE_MOCK)
end

T["mirror"]["long label is display-trimmed; value sent untrimmed"] = function()
	-- The full label must round-trip — format_item only affects display.
	-- Use a moderate length (120 chars) so the comparison stays cheap and
	-- doesn't trip the msgpack payload size guard.
	child.lua(INSTALL_MOCK)
	child.lua([[
		mirror.setup({ ui_prompt_mirror = true })
		local long_label = string.rep('Z', 120)
		_G._long_label = long_label
		mirror._handle_request({
			type = 'ui_prompt_request',
			id = 'sel-long',
			kind = 'select',
			title = 'pick',
			options = { long_label, 'tiny' },
		}, fake_send)
	]])
	-- The picker received the ORIGINAL label, untrimmed.
	local original_len = child.lua("return #_G._select_calls[1].items[1]")
	expect.equality(original_len, 120)
	-- format_item is set and trims display.
	local fmt = child.lua("return type(_G._select_calls[1].opts.format_item)")
	expect.equality(fmt, "function")
	-- User picks the long option → mirror sends the FULL label back.
	child.lua("_G._select_on_choice(_G._select_calls[1].items[1])")
	local sent = child.lua("return _G.mirror_sent")
	expect.equality(#sent[1].value, 120)
	expect.equality(string.sub(sent[1].value, 1, 1), "Z")
	child.lua(RESTORE_MOCK)
end

T["mirror"]["cancel sends cancelled=true"] = function()
	child.lua(INSTALL_MOCK)
	child.lua([[
		mirror.setup({ ui_prompt_mirror = true })
		mirror._handle_request({
			type = 'ui_prompt_request',
			id = 'sel-cancel',
			kind = 'select',
			title = 'pick',
			options = { 'a', 'b' },
		}, fake_send)
	]])
	child.lua("_G._select_on_choice(nil)")
	local sent = child.lua("return _G.mirror_sent")
	expect.equality(#sent, 1)
	expect.equality(sent[1].type, "ui_prompt_response")
	expect.equality(sent[1].id, "sel-cancel")
	expect.equality(sent[1].cancelled, true)
	expect.equality(sent[1].value, nil)
	child.lua(RESTORE_MOCK)
end

T["mirror"]["confirm kind folds into a 2-option select"] = function()
	-- confirm must always have at least Yes/No. With explicit options the
	-- labels are preserved; without options, mirror backfills Yes/No.
	child.lua(INSTALL_MOCK)
	child.lua([[
		mirror.setup({ ui_prompt_mirror = true })
		mirror._handle_request({
			type = 'ui_prompt_request',
			id = 'conf-1',
			kind = 'confirm',
			title = 'are you sure',
		}, fake_send)
	]])
	local items = child.lua("return _G._select_calls[1].items")
	expect.equality(items[1], "Yes")
	expect.equality(items[2], "No")
	child.lua("_G._select_on_choice('Yes')")
	local sent = child.lua("return _G.mirror_sent")
	expect.equality(sent[1].value, "Yes")
	child.lua(RESTORE_MOCK)
end

T["mirror"]["opts off: no picker, no send"] = function()
	-- No mock installed; the disabled path must no-op before reaching
	-- either the plugin path or the stock path.
	child.lua("mirror.setup({ ui_prompt_mirror = false })")
	child.lua([[
		mirror._handle_request({
			type = 'ui_prompt_request',
			id = 'off-1',
			kind = 'select',
			title = 'pick',
			options = { 'a', 'b' },
		}, fake_send)
	]])
	local sent = child.lua("return #_G.mirror_sent")
	expect.equality(sent, 0)
	-- No float window was opened either (current window unchanged).
	local was_floating = child.lua([[
		local cfg = vim.api.nvim_win_get_config(0)
		return cfg.relative ~= ''
	]])
	expect.equality(was_floating, false)
end

T["mirror"]["missing id is dropped without surfacing"] = function()
	child.lua(INSTALL_MOCK)
	child.lua([[
		mirror.setup({ ui_prompt_mirror = true })
		mirror._handle_request({
			type = 'ui_prompt_request',
			kind = 'select',
			options = { 'a' },
		}, fake_send)
	]])
	local calls = child.lua("return #_G._select_calls")
	expect.equality(calls, 0)
	child.lua(RESTORE_MOCK)
end

-- ---------------------------------------------------------------------------
-- Stock picker path: minimal float with numbered keys + Esc.
-- ---------------------------------------------------------------------------

-- Helper to find the mirror's open stock float window. The float is
-- always the only relative-window in the child (headless tests have one
-- non-relative scratch window); if that assumption breaks, fall back to
-- `vim.api.nvim_get_current_win()` after explicit focus.
local FIND_FLOAT = [[
	local found = nil
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		local cfg = vim.api.nvim_win_get_config(w)
		if cfg.relative ~= '' then
			found = w
			break
		end
	end
	return found
]]

local FLOAT_LINES = [[
	local w = nil
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local cfg = vim.api.nvim_win_get_config(win)
		if cfg.relative ~= '' then w = win; break end
	end
	if not w then return nil end
	return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
]]

local IS_FLOAT_OPEN = [[
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		local cfg = vim.api.nvim_win_get_config(w)
		if cfg.relative ~= '' then return true end
	end
	return false
]]

T["mirror"]["stock picker renders trimmed labels and numbered choices"] = function()
	child.lua([[
		mirror.setup({ ui_prompt_mirror = true })
		local long_label = string.rep('Q', 200)
		mirror._handle_request({
			type = 'ui_prompt_request',
			id = 'stk-1',
			kind = 'select',
			title = 'pick one',
			options = { 'alpha', long_label, 'gamma' },
		}, fake_send)
	]])
	expect.equality(child.lua(IS_FLOAT_OPEN), true)
	local lines = child.lua(FLOAT_LINES)
	expect.equality(lines[1], "pick one")
	expect.equality(lines[2], "")
	expect.equality(lines[3]:sub(1, 3), "1 -")
	expect.equality(lines[3]:sub(5), "alpha")
	expect.equality(lines[4]:sub(1, 3), "2 -")
	expect.equality(lines[4]:sub(-3), "...")
	expect.equality(lines[5]:sub(1, 3), "3 -")
	expect.equality(lines[5]:sub(5), "gamma")
	expect.equality(lines[#lines]:sub(1, 5), "<Esc>")
end

T["mirror"]["stock picker sends full label on numbered key"] = function()
	child.lua([[
		mirror.setup({ ui_prompt_mirror = true })
		local long_label = string.rep('Q', 120)
		_G._long_label = long_label
		mirror._handle_request({
			type = 'ui_prompt_request',
			id = 'stk-num',
			kind = 'select',
			title = 'pick',
			options = { 'alpha', long_label },
		}, fake_send)
	]])
	-- Make sure the float is focused so buffer-local maps fire.
	child.lua([[
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			local cfg = vim.api.nvim_win_get_config(w)
			if cfg.relative ~= '' then vim.api.nvim_set_current_win(w); break end
		end
	]])
	child.lua("vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('2', true, false, true), 'x', false)")
	local sent = child.lua("return _G.mirror_sent")
	expect.equality(#sent, 1)
	expect.equality(sent[1].type, "ui_prompt_response")
	expect.equality(sent[1].id, "stk-num")
	expect.equality(#sent[1].value, 120)
end

T["mirror"]["stock picker Esc sends cancelled=true"] = function()
	child.lua([[
		mirror.setup({ ui_prompt_mirror = true })
		mirror._handle_request({
			type = 'ui_prompt_request',
			id = 'stk-esc',
			kind = 'select',
			title = 'pick',
			options = { 'alpha', 'beta' },
		}, fake_send)
	]])
	child.lua([[
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			local cfg = vim.api.nvim_win_get_config(w)
			if cfg.relative ~= '' then vim.api.nvim_set_current_win(w); break end
		end
	]])
	child.lua("vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'x', false)")
	local sent = child.lua("return _G.mirror_sent")
	expect.equality(#sent, 1)
	expect.equality(sent[1].id, "stk-esc")
	expect.equality(sent[1].cancelled, true)
end

T["mirror"]["stock picker is closed after answer"] = function()
	child.lua([[
		mirror.setup({ ui_prompt_mirror = true })
		mirror._handle_request({
			type = 'ui_prompt_request',
			id = 'stk-close',
			kind = 'select',
			title = 'pick',
			options = { 'alpha', 'beta' },
		}, fake_send)
	]])
	expect.equality(child.lua(IS_FLOAT_OPEN), true)
	child.lua([[
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			local cfg = vim.api.nvim_win_get_config(w)
			if cfg.relative ~= '' then vim.api.nvim_set_current_win(w); break end
		end
	]])
	child.lua("vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('1', true, false, true), 'x', false)")
	expect.equality(child.lua(IS_FLOAT_OPEN), false)
end

T["mirror"]["missing id on select request is dropped"] = function()
	child.lua("mirror.setup({ ui_prompt_mirror = true })")
	child.lua([[
		mirror._handle_request({
			type = 'ui_prompt_request',
			kind = 'select',
			options = { 'a' },
		}, fake_send)
	]])
	-- No mock installed; the stock picker path would have opened a float.
	expect.equality(child.lua(IS_FLOAT_OPEN), false)
end

-- ---------------------------------------------------------------------------
-- Resolved handler: closes pending surfaces.
-- ---------------------------------------------------------------------------

T["mirror"]["resolved closes the plugin picker without sending"] = function()
	child.lua(INSTALL_MOCK)
	child.lua([[
		mirror.setup({ ui_prompt_mirror = true })
		mirror._handle_request({
			type = 'ui_prompt_request',
			id = 'res-1',
			kind = 'select',
			title = 'pick',
			options = { 'a', 'b' },
		}, fake_send)
	]])
	local sent_pre = child.lua("return #_G.mirror_sent")
	expect.equality(sent_pre, 0)
	-- pi answers first → ui_prompt_resolved arrives → dismiss, no response.
	child.lua("mirror._handle_resolved({ type = 'ui_prompt_resolved', id = 'res-1' })")
	expect.equality(child.lua("return #_G.mirror_sent"), 0)
	-- The plugin's eventual on_choice(nil) must NOT send cancelled either.
	child.lua("_G._select_on_choice(nil)")
	expect.equality(child.lua("return #_G.mirror_sent"), 0)
	child.lua(RESTORE_MOCK)
end

T["mirror"]["resolved closes the stock picker without sending"] = function()
	child.lua([[
		mirror.setup({ ui_prompt_mirror = true })
		mirror._handle_request({
			type = 'ui_prompt_request',
			id = 'stk-res',
			kind = 'select',
			title = 'pick',
			options = { 'a', 'b' },
		}, fake_send)
	]])
	expect.equality(child.lua(IS_FLOAT_OPEN), true)
	child.lua("mirror._handle_resolved({ type = 'ui_prompt_resolved', id = 'stk-res' })")
	expect.equality(child.lua(IS_FLOAT_OPEN), false)
	expect.equality(child.lua("return #_G.mirror_sent"), 0)
end

T["mirror"]["resolved for unknown id is a no-op"] = function()
	child.lua("mirror.setup({ ui_prompt_mirror = true })")
	local ok = child.lua([[
		return select(1, pcall(mirror._handle_resolved, { type = 'ui_prompt_resolved', id = 'never-seen' }))
	]])
	expect.equality(ok, true)
	expect.equality(child.lua("return #_G.mirror_sent"), 0)
end

-- ---------------------------------------------------------------------------
-- Unknown kind: warn and no surface.
-- ---------------------------------------------------------------------------

T["mirror"]["unknown kind is logged and surfaces nothing"] = function()
	child.lua("mirror.setup({ ui_prompt_mirror = true })")
	child.lua([[
		mirror._handle_request({
			type = 'ui_prompt_request',
			id = 'unk-1',
			kind = 'wat',
			title = '???',
		}, fake_send)
	]])
	expect.equality(child.lua(IS_FLOAT_OPEN), false)
	expect.equality(child.lua("return #_G.mirror_sent"), 0)
end

-- ---------------------------------------------------------------------------
-- Custom mirror: float renders ANSI-stripped lines, key forwarding, Esc
-- closes-only, resolved closes.
-- ---------------------------------------------------------------------------

local function mock_getcharstr_seq(seq)
	-- Replace vim.fn.getcharstr with a function that pops from `seq` on
	-- each call. Used to drive the modal loop deterministically.
	local args = {}
	for _, k in ipairs(seq) do
		table.insert(args, string.format("%q", k))
	end
	child.lua(string.format([[
		local seq = { %s }
		vim.fn.getcharstr = function()
			if #seq == 0 then
				-- No more keys: yield once so the resolved timer can run,
				-- then return empty (the loop treats '' as break-on-Esc).
				vim.schedule(function() end)
				return ''
			end
			return table.remove(seq, 1)
		end
	]], table.concat(args, ", ")))
end

T["mirror"]["custom float renders stripped lines"] = function()
	child.lua([[
		mirror.setup({ ui_prompt_mirror = true })
		-- Block getcharstr entirely so the modal loop never progresses
		-- to its Esc break-out. vim.fn.getcharstr is called from inside
		-- the scheduled callback; making it sleep until cleared means
		-- the float stays open for the rest of this test.
		vim.fn.getcharstr = function() vim.wait(1000, function() return false end, 100); return '' end
		mirror._handle_request({
			type = 'ui_prompt_request',
			id = 'cust-1',
			kind = 'custom',
			lines = {
				'\27[31mred\27[0m text',
				'\27[1;33mbold yellow\27[0m',
				'plain line',
			},
		}, fake_send)
	]])
	expect.equality(child.lua(IS_FLOAT_OPEN), true)
	local lines = child.lua(FLOAT_LINES)
	expect.equality(lines[1], "red text")
	expect.equality(lines[2], "bold yellow")
	expect.equality(lines[3], "plain line")
	-- No color escapes leaked into the float.
	for _, l in ipairs(lines) do
		expect.equality(l:find("\27", 1, true) ~= nil, false)
	end
end

T["mirror"]["custom float forwards keys verbatim"] = function()
	mock_getcharstr_seq({ "y", "y", "s", "x" })
	child.lua([[
		mirror.setup({ ui_prompt_mirror = true })
		mirror._handle_request({
			type = 'ui_prompt_request',
			id = 'cust-keys',
			kind = 'custom',
			lines = { 'dialog text' },
		}, fake_send)
	]])
	child.lua("vim.wait(500, function() return #_G.mirror_sent >= 4 end, 20)")
	local sent = child.lua("return _G.mirror_sent")
	local keys = {}
	for _, m in ipairs(sent) do
		if m.type == "ui_prompt_response" and m.id == "cust-keys" and m.key ~= nil then
			table.insert(keys, m.key)
		end
	end
	expect.equality(#keys >= 4, true)
	expect.equality(keys[1], "y")
	expect.equality(keys[2], "y")
	expect.equality(keys[3], "s")
	expect.equality(keys[4], "x")
end

T["mirror"]["custom float Esc closes only and forwards nothing"] = function()
	-- Sequence ends with Esc; after Esc the loop must break and stop
	-- sending further keys even though the seq mock could yield more.
	mock_getcharstr_seq({ "y", "\27", "s" })
	child.lua([[
		mirror.setup({ ui_prompt_mirror = true })
		mirror._handle_request({
			type = 'ui_prompt_request',
			id = 'cust-esc',
			kind = 'custom',
			lines = { 'dialog text' },
		}, fake_send)
	]])
	child.lua("vim.wait(500, function() return #_G.mirror_sent >= 1 end, 20)")
	-- Wait long enough for any stray key to be sent if the loop
	-- continued past Esc (it must not).
	child.lua("vim.wait(300)")
	local sent = child.lua("return _G.mirror_sent")
	local key_sends = {}
	for _, m in ipairs(sent) do
		if m.type == "ui_prompt_response" and m.id == "cust-esc" then
			table.insert(key_sends, m)
		end
	end
	expect.equality(#key_sends, 1)
	expect.equality(key_sends[1].key, "y")
	expect.equality(child.lua(IS_FLOAT_OPEN), false)
end

T["mirror"]["custom float resolved closes the float"] = function()
	-- Sequence blocks (empty mock that yields) → loop is parked.
	-- ui_prompt_resolved must close the float and clear state.
	child.lua([[
		mirror.setup({ ui_prompt_mirror = true })
		vim.fn.getcharstr = function() vim.wait(1000, function() return false end, 100); return '' end
		mirror._handle_request({
			type = 'ui_prompt_request',
			id = 'cust-res',
			kind = 'custom',
			lines = { 'dialog text' },
		}, fake_send)
	]])
	expect.equality(child.lua(IS_FLOAT_OPEN), true)
	child.lua("mirror._handle_resolved({ type = 'ui_prompt_resolved', id = 'cust-res' })")
	child.lua("vim.wait(200, function() for _, w in ipairs(vim.api.nvim_list_wins()) do local c = vim.api.nvim_win_get_config(w); if c.relative == '' then return true end end; return false end, 20)")
	expect.equality(child.lua(IS_FLOAT_OPEN), false)
end

-- ---------------------------------------------------------------------------
-- Disconnect: dismiss_all closes surfaces, sends nothing.
-- ---------------------------------------------------------------------------

T["mirror"]["dismiss_all closes plugin picker and sends nothing"] = function()
	child.lua(INSTALL_MOCK)
	child.lua([[
		mirror.setup({ ui_prompt_mirror = true })
		mirror._handle_request({
			type = 'ui_prompt_request',
			id = 'dc-1',
			kind = 'select',
			title = 'pick',
			options = { 'a', 'b' },
		}, fake_send)
	]])
	expect.equality(child.lua("return #_G.mirror_sent"), 0)
	child.lua("mirror.dismiss_all()")
	expect.equality(child.lua("return #_G.mirror_sent"), 0)
	-- Plugin's eventual on_choice(nil) does not send cancelled.
	child.lua("_G._select_on_choice(nil)")
	expect.equality(child.lua("return #_G.mirror_sent"), 0)
	child.lua(RESTORE_MOCK)
end

T["mirror"]["dismiss_all closes stock picker and sends nothing"] = function()
	child.lua([[
		mirror.setup({ ui_prompt_mirror = true })
		mirror._handle_request({
			type = 'ui_prompt_request',
			id = 'dc-stk',
			kind = 'select',
			title = 'pick',
			options = { 'a', 'b' },
		}, fake_send)
	]])
	expect.equality(child.lua(IS_FLOAT_OPEN), true)
	child.lua("mirror.dismiss_all()")
	expect.equality(child.lua(IS_FLOAT_OPEN), false)
	expect.equality(child.lua("return #_G.mirror_sent"), 0)
end

T["mirror"]["dismiss_all with no surface is a no-op"] = function()
	child.lua("mirror.setup({ ui_prompt_mirror = true })")
	local ok = child.lua("return select(1, pcall(mirror.dismiss_all))")
	expect.equality(ok, true)
	expect.equality(child.lua("return #_G.mirror_sent"), 0)
end

return T
