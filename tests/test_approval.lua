local MiniTest = require("mini.test")
local expect = MiniTest.expect

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set()

T["approval"] = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.start({ "-u", "scripts/minimal_init.lua" })
			child.lua("MiniTest = require('mini.test')")
			child.lua("require('pi-bridge.approval')")
			-- Reset module state between cases.
			child.lua("require('pi-bridge.approval')._reset()")
		end,
		post_case = function()
			child.stop()
		end,
	},
})

-- Window lifecycle: show() opens a float with diff content and a header.

T["approval"]["show opens a centered floating window"] = function()
	local result = child.lua([[
		local approval = require('pi-bridge.approval')
		approval.setup({ edit_approval_prompt = true })

		local sent = {}
		approval.show({
			type = 'approval_request',
			id = 'req-1',
			tool = 'edit',
			path = '/tmp/example.lua',
			diff = '--- a/example.lua\n+++ b/example.lua\n@@ -1 +1 @@\n-old\n+new\n',
		}, function(msg)
			table.insert(sent, msg)
		end)

		local wins = vim.api.nvim_list_wins()
		local floats = {}
		for _, w in ipairs(wins) do
			local c = vim.api.nvim_win_get_config(w)
			if c.relative and c.relative ~= '' then
				table.insert(floats, {
					relative = c.relative,
					width = c.width,
					height = c.height,
					border = c.border,
					title = c.title,
				})
			end
		end
		return { floats = floats, sent = sent }
	]])
	expect.equality(#result.floats >= 1, true)
	expect.equality(result.floats[1].relative, "editor")
	-- border may be returned as either the string "rounded" or its
	-- expanded list form (table of border chars). Accept both.
	local border = result.floats[1].border
	expect.equality(border == "rounded" or type(border) == "table", true)
	-- title is either a plain string or, when combined with border =
	-- "rounded", an nvim-expanded `{ { "title" } }` table.
	local title = result.floats[1].title
	local title_text
	if type(title) == "string" then
		title_text = title
	elseif type(title) == "table" and type(title[1]) == "table" then
		title_text = title[1][1]
	end
	expect.equality(type(title_text), "string")
	expect.equality(title_text:find("pi edit approval") ~= nil, true)
end

T["approval"]["window contains diff content with header"] = function()
	local result = child.lua([[
		local approval = require('pi-bridge.approval')
		approval.setup({ edit_approval_prompt = true })

		approval.show({
			id = 'req-2',
			tool = 'edit',
			path = '/tmp/foo.lua',
			diff = '--- a/foo.lua\n+++ b/foo.lua\n-old line\n+new line\n',
		}, function() end)

		-- Find the float's buffer.
		local bufnr = nil
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			local c = vim.api.nvim_win_get_config(w)
			if c.relative and c.relative ~= '' then
				bufnr = vim.api.nvim_win_get_buf(w)
				break
			end
		end
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		return lines
	]])
	-- Expect path header, hint line, and diff body.
	local path_found = false
	local hint_found = false
	local diff_found = false
	for _, line in ipairs(result) do
		if line == "approve edit: /tmp/foo.lua" then
			path_found = true
		end
		-- The hint must be its own line: a long path could clip a
		-- combined line past the float's right edge (wrap is off).
		if line:find("respond: y") and line:find("n / <Esc>") then
			hint_found = true
		end
		if line == "+new line" then
			diff_found = true
		end
	end
	expect.equality(path_found, true)
	expect.equality(hint_found, true)
	expect.equality(diff_found, true)
end

T["approval"]["window uses diff syntax"] = function()
	local result = child.lua([[
		local approval = require('pi-bridge.approval')
		approval.setup({ edit_approval_prompt = true })
		approval.show({
			id = 'req-syntax',
			tool = 'edit',
			path = '/tmp/x.lua',
			diff = '--- a/x\n+++ b/x\n-old\n+new\n',
		}, function() end)

		local bufnr = nil
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_config(w).relative and vim.api.nvim_win_get_config(w).relative ~= '' then
				bufnr = vim.api.nvim_win_get_buf(w)
				break
			end
		end
		return {
			filetype = vim.bo[bufnr].filetype,
			syntax = vim.api.nvim_buf_get_option(bufnr, 'syntax'),
			buftype = vim.bo[bufnr].buftype,
			bufhidden = vim.bo[bufnr].bufhidden,
		}
	]])
	expect.equality(result.filetype, "diff")
	expect.equality(result.syntax, "diff")
end

T["approval"]["header warns when target buffer is modified"] = function()
	local result = child.lua([[
		local approval = require('pi-bridge.approval')
		approval.setup({ edit_approval_prompt = true })

		-- Load a buffer for the target path and mark it modified.
		local tmp = vim.fn.tempname() .. '.lua'
		vim.fn.writefile({ 'existing' }, tmp)
		vim.cmd('edit ' .. vim.fn.fnameescape(tmp))
		local edit_buf = vim.api.nvim_get_current_buf()
		vim.bo[edit_buf].modified = true
		local loaded_path = vim.api.nvim_buf_get_name(edit_buf)

		approval.show({
			id = 'req-mod',
			tool = 'edit',
			path = loaded_path,
			diff = '--- a/x\n+++ b/x\n-old\n+new\n',
		}, function() end)

		local bufnr = nil
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_config(w).relative and vim.api.nvim_win_get_config(w).relative ~= '' then
				bufnr = vim.api.nvim_win_get_buf(w)
				break
			end
		end
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		vim.bo[edit_buf].modified = false
		vim.api.nvim_buf_delete(edit_buf, { force = true })
		os.remove(tmp)
		return lines
	]])
	local saw_warning = false
	for _, line in ipairs(result) do
		if line:find("unsaved changes") then
			saw_warning = true
			break
		end
	end
	expect.equality(saw_warning, true)
end

T["approval"]["no warning line when target buffer is not modified"] = function()
	local result = child.lua([[
		local approval = require('pi-bridge.approval')
		approval.setup({ edit_approval_prompt = true })

		approval.show({
			id = 'req-clean',
			tool = 'edit',
			path = '/tmp/never-loaded.lua',
			diff = '--- a/x\n+++ b/x\n-old\n+new\n',
		}, function() end)

		local bufnr = nil
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_config(w).relative and vim.api.nvim_win_get_config(w).relative ~= '' then
				bufnr = vim.api.nvim_win_get_buf(w)
				break
			end
		end
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		return lines
	]])
	local saw_warning = false
	for _, line in ipairs(result) do
		if line:find("unsaved changes") then
			saw_warning = true
			break
		end
	end
	expect.equality(saw_warning, false)
end

-- Ack payload: `approval_ack` is sent immediately after the float opens,
-- and contains exactly `{ type = "approval_ack", id = req.id }`.

T["approval"]["show sends approval_ack with matching id"] = function()
	local result = child.lua([[
		local approval = require('pi-bridge.approval')
		approval.setup({ edit_approval_prompt = true })

		_G.approval_sent = {}
		approval.show({
			id = 'req-ack-1',
			tool = 'edit',
			path = '/tmp/x.lua',
			diff = '--- a\n+++ b\n-old\n+new\n',
		}, function(msg)
			table.insert(_G.approval_sent, msg)
		end)
		return _G.approval_sent
	]])
	expect.equality(#result, 1)
	expect.equality(result[1].type, "approval_ack")
	expect.equality(result[1].id, "req-ack-1")
end

-- Decisions: each key sends the correct decision and closes the float.

local function with_fresh_float(id)
	return string.format([[
		local approval = require('pi-bridge.approval')
		approval.setup({ edit_approval_prompt = true })
		_G.approval_sent = {}
		approval.show({
			id = %q,
			tool = 'edit',
			path = '/tmp/x.lua',
			diff = '--- a\n+++ b\n-old\n+new\n',
		}, function(msg)
			table.insert(_G.approval_sent, msg)
		end)
		local bufnr
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_config(w).relative and vim.api.nvim_win_get_config(w).relative ~= '' then
				bufnr = vim.api.nvim_win_get_buf(w)
				break
			end
		end
		_G.approval_test_bufnr = bufnr
	]], id)
end

local function float_open(child)
	return child.lua([[
		local wins = vim.api.nvim_list_wins()
		for _, w in ipairs(wins) do
			local c = vim.api.nvim_win_get_config(w)
			if c.relative and c.relative ~= '' then
				return true
			end
		end
		return false
	]])
end

local function feed_key(child, key)
	-- Special keys (<Esc>, <CR>, etc.) must be termcode-translated before
	-- feedkeys interprets them — passing the raw "<Esc>" string ends up
	-- as literal text in the typeahead buffer.
	child.lua(string.format([[
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(%q, true, false, true), 'mtx', false)
		vim.wait(50)
	]], key))
end

T["approval"]["show defers UI work when called from a fast-event context"] = function()
	-- The real dispatch path calls show() from the socket's pipe read
	-- callback (a libuv fast event), where nvim_* APIs raise E5560.
	-- Simulate that context and verify the float appears after the
	-- scheduled callback runs, with the ack sent from the deferred body.
	local result = child.lua([[
		local approval = require('pi-bridge.approval')
		approval.setup({ edit_approval_prompt = true })

		local real = vim.in_fast_event
		vim.in_fast_event = function() return true end
		local sent = {}
		approval.show({
			id = 'req-fast',
			tool = 'edit',
			path = '/tmp/fast.lua',
			diff = '--- a\n+++ b\n-old\n+new\n',
		}, function(msg)
			table.insert(sent, msg)
		end)
		vim.in_fast_event = real

		local function count_floats()
			local n = 0
			for _, w in ipairs(vim.api.nvim_list_wins()) do
				local c = vim.api.nvim_win_get_config(w)
				if c.relative and c.relative ~= '' then n = n + 1 end
			end
			return n
		end

		local immediate_floats = count_floats()
		local appeared = vim.wait(200, function() return count_floats() > 0 end, 10)
		return { immediate_floats = immediate_floats, appeared = appeared, acks = #sent }
	]])
	expect.equality(result.immediate_floats, 0)
	expect.equality(result.appeared, true)
	expect.equality(result.acks, 1)
end

T["approval"]["resolve defers when called from a fast-event context"] = function()
	local result = child.lua([[
		local approval = require('pi-bridge.approval')
		approval.setup({ edit_approval_prompt = true })

		approval.show({
			id = 'req-slow',
			tool = 'edit',
			path = '/tmp/slow.lua',
			diff = '--- a\n+++ b\n',
		}, function() end)

		local real = vim.in_fast_event
		vim.in_fast_event = function() return true end
		approval.resolve('req-slow')
		vim.in_fast_event = real

		local function has_float()
			for _, w in ipairs(vim.api.nvim_list_wins()) do
				local c = vim.api.nvim_win_get_config(w)
				if c.relative and c.relative ~= '' then return true end
			end
			return false
		end

		local closed = vim.wait(200, function() return not has_float() end, 10)
		return { closed = closed }
	]])
	expect.equality(result.closed, true)
end

T["approval"]["y key sends decision yes and closes window"] = function()
	child.lua(with_fresh_float("req-y"))
	expect.equality(float_open(child), true)

	feed_key(child, "y")

	local sent = child.lua("return _G.approval_sent")
	expect.equality(#sent >= 1, true)
	local response = nil
	for _, m in ipairs(sent) do
		if m.type == "approval_response" then
			response = m
			break
		end
	end
	expect.equality(response ~= nil, true)
	expect.equality(response.id, "req-y")
	expect.equality(response.decision, "yes")
	expect.equality(float_open(child), false)
end

T["approval"]["a key sends decision all"] = function()
	child.lua(with_fresh_float("req-a"))
	feed_key(child, "a")

	local sent = child.lua("return _G.approval_sent")
	local response = nil
	for _, m in ipairs(sent) do
		if m.type == "approval_response" then
			response = m
			break
		end
	end
	expect.equality(response ~= nil, true)
	expect.equality(response.id, "req-a")
	expect.equality(response.decision, "all")
	expect.equality(float_open(child), false)
end

T["approval"]["n key sends decision no"] = function()
	child.lua(with_fresh_float("req-n"))
	feed_key(child, "n")

	local sent = child.lua("return _G.approval_sent")
	local response = nil
	for _, m in ipairs(sent) do
		if m.type == "approval_response" then
			response = m
			break
		end
	end
	expect.equality(response ~= nil, true)
	expect.equality(response.id, "req-n")
	expect.equality(response.decision, "no")
	expect.equality(float_open(child), false)
end

T["approval"]["<esc> sends decision no"] = function()
	child.lua(with_fresh_float("req-esc"))
	feed_key(child, "<Esc>")

	local sent = child.lua("return _G.approval_sent")
	local response = nil
	for _, m in ipairs(sent) do
		if m.type == "approval_response" then
			response = m
			break
		end
	end
	expect.equality(response ~= nil, true)
	expect.equality(response.id, "req-esc")
	expect.equality(response.decision, "no")
	expect.equality(float_open(child), false)
end

T["approval"]["keypress restores previous window focus"] = function()
	child.lua([[
		local approval = require('pi-bridge.approval')
		approval.setup({ edit_approval_prompt = true })
		_G.approval_sent = {}
		_G.pre_win = vim.api.nvim_get_current_win()
		approval.show({
			id = 'req-focus',
			tool = 'edit',
			path = '/tmp/x.lua',
			diff = 'diff body\n',
		}, function(msg)
			table.insert(_G.approval_sent, msg)
		end)
		-- Verify float stole focus
		_G.focus_after_show = vim.api.nvim_get_current_win()
	]])
	local stole_focus = child.lua([[
		local c = vim.api.nvim_win_get_config(_G.focus_after_show)
		return c.relative and c.relative ~= ''
	]])
	expect.equality(stole_focus, true)

	feed_key(child, "y")

	local restored = child.lua([[
		return _G.pre_win == vim.api.nvim_get_current_win()
			and vim.api.nvim_win_is_valid(_G.pre_win)
	]])
	expect.equality(restored, true)
end

-- resolve(): closes a stale float for the matching id; ignores others.

T["approval"]["resolve closes pending float for matching id"] = function()
	child.lua(with_fresh_float("req-resolve"))
	expect.equality(float_open(child), true)

	child.lua("require('pi-bridge.approval').resolve('req-resolve')")
	expect.equality(float_open(child), false)
end

T["approval"]["resolve ignores non-matching id"] = function()
	child.lua(with_fresh_float("req-keep"))
	expect.equality(float_open(child), true)

	child.lua("require('pi-bridge.approval').resolve('req-other')")
	expect.equality(float_open(child), true)

	-- still answerable
	feed_key(child, "y")
	expect.equality(float_open(child), false)
end

T["approval"]["resolve is safe with no pending float"] = function()
	local ok = child.lua([[
		local ok, err = pcall(require('pi-bridge.approval').resolve, 'no-such-id')
		return ok
	]])
	expect.equality(ok, true)
end

-- Disabled config: no window, no ack — pi will fallback after 1s.

T["approval"]["disabled config opens no window and sends no ack"] = function()
	local result = child.lua([[
		local approval = require('pi-bridge.approval')
		approval.setup({ edit_approval_prompt = false })

		_G.approval_sent = {}
		approval.show({
			id = 'req-disabled',
			tool = 'edit',
			path = '/tmp/x.lua',
			diff = 'diff body\n',
		}, function(msg)
			table.insert(_G.approval_sent, msg)
		end)

		local open = false
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			local c = vim.api.nvim_win_get_config(w)
			if c.relative and c.relative ~= '' then
				open = true
				break
			end
		end
		return { sent = _G.approval_sent, open = open }
	]])
	expect.equality(#result.sent, 0)
	expect.equality(result.open, false)
end

T["approval"]["is_enabled reflects setup option"] = function()
	child.lua("require('pi-bridge.approval').setup({ edit_approval_prompt = true })")
	expect.equality(child.lua("return require('pi-bridge.approval').is_enabled()"), true)

	child.lua("require('pi-bridge.approval').setup({ edit_approval_prompt = false })")
	expect.equality(child.lua("return require('pi-bridge.approval').is_enabled()"), false)

	-- Default (no opts) is enabled.
	child.lua("require('pi-bridge.approval')._reset(); require('pi-bridge.approval').setup()")
	expect.equality(child.lua("return require('pi-bridge.approval').is_enabled()"), true)
end

-- Defensive: a second concurrent request is ignored while one is pending.

T["approval"]["second request while pending is ignored with warning"] = function()
	child.lua([[
		local approval = require('pi-bridge.approval')
		approval.setup({ edit_approval_prompt = true })
		_G.approval_sent = {}
		approval.show({
			id = 'first',
			tool = 'edit',
			path = '/tmp/a.lua',
			diff = 'first diff\n',
		}, function(msg) table.insert(_G.approval_sent, msg) end)

		approval.show({
			id = 'second',
			tool = 'edit',
			path = '/tmp/b.lua',
			diff = 'second diff\n',
		}, function(msg) table.insert(_G.approval_sent, msg) end)
	]])
	-- Only one ack should have been sent (for the first request).
	local acks = child.lua([[
		local n = 0
		for _, m in ipairs(_G.approval_sent) do
			if m.type == 'approval_ack' then n = n + 1 end
		end
		return n
	]])
	expect.equality(acks, 1)
end

-- Defensive: malformed requests are silently dropped.

T["approval"]["missing id is dropped without opening a window"] = function()
	local result = child.lua([[
		local approval = require('pi-bridge.approval')
		approval.setup({ edit_approval_prompt = true })
		_G.approval_sent = {}
		approval.show({ type = 'approval_request', path = '/x', diff = 'd' }, function(m)
			table.insert(_G.approval_sent, m)
		end)
		local open = false
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			local c = vim.api.nvim_win_get_config(w)
			if c.relative and c.relative ~= '' then open = true break end
		end
		return { sent = _G.approval_sent, open = open }
	]])
	expect.equality(#result.sent, 0)
	expect.equality(result.open, false)
end

-- Multiple dispatch handlers can be registered for the same type; the
-- approval wiring uses dispatch.register from init.lua, so verify the
-- dispatch layer accepts the same handlers used by init.lua.

T["approval"]["dispatch wires approval_request to show"] = function()
	local result = child.lua([[
		local dispatch = require('pi-bridge.dispatch')
		local approval = require('pi-bridge.approval')
		approval.setup({ edit_approval_prompt = true })
		_G.approval_sent = {}
		local fake_send = function(msg) table.insert(_G.approval_sent, msg) end
		dispatch.register('approval_request', function(msg)
			approval.show(msg, fake_send)
		end)
		dispatch.dispatch({
			type = 'approval_request',
			id = 'wire-1',
			tool = 'edit',
			path = '/tmp/wire.lua',
			diff = 'wired diff\n',
		})
		local open = false
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			local c = vim.api.nvim_win_get_config(w)
			if c.relative and c.relative ~= '' then open = true break end
		end
		return { sent = _G.approval_sent, open = open }
	]])
	expect.equality(result.open, true)
	local saw_ack = false
	for _, m in ipairs(result.sent) do
		if m.type == "approval_ack" and m.id == "wire-1" then
			saw_ack = true
			break
		end
	end
	expect.equality(saw_ack, true)
end

T["approval"]["dispatch wires approval_resolved to resolve"] = function()
	child.lua([[
		local dispatch = require('pi-bridge.dispatch')
		local approval = require('pi-bridge.approval')
		approval.setup({ edit_approval_prompt = true })
		dispatch.register('approval_request', function(msg) approval.show(msg, function() end) end)
		dispatch.register('approval_resolved', function(msg) approval.resolve(msg.id) end)
		dispatch.dispatch({
			type = 'approval_request',
			id = 'wire-resolve',
			tool = 'edit',
			path = '/tmp/w.lua',
			diff = 'd\n',
		})
		dispatch.dispatch({ type = 'approval_resolved', id = 'wire-resolve' })
	]])
	expect.equality(float_open(child), false)
end

return T

