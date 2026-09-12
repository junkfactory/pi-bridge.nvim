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

return T
