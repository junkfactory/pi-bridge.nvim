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
--   when pi broadcasts `approval_resolved`. Some pickers return a
--   dismissable instance from vim.ui.select (snacks.picker.select
--   returns the picker object) — that return value is the precise
--   handle and is tried first; dressing's cancel and a snacks
--   `picker.get({ source = "select" })` sweep are fallbacks. The
--   fallback float owns its own close. No response is sent in either
--   case.
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

-- Per-request state, keyed by approval_request id. Each entry owns the
-- send fn for its own request and (plugin-picker path) its dismiss
-- handle, so a late callback or a stale resolve() for a settled id can
-- never read or clobber another request's state. Fields:
--   send     fn(msg) — the socket sender captured at show() time
--   open     true once the picker for this id actually opened
--   dismiss  fn — best-effort picker close (wrapper path only)
local requests = {}

-- Id of the request whose picker is opening right now. Set only for the
-- duration of the synchronous vim.ui.select call run_plugin makes, so the
-- installed wrapper cannot pick up another request's id; nil means "not
-- an approval call" and falls through to native behavior.
local opening_id = nil

-- UI-safe bodies of resolve()/on_remote_disconnect() — forward-declared
-- because the public wrappers schedule them (see schedule_ui below).
local resolve_sync
local on_remote_disconnect_sync

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

-- Send a response to pi for ONE request, through that request's own
-- sender. pcall because the socket may have died while the user was
-- deciding.
local function respond(send, id, decision)
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

-- Id of the request whose picker is currently open, if any.
local function open_id()
	for id, entry in pairs(requests) do
		if entry.open then return id end
	end
end

-- Stock picker path: render via fallback-select.
local function run_stock(req, send)
	fallback.show(req, function(msg)
		-- The float answered (or dismissed-as-reject): the request is
		-- settled, so drop its state locally. Do not rely on the
		-- `approval_resolved` echo — a user answer may never get one.
		requests[req.id] = nil
		-- Forward through the sender captured at show() time.
		if type(send) ~= "function" then return end
		local ok, err = pcall(send, msg)
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
		local id = opening_id
		local entry = type(id) == "string" and requests[id] or nil
		if not entry then
			-- Not an approval call (or the request settled before the
			-- picker opened): fall back to native behavior.
			call_through(items, opts, on_choice)
			return
		end

		local wrapped_on_choice = function(choice)
			if dismissed_remote[id] then
				dismissed_remote[id] = nil
				requests[id] = nil
				log.info("approval: picker dismissed remotely for " .. tostring(id))
				return
			end
			-- The request entry is cleared by run_plugin's on_choice below
			-- (it needs it to tell a live answer from a stale one).
			on_choice(choice)
		end

		-- Some pickers return a dismissable instance (snacks.picker.select
		-- returns the picker object); others return nothing (dressing). The
		-- dismiss handle is installed BEFORE the call so a synchronous
		-- on_choice(nil) can't race it, and `ret` is filled in after.
		local ret
		entry.dismiss = function()
			if dismissed_remote[id] then return end
			dismissed_remote[id] = true
			log.info("approval: remote dismiss for " .. tostring(id))
			-- Precise handle: the instance the picker returned us.
			if type(ret) == "table" and type(ret.close) == "function" then
				pcall(ret.close, ret)
				return
			end
			-- Best-effort fallbacks for pickers that return nothing.
			pcall(function()
				local m = require("dressing.select.builtin")
				if m and m.cancel then m.cancel() end
			end)
			pcall(function()
				local s = require("snacks")
				if s and s.picker and s.picker.get then
					for _, p in ipairs(s.picker.get({ source = "select" })) do
						if p and p.close then p:close() end
					end
				end
			end)
		end

		ret = call_through(items, opts, wrapped_on_choice)
	end

	vim.ui.select = wrapper
	wrapper_installed = true
	log.debug("approval: installed vim.ui.select wrapper")
end

local function run_plugin(req, send)
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

	-- Label choice matters: snacks.picker (and other fuzzy pickers)
	-- filter items as the user types. The y item must not contain the
	-- letters 'a' or 'n' anywhere, and the n item must not contain 'a'
	-- or 'y', so typing a key fuzzy-matches only its own item (typing
	-- 'a' used to select y because both items contained "approve").
	local CHOICES = {
		{ label = "y — yes to this edit", decision = "yes" },
		{ label = "a — approve all edits to this file (this session)", decision = "all" },
		{ label = "n — reject this edit", decision = "no" },
	}

	opening_id = req.id
	local ok_call, err_call = pcall(vim.ui.select, CHOICES, {
		prompt = prompt,
		format_item = function(item)
			return item.label
		end,
	}, function(choice)
		if requests[req.id] == nil then
			-- Stale callback: this request already settled (answered,
			-- resolved remotely, or pi disconnected). Never answer a
			-- settled id — and never silently: a real choice arriving
			-- here means a picker called back twice.
			if choice ~= nil then
				log.warn("approval: dropping stale choice for " .. tostring(req.id))
			end
			return
		end
		-- Only this request's state is cleared; other ids are untouched.
		requests[req.id] = nil
		if choice == nil then
			log.info("approval: picker dismissed for " .. tostring(req.id))
			respond(send, req.id, "no")
			return
		end
		log.info("approval: " .. req.id .. " -> " .. choice.decision)
		respond(send, req.id, choice.decision)
	end)
	opening_id = nil
	if not ok_call then
		-- Re-raise: same propagation as before, but opening_id is reset
		-- first so a failed picker cannot mislabel a later select call.
		error(err_call)
	end
end

-- Full show body. Runs in a UI-safe context (normal or scheduled via
-- `schedule_ui`) — picker APIs and the buffer checks would raise
-- E5560 in a fast event context.
local function run_show(req)
	local entry = requests[req.id]
	if not entry then
		-- Settled while the UI callback was queued (fast-event path).
		log.debug("approval: request " .. tostring(req.id) .. " settled before show")
		return
	end

	local open = open_id()
	if open and open ~= req.id then
		-- A request arriving while another id's picker is open means that
		-- picker's request already settled (pi broadcasts
		-- `approval_resolved` before the next request; the echo may be
		-- dropped). Replace the stale picker: dismiss it silently — no
		-- response for the stale id — and show the new request.
		log.warn("approval: replacing stale picker for " .. tostring(open))
		resolve_sync(open)
	elseif open then
		-- Same id shown twice: the open picker still owns it. Keep the
		-- state (clearing it would drop the live picker's answer).
		log.warn("approval: duplicate show for " .. tostring(req.id) .. " ignored")
		return
	end

	entry.open = true
	local send = entry.send

	-- Ack immediately so older pi (which shows its fallback overlay
	-- without ack) does not duplicate the prompt.
	if type(send) == "function" then
		local ok, err = pcall(send, { type = "approval_ack", id = req.id })
		if not ok then
			log.error("approval: failed to send ack: " .. tostring(err))
		end
	end

	if M.is_stock_picker() then
		run_stock(req, send)
	else
		run_plugin(req, send)
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

	local id = req.id
	if type(id) ~= "string" or id == "" then
		log.warn("approval: missing id, ignoring request")
		return
	end

	-- The request owns its send fn: cleared when THIS request settles
	-- (answer, resolve, or remote disconnect), never shared.
	local existing = requests[id]
	if existing and existing.open then
		-- Same id re-shown while its picker is still open: keep the live
		-- entry (send/dismiss/open) so run_show's duplicate branch can
		-- drop the repeat. Replacing it would open a second picker and
		-- lose the live one's answer path.
		log.debug("approval: duplicate show for " .. id .. " (picker open), keeping state")
	else
		requests[id] = { send = send }
	end

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
	-- Only THIS request's state is touched: a resolve for an already
	-- settled id finds nothing and leaves newer requests alone.
	local entry = requests[id]
	requests[id] = nil
	if entry and type(entry.dismiss) == "function" then
		-- Wrapper path: trigger the plugin's cancel. The wrapper
		-- intercepts the eventual on_choice(nil) via dismissed_remote.
		entry.dismiss()
	elseif fallback.is_open() and fallback.get_pending_id() == id then
		-- Fallback float path: silent close (no echo, no response).
		fallback.close()
		log.info("approval: fallback closed for resolved " .. tostring(id))
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
	-- Walk all live requests; each gets a dismiss (no echo — the single
	-- "pi disconnected" notify below covers the user-facing message for
	-- both paths).
	local had_request = false
	for id, entry in pairs(requests) do
		had_request = true
		if type(entry.dismiss) == "function" then
			entry.dismiss()
		end
		requests[id] = nil
	end
	if had_request then
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
	requests = {}
	dismissed_remote = {}
	opening_id = nil
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
