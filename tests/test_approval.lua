local MiniTest = require("mini.test")
local expect = MiniTest.expect

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set()

T["approval"] = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.start({ "-u", "scripts/minimal_init.lua" })
			child.lua("MiniTest = require('mini.test')")
			-- Global so every test snippet can reach the module.
			child.lua("approval = require('pi-bridge.approval')")
			-- Reset module state between cases.
			child.lua("require('pi-bridge.approval')._reset()")
		end,
		post_case = function()
			child.stop()
		end,
	},
})

-- Helper snippets for child.lua. Override vim.ui.select so tests can
-- choose deterministically without depending on the default picker UI
-- (same pattern as tests/test_launch.lua).
local MOCK_SELECT = [[
	_G._select_calls = {}
	vim.ui.select = function(items, opts, on_choice)
		table.insert(_G._select_calls, { items = items, opts = opts })
		_G._select_on_choice = on_choice
	end
	_G.approval_sent = {}
	_G.fake_send = function(msg) table.insert(_G.approval_sent, msg) end
]]

local function make_request(id)
	return string.format([[
		approval.show({
			type = 'approval_request',
			id = %q,
			tool = 'edit',
			path = '/tmp/example.lua',
			diff = '--- a/example.lua\n+++ b/example.lua\n',
		}, fake_send)
	]], id)
end

local function messages()
	return child.lua("return _G.approval_sent")
end

T["approval"]["show opens the picker and acks immediately"] = function()
	child.lua(MOCK_SELECT)
	child.lua("approval.setup({ edit_approval_prompt = true })")
	child.lua(make_request("req-1"))

	-- Ack must beat pi's 1s fallback timer: assert it was already sent.
	local sent = messages()
	expect.equality(#sent, 1)
	expect.equality(sent[1].type, "approval_ack")
	expect.equality(sent[1].id, "req-1")

	-- The picker got exactly the three y/a/n choices.
	local count = child.lua("return #_G._select_calls[1].items")
	expect.equality(count, 3)
end

T["approval"]["picker prompt names the file"] = function()
	child.lua(MOCK_SELECT)
	child.lua("approval.setup({ edit_approval_prompt = true })")
	child.lua(make_request("req-prompt"))

	local prompt = child.lua("return _G._select_calls[1].opts.prompt")
	expect.equality(prompt, "approve edit: /tmp/example.lua")
end

T["approval"]["choice 'y' sends decision yes"] = function()
	child.lua(MOCK_SELECT)
	child.lua("approval.setup({ edit_approval_prompt = true })")
	child.lua(make_request("req-y"))
	child.lua("_G._select_on_choice(_G._select_calls[1].items[1])")

	local sent = messages()
	expect.equality(#sent, 2)
	expect.equality(sent[2].type, "approval_response")
	expect.equality(sent[2].id, "req-y")
	expect.equality(sent[2].decision, "yes")
end

T["approval"]["choice 'a' sends decision all"] = function()
	child.lua(MOCK_SELECT)
	child.lua("approval.setup({ edit_approval_prompt = true })")
	child.lua(make_request("req-a"))
	child.lua("_G._select_on_choice(_G._select_calls[1].items[2])")

	local sent = messages()
	expect.equality(sent[2].decision, "all")
end

T["approval"]["choice 'n' sends decision no"] = function()
	child.lua(MOCK_SELECT)
	child.lua("approval.setup({ edit_approval_prompt = true })")
	child.lua(make_request("req-n"))
	child.lua("_G._select_on_choice(_G._select_calls[1].items[3])")

	local sent = messages()
	expect.equality(sent[2].decision, "no")
end

T["approval"]["dismissed picker (Esc) sends decision no"] = function()
	child.lua(MOCK_SELECT)
	child.lua("approval.setup({ edit_approval_prompt = true })")
	child.lua(make_request("req-esc"))
	child.lua("_G._select_on_choice(nil)")

	local sent = messages()
	expect.equality(#sent, 2)
	expect.equality(sent[2].decision, "no")
end

T["approval"]["picker records buffer-modified warning in the prompt"] = function()
	child.lua(MOCK_SELECT)
	child.lua([[
		approval.setup({ edit_approval_prompt = true })
		-- Real temp file so realpath matching works (buffer names resolve
		-- symlinks, so a nonexistent /tmp path wouldn't match).
		local file = vim.fn.tempname() .. '.lua'
		vim.fn.writefile({ 'old' }, file)
		_G._approval_target = file
		local buf = vim.fn.bufadd(file)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'dirty' })
	]])
	child.lua([[
		approval.show({
			type = 'approval_request',
			id = 'req-warn',
			tool = 'edit',
			path = _G._approval_target,
			diff = '--- a\n+++ b\n',
		}, fake_send)
	]])
	local prompt = child.lua("return _G._select_calls[1].opts.prompt")
	expect.equality(
		prompt:find("buffer has unsaved changes", 1, true) ~= nil,
		true
	)
end

T["approval"]["second request while picker is open is ignored"] = function()
	child.lua(MOCK_SELECT)
	child.lua("approval.setup({ edit_approval_prompt = true })")
	-- First request opens the picker (mock never calls on_choice).
	child.lua(make_request("req-1"))
	-- Second request while the picker is still open must not ack again.
	child.lua(make_request("req-2"))

	local sent = messages()
	expect.equality(#sent, 1)
	expect.equality(sent[1].id, "req-1")
end

T["approval"]["missing id is dropped without acking"] = function()
	child.lua(MOCK_SELECT)
	child.lua("approval.setup({ edit_approval_prompt = true })")
	child.lua("approval.show({ type = 'approval_request', tool = 'edit', path = '/tmp/x.lua' }, fake_send)")

	expect.equality(#messages(), 0)
	local calls = child.lua("return #_G._select_calls")
	expect.equality(calls, 0)
end

T["approval"]["disabled config acks nothing and opens no picker"] = function()
	child.lua(MOCK_SELECT)
	child.lua("approval.setup({ edit_approval_prompt = false })")
	child.lua(make_request("req-off"))

	expect.equality(#messages(), 0)
	local calls = child.lua("return #_G._select_calls")
	expect.equality(calls, 0)
end

T["approval"]["is_enabled reflects setup option"] = function()
	child.lua("approval.setup({ edit_approval_prompt = true })")
	expect.equality(child.lua("return approval.is_enabled()"), true)
	child.lua("approval.setup({ edit_approval_prompt = false })")
	expect.equality(child.lua("return approval.is_enabled()"), false)
end

T["approval"]["show defers UI work when called from a fast-event context"] = function()
	-- The real dispatch path calls show() from the socket's pipe read
	-- callback (a libuv fast event), where nvim_* APIs raise E5560.
	-- Simulate that context and verify the ack/picker happen after the
	-- scheduled callback runs.
	child.lua(MOCK_SELECT)
	child.lua([[
		approval.setup({ edit_approval_prompt = true })
		local real = vim.in_fast_event
		vim.in_fast_event = function() return true end
		approval.show({
			id = 'req-fast',
			tool = 'edit',
			path = '/tmp/fast.lua',
			diff = '--- a\n+++ b\n',
		}, fake_send)
		vim.in_fast_event = real

		local immediate_acks = #_G.approval_sent
		local acked = vim.wait(200, function() return #_G.approval_sent > 0 end, 10)
		return { immediate_acks = immediate_acks, acked = acked }
	]])
	local result = child.lua([[
		local calls = #_G._select_calls
		return { acks = #_G.approval_sent, calls = calls }
	]])
	expect.equality(result.acks, 1)
	expect.equality(result.calls, 1)
end

T["approval"]["resolve is safe with or without an open picker"] = function()
	child.lua("approval.setup({ edit_approval_prompt = true })")
	-- No picker open: must not error.
	expect.equality(child.lua("return select(1, pcall(approval.resolve, 'req-x'))"), true)
	-- Picker open (mock never resolves): resolve only logs, no crash.
	child.lua(MOCK_SELECT)
	child.lua(make_request("req-open"))
	expect.equality(child.lua("return select(1, pcall(approval.resolve, 'req-open'))"), true)
end

T["approval"]["dispatch wires approval_request to show"] = function()
	child.lua(MOCK_SELECT)
	child.lua([[
		approval.setup({ edit_approval_prompt = true })
		local dispatch = require('pi-bridge.dispatch')
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
	]])
	local sent = messages()
	local saw_ack = false
	for _, m in ipairs(sent) do
		if m.type == "approval_ack" and m.id == "wire-1" then
			saw_ack = true
			break
		end
	end
	expect.equality(saw_ack, true)
end

-- ---------------------------------------------------------------------------
-- New-design behaviors: stock detection, resolve-dismissal, pi-disconnect
-- ---------------------------------------------------------------------------

T["approval"]["is_stock_picker detects stock vs wrapped by source"] = function()
	child.lua("approval.setup({ edit_approval_prompt = true })")
	-- Headless test env: vim.ui.select is the runtime builtin → stock.
	expect.equality(child.lua("return approval.is_stock_picker()"), true)
	-- Wrap it (any non-runtime source) → not stock.
	child.lua([[
		local stock = vim.ui.select
		vim.ui.select = function(items, opts, on_choice) stock(items, opts, on_choice) end
	]])
	expect.equality(child.lua("return approval.is_stock_picker()"), false)
end

T["approval"]["stock path routes to the fallback float, not vim.ui.select"] = function()
	child.lua("approval.setup({ edit_approval_prompt = true }) _G.approval_sent = {} _G.fake_send = function(msg) table.insert(_G.approval_sent, msg) end")
	-- No mock installed: stock builtin active. show() must open the float.
	child.lua(make_request("fs-route"))
	expect.equality(child.lua("return require('pi-bridge.fallback-select').is_open()"), true)
	local sent = messages()
	expect.equality(#sent, 1) -- ack only
	expect.equality(sent[1].type, "approval_ack")
end

T["approval"]["resolve(id) dismisses the fallback float without responding"] = function()
	child.lua("approval.setup({ edit_approval_prompt = true }) _G.approval_sent = {} _G.fake_send = function(msg) table.insert(_G.approval_sent, msg) end")
	child.lua(make_request("fs-resolve"))
	child.lua("approval.resolve('fs-resolve')")
	expect.equality(child.lua("return require('pi-bridge.fallback-select').is_open()"), false)
	expect.equality(#messages(), 1) -- ack only; no response sent
end

T["approval"]["resolve from a fast event dismisses the float (E5560 regression)"] = function()
	-- The socket dispatches handlers from libuv callbacks — fast events
	-- in which nvim_* APIs raise E5560. resolve() must defer to the main
	-- loop instead of crashing mid-close (which used to leave the float
	-- visible with dead keymaps and a stale current_id that swallowed
	-- every later approval_request).
	child.lua("approval.setup({ edit_approval_prompt = true }) _G.approval_sent = {} _G.fake_send = function(msg) table.insert(_G.approval_sent, msg) end")
	child.lua(make_request("fast-1"))
	expect.equality(child.lua("return require('pi-bridge.fallback-select').is_open()"), true)
	child.lua([[
		local timer = vim.uv.new_timer()
		timer:start(0, 0, function()
			approval.resolve('fast-1')
		end)
	]])
	child.lua("vim.wait(2000, function() return not require('pi-bridge.fallback-select').is_open() end)")
	expect.equality(child.lua("return require('pi-bridge.fallback-select').is_open()"), false)
	expect.equality(#messages(), 1) -- ack only; no response sent
	-- The state must not be poisoned: a follow-up request still opens.
	child.lua(make_request("fast-2"))
	expect.equality(child.lua("return require('pi-bridge.fallback-select').is_open()"), true)
end

T["approval"]["on_remote_disconnect from a fast event closes the float"] = function()
	child.lua("approval.setup({ edit_approval_prompt = true }) _G.approval_sent = {} _G.fake_send = function(msg) table.insert(_G.approval_sent, msg) end")
	child.lua(make_request("dc-fast"))
	expect.equality(child.lua("return require('pi-bridge.fallback-select').is_open()"), true)
	child.lua([[
		_G._notified = {}
		vim.notify = function(msg, level)
			table.insert(_G._notified, { msg = msg, level = level })
		end
		local timer = vim.uv.new_timer()
		timer:start(0, 0, function()
			approval.on_remote_disconnect()
		end)
	]])
	child.lua("vim.wait(2000, function() return not require('pi-bridge.fallback-select').is_open() end)")
	expect.equality(child.lua("return require('pi-bridge.fallback-select').is_open()"), false)
	expect.equality(#messages(), 1) -- ack only; nothing sent on disconnect
	child.lua("vim.wait(2000, function() return #_G._notified > 0 end)")
	local notified = child.lua("return _G._notified")
	expect.equality(#notified, 1)
	expect.equality(notified[1].msg, "pi-bridge: pi disconnected")
end

T["approval"]["wrapper path: resolve(id) dismisses without sending a response"] = function()
	-- Simulate a plugin picker: non-stock select that stores on_choice
	-- (async — never calls it on its own).
	child.lua([[
		approval.setup({ edit_approval_prompt = true })
		_G._plugin_on_choice = nil
		local stock = vim.ui.select
		vim.ui.select = function(items, opts, on_choice)
			_G._plugin_on_choice = on_choice
		end
		_G.approval_sent = {}
		_G.fake_send = function(msg) table.insert(_G.approval_sent, msg) end
	]])
	child.lua(make_request("wrap-1"))
	-- Wrapper installed on top of the mock; the request is pending.
	local sent = messages()
	expect.equality(#sent, 1)
	expect.equality(sent[1].type, "approval_ack")
	-- pi answered first (approval_resolved) → dismiss, no response.
	child.lua("approval.resolve('wrap-1')")
	expect.equality(#messages(), 1)
	-- The plugin's eventual on_choice(nil) must NOT send "no".
	child.lua("_G._plugin_on_choice(nil)")
	expect.equality(#messages(), 1)
end

T["approval"]["wrapper dismiss closes a picker instance returned by the plugin select"] = function()
	-- snacks.picker.select returns the live picker object from
	-- Snacks.picker.pick — that return value is the precise dismiss
	-- handle and must be closed on resolve().
	child.lua([[
		approval.setup({ edit_approval_prompt = true })
		_G._closed = 0
		local stock = vim.ui.select
		vim.ui.select = function(items, opts, on_choice)
			_G._plugin_on_choice = on_choice
			return { close = function() _G._closed = _G._closed + 1 end }
		end
		_G.approval_sent = {}
		_G.fake_send = function(msg) table.insert(_G.approval_sent, msg) end
	]])
	child.lua(make_request("wrap-ret"))
	child.lua("approval.resolve('wrap-ret')")
	expect.equality(child.lua("return _G._closed"), 1)
	-- No response sent (the eventual on_choice(nil) is intercepted).
	child.lua("_G._plugin_on_choice(nil)")
	expect.equality(#messages(), 1)
end

T["approval"]["wrapper dismiss falls back to snacks.picker.get when the select returns nothing"] = function()
	-- Regression: the old code probed a nonexistent snacks.picker.current
	-- and silently skipped the close. The fallback must sweep the
	-- source="select" pickers via snacks.picker.get.
	child.lua([[
		package.loaded.snacks = {
			picker = {
				get = function(opts)
					_G._snacks_get_opts = opts
					return { { close = function() _G._snacks_closed = (_G._snacks_closed or 0) + 1 end } }
				end,
			},
		}
		approval.setup({ edit_approval_prompt = true })
		local stock = vim.ui.select
		vim.ui.select = function(items, opts, on_choice)
			_G._plugin_on_choice = on_choice
		end
		_G.approval_sent = {}
		_G.fake_send = function(msg) table.insert(_G.approval_sent, msg) end
	]])
	child.lua(make_request("wrap-snacks"))
	child.lua("approval.resolve('wrap-snacks')")
	expect.equality(child.lua("return _G._snacks_closed"), 1)
	local get_opts = child.lua("return _G._snacks_get_opts")
	expect.equality(get_opts.source, "select")
end

T["approval"]["wrapper path: user choice still sends the decision"] = function()
	child.lua([[
		approval.setup({ edit_approval_prompt = true })
		_G._plugin_on_choice = nil
		local stock = vim.ui.select
		vim.ui.select = function(items, opts, on_choice)
			_G._plugin_on_choice = on_choice
		end
		_G.approval_sent = {}
		_G.fake_send = function(msg) table.insert(_G.approval_sent, msg) end
	]])
	child.lua(make_request("wrap-2"))
	child.lua("_G._plugin_on_choice({ label = 'y — yes to this edit', decision = 'yes' })")
	local sent = messages()
	expect.equality(#sent, 2)
	expect.equality(sent[2].type, "approval_response")
	expect.equality(sent[2].decision, "yes")
end

T["approval"]["wrapper call-through invokes the picker present at install time"] = function()
	-- Regression: a picker that wraps AFTER setup() must still receive the
	-- call (not the stock builtin, which blocks).
	child.lua("approval.setup({ edit_approval_prompt = true })") -- captures stock
	child.lua([[
		_G._plugin_called = false
		local stock = vim.ui.select
		vim.ui.select = function(items, opts, on_choice)
			_G._plugin_called = true
			_G._plugin_on_choice = on_choice
		end
	]])
	child.lua(make_request("wrap-3"))
	expect.equality(child.lua("return _G._plugin_called"), true)
end

T["approval"]["on_remote_disconnect closes the float, notifies, sends nothing"] = function()
	child.lua("approval.setup({ edit_approval_prompt = true }) _G.approval_sent = {} _G.fake_send = function(msg) table.insert(_G.approval_sent, msg) end")
	child.lua([[
		_G._notified = {}
		vim.notify = function(msg, level)
			table.insert(_G._notified, { msg = msg, level = level })
		end
	]])
	child.lua(make_request("dc-1"))
	expect.equality(child.lua("return require('pi-bridge.fallback-select').is_open()"), true)
	child.lua("approval.on_remote_disconnect()")
	expect.equality(child.lua("return require('pi-bridge.fallback-select').is_open()"), false)
	expect.equality(child.lua("return #_G.approval_sent"), 1) -- ack only
	local notified = child.lua("return _G._notified")
	expect.equality(#notified, 1)
	expect.equality(notified[1].msg, "pi-bridge: pi disconnected")
end

T["approval"]["on_remote_disconnect dismisses the wrapped picker without responding"] = function()
	child.lua([[
		approval.setup({ edit_approval_prompt = true })
		_G._plugin_on_choice = nil
		local stock = vim.ui.select
		vim.ui.select = function(items, opts, on_choice)
			_G._plugin_on_choice = on_choice
		end
		_G._notified = {}
		vim.notify = function(msg, level) _G._notified[#_G._notified + 1] = msg end
		_G.approval_sent = {}
		_G.fake_send = function(msg) table.insert(_G.approval_sent, msg) end
	]])
	child.lua(make_request("dc-2"))
	child.lua("approval.on_remote_disconnect()")
	expect.equality(child.lua("return #_G.approval_sent"), 1) -- ack only; no response
	-- The plugin's eventual nil callback is guarded → still no response.
	child.lua("_G._plugin_on_choice(nil)")
	expect.equality(child.lua("return #_G.approval_sent"), 1)
	expect.equality(child.lua("return #_G._notified >= 1"), true)
end

T["approval"]["on_remote_disconnect with no picker open is a no-op"] = function()
	child.lua(
		"approval.setup({ edit_approval_prompt = true })"
			.. " _G.approval_sent = {}"
			.. " _G.fake_send = function(msg) table.insert(_G.approval_sent, msg) end"
	)
	expect.equality(child.lua("return select(1, pcall(approval.on_remote_disconnect))"), true)
	expect.equality(child.lua("return #_G.approval_sent"), 0)
end

return T
