-- Edit-approval prompt for pi edit/write requests.
--
-- When pi wants to modify a file it broadcasts an `approval_request`
-- over the bridge socket. This module renders the choice via the
-- user's configured picker:
--
--   * Stock `vim.ui.select` — inputlist blocks and cannot be closed
--     remotely. We use `pi-bridge.fallback-select`, a minimal owned
--     float with buffer-local y/a/n/Esc maps, owned close().
--
--   * Plugin picker (dressing / snacks / fzf-lua / ...) — installs
--     a thin wrapper around `vim.ui.select` that keeps a per-request
--     dismiss handle. `vim.ui.select` is called with a wrapped
--     `on_choice` so we can intercept remote dismissals.
--
-- pi's TUI also shows its own y/a/n prompt for the same request.
-- Whichever answers first wins; pi broadcasts `approval_resolved`
-- when it answers, nvim dismisses its picker via `M.resolve(id)`.
--
-- Protocol notes:
--
--   Why ack immediately after the request arrives:
--   pi suppresses its TUI prompt once it sees `approval_ack` (older
--   fallback behavior). Acking on receipt keeps the protocol happy
--   with both old and new pi versions.
--
--   Why a user-dismissed picker still counts as "no":
--   `vim.ui.select` (and most plugin replacements) call back with
--   nil on Esc/<C-c>. Treating that as reject is the safe default —
--   pi blocks the edit and the agent can try a different approach.
--
--   Why `M.resolve(id)` actually dismisses the picker:
--   The previous design relied on `vim.ui.select` being non-closable
--   (a stock inputlist). With the wrapper path the picker CAN be
--   closed, so we install per-id dismiss handles and call them here
--   when pi broadcasts `approval_resolved`. The fallback float owns
--   its own close. No response is sent in either case.
--
--   Why `schedule_ui` (defer when `vim.in_fast_event()`):
--   Dispatch handlers run from the socket's `pipe:read_start` callback,
--   a libuv fast event in which nvim_* APIs raise E5560. Every entry
--   point that touches the UI (show, resolve, on_remote_disconnect)
--   defers to the main loop in that case and runs directly otherwise,
--   so direct callers (tests) keep synchronous semantics.
--
--   Why capture `vim.ui.select` at `setup()` time:
--   The captured function is only the wrapper path's call-through
--   target (what gets invoked when our wrapper is installed on top).
--   Stock-vs-plugin detection is source-based (see is_stock_picker),
--   so setup() ordering relative to picker plugins does not matter.

local log = require("pi-bridge.log")
local fallback = require("pi-bridge.fallback-select")

local M = {}

local enabled = true

-- Setup-time state.
local original_select = nil -- captured at M.setup()
local wrapper_installed = false

-- Request state: only one request in flight at a time. pi serializes.
local current_id = nil
local current_send = nil

-- UI-safe bodies of resolve()/on_remote_disconnect() — forward-declared
-- because the public wrappers schedule them (see schedule_ui below).
local resolve_sync
local on_remote_disconnect_sync

-- Per-request dismiss handles for the wrapper (plugin picker) path.
-- Keyed by approval_request id so resolve() / on_remote_disconnect()
-- can target the right one.
local pending = {}

-- Guard flag: set when the picker is dismissed remotely, so the
-- plugin's eventual on_choice(nil) (from its own cancel path) does
-- NOT trigger a user-Esc "no" response.
local dismissed_remote = {}

local function schedule_ui(fn)
	if vim.in_fast_event() then
		vim.schedule(fn)
	else
		fn()
	end
end

function M.setup(config)
	-- `false` is the explicit opt-out; anything else (including nil)
	-- means enabled — the dispatch wiring is unconditional, this only
	-- decides whether a picker opens.
	enabled = config.edit_approval_prompt ~= false

	-- Capture `vim.ui.select` once, only so `_reset()` can restore the
	-- pre-wrapper state (tests). Stock-vs-plugin detection is source-based
	-- (see is_stock_picker) and the wrapper's call-through target is
	-- captured at install time, so setup() ordering does not matter.
	original_select = original_select or vim.ui.select

	log.debug("approval: setup, enabled=" .. tostring(enabled))
end

function M.is_enabled()
	return enabled
end

function M.is_stock_picker()
	-- Stock detection by SOURCE, not by reference: the built-in select
	-- is defined in nvim's own runtime (…/runtime/lua/vim/ui.lua); every
	-- wrapper plugin (dressing, snacks, fzf-lua, our own wrapper) is a
	-- different file or an anonymous chunk. Reference comparison is
	-- unreliable because setup() may run before or after plugins wrap.
	local sel = vim.ui.select
	if type(sel) ~= "function" then return true end
	local source = debug.getinfo(sel, "S").source or ""
	return source:match("vim[/\\]ui%.lua$") ~= nil
end

-- Send a response back to pi. pcall because the socket may have died
-- while the user was deciding.
local function send_response(id, decision)
	if type(current_send) ~= "function" then return end
	local ok, err = pcall(current_send, {
		type = "approval_response",
		id = id,
		decision = decision,
	})
	if not ok then
		log.error("approval: failed to send response: " .. tostring(err))
	end
end

local function clear_current()
	current_id = nil
	current_send = nil
end

-- Stock picker path: render via fallback-select.
local function run_stock(req)
	fallback.show(req, function(msg)
		-- Forward through the original send captured at show() time.
		if type(current_send) ~= "function" then return end
		local ok, err = pcall(current_send, msg)
		if not ok then
			log.error("approval: fallback send failed: " .. tostring(err))
		end
	end)
end

-- Plugin picker path: wrap vim.ui.select once. The wrapper stores a
-- dismiss handle per pending id and intercepts the plugin's eventual
-- on_choice(nil) when remote-dismissed.
local function install_wrapper()
	if wrapper_installed then return end
	-- Call-through target: whatever vim.ui.select is at INSTALL time —
	-- normally the plugin's wrapper (dressing/snacks/...), since we only
	-- take this path when a non-stock picker is detected. Capturing at
	-- install (not setup) means a plugin that wrapped vim.ui.select
	-- after our setup() is still called correctly instead of falling
	-- through to the blocking stock builtin.
	local call_through = vim.ui.select

	local function wrapper(items, opts, on_choice)
		local id = current_id
		if type(id) ~= "string" then
			-- Defensive: fall back to native behavior.
			call_through(items, opts, on_choice)
			return
		end

		local wrapped_on_choice = function(choice)
			if dismissed_remote[id] then
				dismissed_remote[id] = nil
				pending[id] = nil
				log.info("approval: picker dismissed remotely for " .. tostring(id))
				return
			end
			pending[id] = nil
			on_choice(choice)
		end

		pending[id] = {
			dismiss = function()
				if dismissed_remote[id] then return end
				dismissed_remote[id] = true
				log.info("approval: remote dismiss for " .. tostring(id))
				-- Best-effort: ask known plugins to close their picker.
				-- The eventual on_choice(nil) is intercepted by
				-- dismissed_remote above, so no response is sent.
				pcall(function()
					local m = require("dressing.select.builtin")
					if m and m.cancel then m.cancel() end
				end)
				pcall(function()
					local s = require("snacks")
					if s and s.picker and s.picker.current then
						local p = s.picker.current()
						if p and p.close then p:close() end
					end
				end)
			end,
		}

		call_through(items, opts, wrapped_on_choice)
	end

	vim.ui.select = wrapper
	wrapper_installed = true
	log.debug("approval: installed vim.ui.select wrapper")
end

local function run_plugin(req)
	install_wrapper()

	-- Build the prompt (same shape as the legacy path).
	local prompt = "approve edit: " .. (req.path or "")
	if req.path then
		local target = vim.uv.fs_realpath(req.path)
			or vim.fn.fnamemodify(req.path, ":p")
		for _, buf in ipairs(vim.fn.getbufinfo({ bufmodified = 1 })) do
			local buf_path = vim.api.nvim_buf_get_name(buf.bufnr)
			if buf_path ~= "" then
				local resolved = vim.uv.fs_realpath(buf_path)
					or vim.fn.fnamemodify(buf_path, ":p")
				if resolved == target then
					prompt = prompt
						.. " [buffer has unsaved changes; diff is computed from disk]"
					break
				end
			end
		end
	end

	local CHOICES = {
		{ label = "y — approve this edit", decision = "yes" },
		{ label = "a — approve all edits to this file (this session)", decision = "all" },
		{ label = "n — reject this edit", decision = "no" },
	}

	vim.ui.select(CHOICES, {
		prompt = prompt,
		format_item = function(item)
			return item.label
		end,
	}, function(choice)
		if current_id ~= req.id then
			-- Stale callback (request already cleared by resolve /
			-- remote disconnect). Drop.
			return
		end
		-- Capture the send fn BEFORE clear_current() nils it —
		-- send_response reads the module-level current_send.
		local send = current_send
		local function respond(dec)
			if type(send) ~= "function" then return end
			local ok, err = pcall(send, {
				type = "approval_response",
				id = req.id,
				decision = dec,
			})
			if not ok then
				log.error("approval: failed to send response: " .. tostring(err))
			end
		end
		clear_current()
		if choice == nil then
			log.info("approval: picker dismissed for " .. tostring(req.id))
			respond("no")
			return
		end
		log.info("approval: " .. req.id .. " -> " .. choice.decision)
		respond(choice.decision)
	end)
end

-- Full show body. Runs in a UI-safe context (normal or scheduled via
-- `schedule_ui`) — picker APIs and the buffer checks would raise
-- E5560 in a fast event context.
local function run_show(req)
	if current_id ~= nil then
		-- Defensive: pi should serialize. If two arrive, prefer the
		-- open picker and let pi's queue re-deliver later.
		log.warn(
			"approval: request "
				.. tostring(req.id)
				.. " ignored; picker already open for "
				.. tostring(current_id)
		)
		return
	end

	local id = req.id
	if type(id) ~= "string" or id == "" then
		log.warn("approval: missing id, ignoring request")
		return
	end

	current_id = id

	-- Ack immediately so older pi (which shows its fallback overlay
	-- without ack) does not duplicate the prompt.
	if type(current_send) == "function" then
		local ok, err = pcall(current_send, { type = "approval_ack", id = id })
		if not ok then
			log.error("approval: failed to send ack: " .. tostring(err))
		end
	end

	if M.is_stock_picker() then
		run_stock(req)
	else
		run_plugin(req)
	end
end

function M.show(req, send)
	if not enabled then
		-- Opt-out path: pi shows its own prompt (no ack arrives within
		-- the timeout). Logged at info so users can confirm.
		log.info("approval: disabled, ignoring request " .. tostring(req and req.id))
		return
	end

	if type(req) ~= "table" then
		log.warn("approval: malformed request (not a table)")
		return
	end

	-- Capture the send fn for this request. Cleared when the request
	-- settles (answer, resolve, or remote disconnect).
	current_send = send

	-- The socket callback runs in a libuv fast event; nvim_* APIs raise
	-- E5560 there. Defer to the main loop when needed (see schedule_ui).
	schedule_ui(function()
		run_show(req)
	end)
end

-- Dismiss the picker for a request id without sending a response.
-- Called when pi broadcasts `approval_resolved` (pi already answered).
-- UI-safe: the dispatch handler runs in a fast event, and dismissal
-- touches window APIs (E5560 there) — defer like show() does.
function M.resolve(id)
	if id == nil then return end
	schedule_ui(function()
		resolve_sync(id)
	end)
end

function resolve_sync(id)
	local handle = pending[id]
	if handle and type(handle.dismiss) == "function" then
		-- Wrapper path: trigger the plugin's cancel. The wrapper
		-- intercepts the eventual on_choice(nil) via dismissed_remote.
		handle.dismiss()
	elseif fallback.is_open() and fallback.get_pending_id() == id then
		-- Fallback float path: silent close (no echo, no response).
		fallback.close()
		log.info("approval: fallback closed for resolved " .. tostring(id))
	end
	if current_id == id then
		clear_current()
	end
end

-- Remote disconnect handler: dismiss any open picker, echo "pi
-- disconnected", send nothing. The user's Esc/answer path is
-- unaffected (those happen inside the picker callbacks before
-- this fires).
function M.on_remote_disconnect()
	-- UI-safe for the same reason as resolve(): callers may invoke this
	-- straight from the socket's fast event (init.lua schedules it too,
	-- but the module must not rely on caller discipline).
	schedule_ui(function()
		on_remote_disconnect_sync()
	end)
end

function on_remote_disconnect_sync()
	-- One user-facing message for the disconnect, regardless of which
	-- picker path is active. close() (not close_silent) for the fallback
	-- float so the notify below is the only echo.
	if fallback.is_open() then
		fallback.close()
	end
	-- Walk all pending wrappers; each gets a dismiss (no echo — the
	-- single "pi disconnected" notify below covers the user-facing
	-- message for both paths).
	for id, handle in pairs(pending) do
		if type(handle.dismiss) == "function" then
			handle.dismiss()
		end
		pending[id] = nil
	end
	if current_id ~= nil then
		clear_current()
		vim.schedule(function()
			vim.notify("pi-bridge: pi disconnected", vim.log.levels.WARN)
		end)
	else
		-- No request was in flight, but for symmetry still log.
		log.debug("approval: remote disconnect, no picker open")
	end
end

-- Test-only: clear module state. Not part of the public API.
function M._reset()
	enabled = true
	current_id = nil
	current_send = nil
	pending = {}
	dismissed_remote = {}
	-- Restore vim.ui.select to the captured original (test may have
	-- installed a wrapper that must not leak into the next case).
	if wrapper_installed and original_select then
		vim.ui.select = original_select
	end
	wrapper_installed = false
	original_select = nil
	fallback._reset()
end

return M
