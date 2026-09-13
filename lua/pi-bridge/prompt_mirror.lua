-- UI prompt mirror for pi extension prompts.
--
-- When a turn is started from Neovim (`<leader>ai`) and any pi extension
-- raises a blocking prompt (`ctx.ui.select` / `ctx.ui.confirm` / a custom
-- `ctx.ui.custom` component), pi-bridge mirrors it into Neovim so the user
-- can answer from either surface — first answer wins, the other cleans up.
--
-- Surface types:
--
--   select / confirm — `vim.ui.select` with the ORIGINAL option labels as
--   items and a `format_item` that trims long labels for display only. The
--   picker receives the full original label back, so the value sent over
--   the wire is never display-trimmed. Plugin pickers (dressing, snacks,
--   fzf-lua) are supported by capturing the instance's `close` method
--   from the picker's return value (same pattern as `approval.lua`).
--   Stock `vim.ui.select` (which blocks in `inputlist()` and cannot be
--   dismissed programmatically) is unsupported for mirror; we open our
--   own minimal float with numbered keys 1..9 + Esc, mirroring the gate's
--   fallback pattern. (We do NOT import `fallback-select` because that
--   module is approval-specific and we cannot modify its behavior.)
--
--   custom — floating window (`nvim_open_win`, `buftype=nofile`, `wrap`)
--   sized to the longest ANSI-stripped line, showing the rendered
--   dialog text. The user then drives the actual pi-side dialog from the
--   terminal; their keystrokes are captured by a `getcharstr()` loop and
--   forwarded as `ui_prompt_response {id, key}`. `<Esc>` closes the
--   mirror float WITHOUT forwarding — the dialog's hotkeys (`y/s/b/n/r`)
--   act on the dialog itself, and Esc is a no-op in the dialog's own
--   decision state, so the mirror must not pollute the dialog's input
--   stream with a spurious Esc. `ui_prompt_resolved` closes the float
--   and breaks the loop.
--
-- Protocol notes:
--
--   Why `format_item` for trimming instead of trimming the items array:
--   vim.ui.select hands `on_choice` the item the user picked. If we
--   trimmed the items, the value sent back would also be trimmed (and
--   pi's prompt would receive a truncated label). `format_item` only
--   changes display, so the original label round-trips intact — the
--   trim is purely visual, matching the plan's R15 ("full label always
--   sent back as the value").
--
--   Why capture the picker's return value for dismissal:
--   Plugin pickers (`snacks.picker.select`, `dressing`, ...) can return
--   a live picker instance from `vim.ui.select`. Calling `instance:close()`
--   is the precise dismiss handle; the fallback sweeps
--   (`snacks.picker.get`, dressing cancel) only exist for pickers that
--   return nothing. The capture pattern is identical to
--   `approval.lua:install_wrapper`.
--
--   Why a per-id `pending` table:
--   pi serializes requests, but the wrapper path lets multiple pickers
--   exist transiently (resolve races the plugin's own async on_choice).
--   Keying dismiss handles by id lets `M.resolve(id)` close the right
--   surface even when an earlier surface's on_choice callback is still
--   in flight — and guards the eventual on_choice(nil) from re-sending
--   the user's answer (matches the gate's `dismissed_remote` guard).
--
--   Why `schedule_ui` (defer when `vim.in_fast_event()`):
--   Dispatch handlers run from the socket's `pipe:read_start` callback,
--   a libuv fast event in which nvim_* APIs raise E5560. Every entry
--   point that touches the UI defers to the main loop in that case and
--   runs directly otherwise, so direct callers (tests) keep synchronous
--   semantics — same as `approval.lua`.

local log = require("pi-bridge.log")

local M = {}

-- Public constant: display-trim cutoff for long option labels.
M.TRIM_LEN = 80

-- Trim a label for display only. Anything longer than TRIM_LEN renders
-- as first 77 chars + "...". The original is never returned — callers
-- must keep the untrimmed label around so they can send it back as the
-- selected value (format_item only affects picker display).
function M.trim_label(label)
	if type(label) ~= "string" then
		return tostring(label or "")
	end
	if #label <= M.TRIM_LEN then
		return label
	end
	return label:sub(1, 77) .. "..."
end

-- Setup-time state.
local enabled = true
local original_select = nil -- captured at M.setup() for _reset()
local wrapper_installed = false
local wrapper_call_through = nil -- vim.ui.select at install time

-- Bridge state for the wrapper path: the wrapper closure needs the
-- request's id and send fn on the next vim.ui.select call. Storing on
-- the function itself is not portable (functions don't accept
-- arbitrary upvalues in Lua), so use a module-local table keyed by the
-- wrapper identity.
local current_call = { id = nil, send = nil }

-- Per-request state. Keyed by id so resolve() can target the right
-- surface even when the plugin picker's on_choice fires after a
-- remote-resolved race. The handle is NOT cleared by resolve /
-- dismiss_all — only by the picker callback (which checks `dismissed`
-- first). This mirrors approval.lua's `dismissed_remote` pattern.
local pending = {} -- { [id] = { kind = "select"|"custom", send, dismiss?, dismissed = bool } }

-- Guard flag: set when the picker is dismissed remotely, so the
-- plugin's eventual on_choice(nil) (from its own cancel path) does
-- NOT trigger a user-Esc "cancelled" response.
local dismissed_remote = {}

-- Single-flight guard for the custom float: the getcharstr loop blocks
-- the editor and only one mirror can be active at a time (pi serializes
-- anyway; this guards against a stale race).
local custom_active = nil -- { id, win, buf, send, stop }

-- UI-safe bodies of dispatch handlers — forward-declared because the
-- public wrappers schedule them (see schedule_ui below).
local handle_request_sync
local handle_resolved_sync

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
	-- decides whether a mirror surface opens.
	enabled = config.ui_prompt_mirror ~= false

	-- Capture vim.ui.select once for the _reset() restore path.
	original_select = original_select or vim.ui.select

	log.debug("mirror: setup, enabled=" .. tostring(enabled))
end

function M.is_enabled()
	return enabled
end

-- Stock detection by SOURCE, not by reference — same rationale as
-- approval.lua's is_stock_picker.
function M.is_stock_picker()
	local sel = vim.ui.select
	if type(sel) ~= "function" then return true end
	local source = debug.getinfo(sel, "S").source or ""
	return source:match("vim[/\\]ui%.lua$") ~= nil
end

-- Send a response back to pi. pcall because the socket may have died
-- while the user was deciding.
local function send_response(id, value, cancelled, key)
	-- All mirror sends come from a per-request closure captured at
	-- handler entry; nothing reads a module-level current_send here.
	-- Look up the send fn through pending.
	local handle = pending[id]
	local send = handle and handle.send
	if type(send) ~= "function" then
		log.warn("mirror: no send function for " .. tostring(id))
		return
	end
	local msg = { type = "ui_prompt_response", id = id }
	if value ~= nil then msg.value = value end
	if cancelled then msg.cancelled = true end
	if key ~= nil then msg.key = key end
	local ok, err = pcall(send, msg)
	if not ok then
		log.error("mirror: failed to send response: " .. tostring(err))
	end
end

-- ---------------------------------------------------------------------------
-- Stock picker path: a minimal owned float, mirrors fallback-select's shape
-- but for variable-length option lists. Numbered choices 1..9 + Esc.
-- ---------------------------------------------------------------------------

local function build_stock_lines(title, options)
	local lines = {}
	lines[#lines + 1] = type(title) == "string" and title ~= "" and title or "pi prompt"
	lines[#lines + 1] = ""
	for i, opt in ipairs(options) do
		if i > 9 then break end
		-- ASCII "-" separator; em-dash would be prettier but encodes
		-- inconsistently across terminals.
		lines[#lines + 1] = tostring(i) .. " - " .. M.trim_label(opt)
	end
	if #options > 9 then
		lines[#lines + 1] = "(... and " .. tostring(#options - 9) .. " more)"
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "<Esc> - cancel"
	return lines
end

local function find_stock_state(id)
	if not custom_active or custom_active.kind ~= "stock" then return nil end
	if custom_active.id == id then return custom_active end
	return nil
end

local function close_stock(id)
	local st = find_stock_state(id)
	if not st then return end
	local win, buf, prev_win = st.win, st.buf, st.prev_win
	if win and vim.api.nvim_win_is_valid(win) then
		pcall(vim.api.nvim_win_close, win, true)
	end
	if buf and vim.api.nvim_buf_is_valid(buf) then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
	custom_active = nil
	if prev_win and vim.api.nvim_win_is_valid(prev_win) then
		pcall(vim.api.nvim_set_current_win, prev_win)
	end
	log.debug("mirror: stock float closed for " .. tostring(id))
end

local function install_stock_keymaps(buf, options)
	local function map(key, idx)
		vim.keymap.set("n", key, function()
			local st = custom_active
			if not st or st.kind ~= "stock" then return end
			local send = st.send
			local id = st.id
			local opt = options[idx]
			close_stock(id)
			if type(send) ~= "function" then return end
			local ok, err = pcall(send, {
				type = "ui_prompt_response",
				id = id,
				value = opt,
			})
			if not ok then
				log.error("mirror: stock send failed: " .. tostring(err))
			end
		end, { buffer = buf, nowait = true, silent = true })
	end
	for i = 1, math.min(#options, 9) do
		map(tostring(i), i)
	end
	vim.keymap.set("n", "<Esc>", function()
		local st = custom_active
		if not st or st.kind ~= "stock" then return end
		local send = st.send
		local id = st.id
		close_stock(id)
		if type(send) ~= "function" then return end
		local ok, err = pcall(send, {
			type = "ui_prompt_response",
			id = id,
			cancelled = true,
		})
		if not ok then
			log.error("mirror: stock cancel send failed: " .. tostring(err))
		end
	end, { buffer = buf, nowait = true, silent = true })
	vim.keymap.set("n", "<C-c>", function()
		local st = custom_active
		if not st or st.kind ~= "stock" then return end
		local send = st.send
		local id = st.id
		close_stock(id)
		if type(send) ~= "function" then return end
		local ok, err = pcall(send, {
			type = "ui_prompt_response",
			id = id,
			cancelled = true,
		})
		if not ok then
			log.error("mirror: stock cancel send failed: " .. tostring(err))
		end
	end, { buffer = buf, nowait = true, silent = true })
end

local function show_stock(req)
	if custom_active then
		log.warn(
			"mirror: surface already open for "
				.. tostring(custom_active.id)
				.. ", ignoring request "
				.. tostring(req.id)
		)
		return
	end
	local title = req.title or "pi prompt"
	local options = req.options or {}
	if #options == 0 then
		log.warn("mirror: select/confirm request has no options, ignoring")
		return
	end

	local lines = build_stock_lines(title, options)
	local max_len = 1
	for _, l in ipairs(lines) do
		if #l > max_len then max_len = #l end
	end
	local width = math.max(20, math.min(max_len + 2, vim.o.columns - 4))
	local height = #lines

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	local total_lines = vim.o.lines
	local total_cols = vim.o.columns
	local row = math.max(0, math.floor((total_lines - height) / 2) - 1)
	local col = math.max(0, math.floor((total_cols - width) / 2))

	local prev_win = vim.api.nvim_get_current_win()
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " pi prompt ",
		title_pos = "center",
	})

	custom_active = {
		kind = "stock",
		id = req.id,
		win = win,
		buf = buf,
		send = req._send,
		prev_win = prev_win,
	}

	install_stock_keymaps(buf, options)
	log.info("mirror: stock picker opened for " .. tostring(req.id))
end

-- ---------------------------------------------------------------------------
-- Plugin picker path: install a vim.ui.select wrapper that captures the
-- per-request dismiss handle from the picker's return value. The wrapper
-- intercepts the plugin's eventual on_choice(nil) when the picker was
-- dismissed remotely (so it does not send "cancelled" after the user
-- already answered in pi).
-- ---------------------------------------------------------------------------

local function install_wrapper()
	if wrapper_installed then return end
	-- Call-through target: whatever vim.ui.select is at INSTALL time —
	-- normally the plugin's wrapper (dressing/snacks/...), since we only
	-- take this path when a non-stock picker is detected. Capturing at
	-- install (not setup) means a plugin that wrapped vim.ui.select
	-- after our setup() is still called correctly.
	wrapper_call_through = vim.ui.select

	local function wrapper(items, opts, on_choice)
		local id = current_call.id
		if type(id) ~= "string" then
			wrapper_call_through(items, opts, on_choice)
			return
		end

		local wrapped_on_choice = function(choice)
			if dismissed_remote[id] then
				dismissed_remote[id] = nil
				pending[id] = nil
				log.info("mirror: picker dismissed remotely for " .. tostring(id))
				return
			end
			pending[id] = nil
			on_choice(choice)
		end

		-- Install per-id handle BEFORE call so a synchronous on_choice
		-- can't race the dismiss closure.
		local ret
		pending[id] = {
			kind = "select",
			send = current_call.send,
			dismiss = function()
				if dismissed_remote[id] then return end
				dismissed_remote[id] = true
				log.info("mirror: remote dismiss for " .. tostring(id))
				if type(ret) == "table" and type(ret.close) == "function" then
					pcall(ret.close, ret)
					return
				end
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
			end,
		}

		ret = wrapper_call_through(items, opts, wrapped_on_choice)
	end

	vim.ui.select = wrapper
	wrapper_installed = true
	log.debug("mirror: installed vim.ui.select wrapper")
end

local function show_plugin_select(req)
	install_wrapper()

	-- Bridge the per-request id and send fn to the wrapper via module-
	-- local state. The wrapper reads these on the next call.
	current_call.id = req.id
	current_call.send = req._send

	vim.ui.select(req.options or {}, {
		prompt = req.title or "pi prompt",
		format_item = function(item)
			return M.trim_label(item)
		end,
	}, function(choice)
		-- Capture the send fn BEFORE clearing the bridge state — the
		-- pending entry also holds it but pending[id] is cleared in
		-- some paths before we reach here.
		local send = req._send
		-- Clear the bridge state regardless of outcome.
		current_call.id = nil
		current_call.send = nil
		if dismissed_remote[req.id] then
			-- Already handled by dismiss path; wrapped_on_choice will
			-- have cleared pending[req.id] and dismissed_remote[req.id].
			dismissed_remote[req.id] = nil
			return
		end
		pending[req.id] = nil
		if choice == nil then
			if type(send) ~= "function" then return end
			local ok, err = pcall(send, {
				type = "ui_prompt_response",
				id = req.id,
				cancelled = true,
			})
			if not ok then
				log.error("mirror: cancel send failed: " .. tostring(err))
			end
			return
		end
		if type(send) ~= "function" then return end
		local ok, err = pcall(send, {
			type = "ui_prompt_response",
			id = req.id,
			value = choice,
		})
		if not ok then
			log.error("mirror: select send failed: " .. tostring(err))
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Custom mirror: floating window + key forwarding loop.
-- ---------------------------------------------------------------------------

local ANSI_SGR_PATTERN = "\27%[%d+;?%d*m"

-- Strip SGR escape codes from a line. Minimal — only CSI SGR sequences
-- (color/style); other ANSI (cursor moves, etc.) are left intact. The
-- float is plain text only; we trade fidelity for the simplicity of a
-- one-pattern strip (R16 wrap handles width overflow).
local function strip_ansi(line)
	if type(line) ~= "string" or line == "" then
		return tostring(line or "")
	end
	if not line:find("\27", 1, true) then return line end
	return (line:gsub(ANSI_SGR_PATTERN, ""))
end

local function find_custom_state(id)
	if not custom_active or custom_active.kind ~= "custom" then return nil end
	if custom_active.id == id then return custom_active end
	return nil
end

local function close_custom_float(id)
	local st = find_custom_state(id)
	if not st then return end
	local win, buf, prev_win = st.win, st.buf, st.prev_win
	if win and vim.api.nvim_win_is_valid(win) then
		pcall(vim.api.nvim_win_close, win, true)
	end
	if buf and vim.api.nvim_buf_is_valid(buf) then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
	st.closed = true
	if prev_win and vim.api.nvim_win_is_valid(prev_win) then
		pcall(vim.api.nvim_set_current_win, prev_win)
	end
	log.debug("mirror: custom float closed for " .. tostring(id))
end

local function show_custom(req)
	if custom_active then
		log.warn(
			"mirror: surface already open for "
				.. tostring(custom_active.id)
				.. ", ignoring request "
				.. tostring(req.id)
		)
		return
	end
	local raw_lines = req.lines or {}
	local stripped = {}
	local max_len = 1
	for _, l in ipairs(raw_lines) do
		local s = strip_ansi(l)
		stripped[#stripped + 1] = s
		if #s > max_len then max_len = #s end
	end
	if #stripped == 0 then
		log.warn("mirror: custom request has no lines, ignoring")
		return
	end
	local width = math.max(20, math.min(max_len + 2, vim.o.columns - 4))
	local height = #stripped

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, stripped)

	local total_lines = vim.o.lines
	local total_cols = vim.o.columns
	local row = math.max(0, math.floor((total_lines - height) / 2) - 1)
	local col = math.max(0, math.floor((total_cols - width) / 2))

	local prev_win = vim.api.nvim_get_current_win()
	local win = vim.api.nvim_open_win(buf, false, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " pi custom prompt ",
		title_pos = "center",
	})
	-- wrap is window-local, not buffer-local. Set after the window is
	-- open so long lines don't overflow the float width (R16).
	vim.api.nvim_set_option_value("wrap", true, { win = win })

	local state = {
		kind = "custom",
		id = req.id,
		win = win,
		buf = buf,
		send = req._send,
		prev_win = prev_win,
		closed = false,
	}
	custom_active = state
	log.info("mirror: custom float opened for " .. tostring(req.id))

	-- Modal getchar loop. Breaks when the float is closed (by resolve
	-- or by the user's own Esc). Each non-Esc key is forwarded as a
	-- ui_prompt_response {id, key}. Esc closes the float only — does
	-- NOT forward, per R10.
	vim.schedule(function()
		-- If a resolve() raced in between scheduling and running, bail.
		if state.closed or custom_active ~= state then return end
		local send = state.send
		local id = state.id
		while not state.closed do
			local ok, key = pcall(vim.fn.getcharstr)
			if not ok or key == nil or key == "" then
				-- getcharstr() can fail on interrupt; treat as Esc
				-- so the user always has a way out.
				close_custom_float(id)
				break
			end
			-- Esc (or CSI-u Esc under kitty) closes only.
			if key == "\27" or key:sub(1, 3) == "\27[" then
				close_custom_float(id)
				break
			end
			if type(send) == "function" then
				local sok, serr = pcall(send, {
					type = "ui_prompt_response",
					id = id,
					key = key,
				})
				if not sok then
					log.error("mirror: key forward failed: " .. tostring(serr))
				end
			end
		end
		-- Defensive: ensure state cleared even if loop exited via
		-- remote-resolve while still iterating.
		if custom_active == state then
			custom_active = nil
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Dispatch entry points.
-- ---------------------------------------------------------------------------

function M._handle_request(req, send)
	if not enabled then
		log.info("mirror: disabled, ignoring request " .. tostring(req and req.id))
		return
	end
	if type(req) ~= "table" then
		log.warn("mirror: malformed request (not a table)")
		return
	end
	if type(req.id) ~= "string" or req.id == "" then
		log.warn("mirror: missing id, ignoring request")
		return
	end
	-- Attach the send fn for this request so the handlers can call it.
	req._send = send

	schedule_ui(function()
		handle_request_sync(req)
	end)
end

function handle_request_sync(req)
	local kind = req.kind
	if kind == "select" or kind == "confirm" then
		-- confirm folded in as a 2-option select.
		local options = req.options or {}
		if kind == "confirm" and #options < 2 then
			options = { "Yes", "No" }
		end
		req.options = options
		if M.is_stock_picker() then
			show_stock(req)
		else
			show_plugin_select(req)
		end
	elseif kind == "custom" then
		show_custom(req)
	else
		log.warn("mirror: unknown kind '" .. tostring(kind) .. "', no surface")
	end
end

function M._handle_resolved(msg)
	if type(msg) ~= "table" or type(msg.id) ~= "string" then return end
	schedule_ui(function()
		handle_resolved_sync(msg.id)
	end)
end

function handle_resolved_sync(id)
	local handle = pending[id]
	if handle then
		if type(handle.dismiss) == "function" then
			handle.dismiss()
		end
		-- Don't clear pending[id]: the plugin's eventual wrapped_on_choice
		-- needs to see the dismissed flag to no-op. The wrapper does the
		-- cleanup once the callback fires.
		return
	end
	-- Stock picker path: the float is tracked under custom_active with
	-- kind="stock". Close it without sending a response.
	local stk = find_stock_state(id)
	if stk then
		close_stock(id)
		custom_active = nil
		return
	end
	-- Custom mirror float: tracked under custom_active with kind="custom".
	local cst = find_custom_state(id)
	if cst then
		close_custom_float(id)
		custom_active = nil
		return
	end
	-- Late / unknown id: no-op (matches the plan's R11 / R8).
	log.debug("mirror: resolved for unknown id " .. tostring(id))
end

function M.dismiss_all()
	-- Called by wiring on pi disconnect. Closes any open mirror
	-- surface, echoes "pi disconnected", sends nothing.
	schedule_ui(function()
		for id, handle in pairs(pending) do
			if type(handle.dismiss) == "function" then
				handle.dismiss()
			end
			-- Leave pending[id] in place: the plugin's eventual
			-- wrapped_on_choice still needs the dismissed_remote flag
			-- to no-op. The wrapper clears it after firing.
		end
		if custom_active then
			local id = custom_active.id
			if custom_active.kind == "custom" then
				close_custom_float(id)
			elseif custom_active.kind == "stock" then
				close_stock(id)
			end
			custom_active = nil
		end
		log.debug("mirror: dismiss_all, surfaces closed")
	end)
end

-- Wire-callable hello: send {"type":"mirror_ready"} once per connect.
-- Pcall because the socket may not be ready.
function M.send_ready(send)
	if type(send) ~= "function" then return end
	local ok, err = pcall(send, { type = "mirror_ready" })
	if not ok then
		log.error("mirror: send_ready failed: " .. tostring(err))
	end
end

-- Test-only: clear module state.
function M._reset()
	enabled = true
	pending = {}
	dismissed_remote = {}
	custom_active = nil
	current_call.id = nil
	current_call.send = nil
	if wrapper_installed and original_select then
		vim.ui.select = original_select
	end
	wrapper_installed = false
	wrapper_call_through = nil
	original_select = nil
end

return M
