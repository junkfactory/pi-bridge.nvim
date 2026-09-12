-- Edit-approval prompt for pi edit/write requests.
--
-- When pi wants to modify a file it broadcasts an `approval_request`
-- over the bridge socket. This module renders the choice with
-- `vim.ui.select` — the same primitive the launch prompt uses — so the
-- picker follows whatever the user has configured (native menu,
-- snacks, fzf-lua, ...). pi's TUI already shows the diff as a widget
-- above the editor; Neovim is only the decision surface here.
--
-- Protocol notes:
--
--   Why ack immediately after the request arrives:
--   pi falls back to its own TUI overlay if it sees no `approval_ack`
--   within 1s. The picker opens synchronously on the main loop, so
--   acking right away beats the fallback timer with room to spare.
--
--   Why a dismissed picker counts as "no":
--   `vim.ui.select` calls back with nil on Esc/<C-c>. Treating that as
--   reject is the safe default — pi blocks the edit and the agent can
--   try a different approach.
--
--   Why `M.resolve(id)` only logs:
--   pi sends `approval_resolved` when it answered the request itself
--   (fallback overlay) and the picker is stale. vim.ui.select cannot
--   be dismissed programmatically; if the user still answers, pi
--   discards the late response (first resolution wins by id).
--
--   Why `schedule_ui` (defer when `vim.in_fast_event()`):
--   Dispatch handlers run from the socket's `pipe:read_start` callback,
--   a libuv fast event in which nvim_* APIs raise E5560. show() defers
--   to the main loop in that case and runs directly otherwise, so
--   direct callers (tests) keep synchronous semantics.

local log = require("pi-bridge.log")

local M = {}

local enabled = true
local showing = false

function M.setup(config)
	-- `false` is the explicit opt-out; anything else (including nil)
	-- means enabled — the dispatch wiring is unconditional, this only
	-- decides whether a picker opens.
	enabled = config.edit_approval_prompt ~= false
	log.debug("approval: setup, enabled=" .. tostring(enabled))
end

function M.is_enabled()
	return enabled
end

-- Run `fn` immediately in normal context, or deferred when called from
-- a libuv fast-event context (the socket's `pipe:read_start` callback).
-- nvim_* APIs raise E5560 in a fast event, so every entry point that
-- can be reached from socket callbacks must funnel through here.
local function schedule_ui(fn)
	if vim.in_fast_event() then
		vim.schedule(fn)
	else
		fn()
	end
end

-- True when a buffer with the target path open has unsaved changes —
-- the diff pi computed reads from disk and may not match the editor.
-- Paths are realpath-normalized because nvim resolves symlinks when
-- naming buffers (e.g. /tmp/x.lua becomes /private/tmp/x.lua on macOS).
local function normalized(path)
	return vim.uv.fs_realpath(path) or vim.fn.fnamemodify(path, ":p")
end

local function target_buffer_modified(path)
	local target = normalized(path)
	for _, buf in ipairs(vim.fn.getbufinfo({ bufmodified = 1 })) do
		if normalized(vim.api.nvim_buf_get_name(buf.bufnr)) == target then
			return true
		end
	end
	return false
end

local CHOICES = {
	{ label = "y — approve this edit", decision = "yes" },
	{ label = "a — approve all edits to this file (this session)", decision = "all" },
	{ label = "n — reject this edit", decision = "no" },
}

-- Send a response back to pi. pcall because the socket may have died
-- while the user was deciding.
local function send_response(send, id, decision)
	if type(send) ~= "function" then return end
	local ok, err = pcall(send, {
		type = "approval_response",
		id = id,
		decision = decision,
	})
	if not ok then
		log.error("approval: failed to send response: " .. tostring(err))
	end
end

-- Full show body. Runs in a UI-safe context (normal or scheduled via
-- `schedule_ui`) — vim.ui.select and the buffer checks below would
-- raise E5560 in a fast event context.
local function run_show(req, send)
	if showing then
		-- Defensive: pi should serialize. If two arrive, prefer the
		-- open picker and let pi's queue re-deliver later.
		log.warn("approval: request " .. tostring(req.id) .. " ignored; picker already open")
		return
	end

	local id = req.id
	if type(id) ~= "string" or id == "" then
		log.warn("approval: missing id, ignoring request")
		return
	end

	showing = true

	-- Ack immediately: pi must not start its 1s fallback timer for a
	-- prompt that is about to be on screen.
	if type(send) == "function" then
		local ok, err = pcall(send, { type = "approval_ack", id = id })
		if not ok then
			log.error("approval: failed to send ack: " .. tostring(err))
		end
	end

	local prompt = "approve edit: " .. (req.path or "")
	if target_buffer_modified(req.path) then
		prompt = prompt .. " [buffer has unsaved changes; diff is computed from disk]"
	end

	vim.ui.select(CHOICES, {
		prompt = prompt,
		format_item = function(item)
			return item.label
		end,
	}, function(choice)
		showing = false
		if choice == nil then
			-- Dismissed (Esc / <C-c>): reject is the safe default.
			log.info("approval: picker dismissed for " .. tostring(id))
			send_response(send, id, "no")
			return
		end
		log.info("approval: " .. id .. " -> " .. choice.decision)
		send_response(send, id, choice.decision)
	end)
end

function M.show(req, send)
	if not enabled then
		-- Opt-out path: pi falls back to its own TUI overlay after 1s
		-- because we never ack. Logged at info so users can confirm.
		log.info("approval: disabled, ignoring request " .. tostring(req and req.id))
		return
	end

	if type(req) ~= "table" then
		log.warn("approval: malformed request (not a table)")
		return
	end

	-- The socket callback runs in a libuv fast event; nvim_* APIs raise
	-- E5560 there. Defer to the main loop when needed (see schedule_ui).
	schedule_ui(function()
		run_show(req, send)
	end)
end

function M.resolve(id)
	-- approval_resolved means pi already answered (its fallback won).
	-- Nothing to close — a late picker answer is discarded by pi.
	log.info("approval: request " .. tostring(id) .. " resolved remotely")
end

-- Test-only: clear module state. Not part of the public API.
function M._reset()
	enabled = true
	showing = false
end

return M
