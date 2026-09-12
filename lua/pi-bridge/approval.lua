-- Floating-window approval prompt for pi's `edit`/`write` tool calls.
--
-- Design decisions:
--
--   Why a scratch buffer with `syntax=diff`:
--   Vim ships a diff syntax file. Setting `vim.bo.syntax = "diff"` (via
--   filetype) on a scratch buffer gives free coloring for added/removed
--   lines without bundling a treesitter parser or color override. The
--   float stays self-contained and has no side effects on user buffers.
--
--   Why send `approval_ack` immediately after the window opens:
--   pi's gate waits up to 1s for an ack. If we delay the ack (e.g. wait
--   for a user keypress first) pi falls back to its own TUI overlay
--   and the nvim float becomes a duplicate UI. The ack must fire as
--   soon as a window is on screen so pi knows nvim took over.
--
--   Why ignore (not answer) a second concurrent request:
--   pi serializes requests via its own queue (ext Step 3), so at most
--   one `approval_request` is in flight at a time. If we ever receive
--   two (e.g. protocol bug), answering the second with a synthetic
--   decision would surprise the user — the visible float would close
--   without a keypress. Logging a warning is enough; pi's queue will
--   re-deliver the next one cleanly once the current float resolves.
--
--   Why restore previous window on close:
--   The user was editing somewhere. Jumping focus to a now-closed
--   window would be jarring; restoring the prior focus point keeps
--   the editor cursor where the user left it.
--
--   Why `M.resolve(id)` instead of just letting the user keypress:
--   If pi's fallback overlay resolves the request before nvim's user
--   presses a key, the float is stale and would respond to a keypress
--   pi already discarded. The `approval_resolved` event lets nvim
--   close the float proactively; late keypresses (in the brief window
--   between resolve and close) send a response pi ignores harmlessly.
--
--   Why `schedule_ui` (defer when `vim.in_fast_event()`):
--   Dispatch handlers run from the socket's `pipe:read_start` callback,
--   a libuv fast event in which nvim_* APIs raise E5560. show()/resolve()
--   defer their UI work to the main loop in that case and run directly
--   otherwise, so direct callers (tests) keep synchronous semantics.

local log = require("pi-bridge.log")

local M = {}

-- Module state. Pending float is `{ id, winid, bufnr, prev_win, send }`.
local enabled = true
local pending = nil

-- Run `fn` immediately in normal context, or deferred when called from a
-- libuv fast-event context (the socket's `pipe:read_start` callback).
-- nvim_* APIs raise E5560 in a fast event, so every entry point that can
-- be reached from socket callbacks must funnel through here. Using
-- `vim.in_fast_event()` keeps direct calls (tests, re-sourced modules)
-- synchronous while making socket-driven calls safe.
local function schedule_ui(fn)
	if vim.in_fast_event() then
		vim.schedule(fn)
	else
		fn()
	end
end

function M.setup(opts)
	-- `false` is the explicit opt-out; anything else (including nil) means
	-- the default-on behavior. This is the only switch — the protocol
	-- itself is always wired (dispatch.register is unconditional).
	if opts and opts.edit_approval_prompt == false then
		enabled = false
	else
		enabled = true
	end
end

function M.is_enabled()
	return enabled
end

-- Find a loaded buffer for `path` and return whether it's modified.
-- Returns nil when no buffer is loaded for that path.
local function target_buffer_modified(path)
	if not path or path == "" then return nil end
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			local name = vim.api.nvim_buf_get_name(bufnr)
			if name == path or vim.fn.fnamemodify(name, ":p") == vim.fn.fnamemodify(path, ":p") then
				if vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
					return true
				end
				return false
			end
		end
	end
	return nil
end

local function build_header_lines(path)
	local lines = {}
	if target_buffer_modified(path) then
		table.insert(lines, "[warning] buffer has unsaved changes; diff is computed from disk")
	end
	table.insert(lines, "approve edit: " .. path)
	-- Hint on its own line: long absolute paths would otherwise push it
	-- past the float's right edge (wrap is off), hiding the choices.
	table.insert(lines, "respond: y (this edit) · a (all edits to this file) · n / <Esc> (reject)")
	return lines
end

local function compute_dimensions()
	local max_width = math.min(100, vim.o.columns - 4)
	if max_width < 20 then
		max_width = vim.o.columns
	end
	return max_width
end

local function center_position(width, height)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)
	if row < 0 then row = 0 end
	if col < 0 then col = 0 end
	return row, col
end

-- Close the pending float and clean up state.
--
-- `restore_focus` is true only when the close is user-initiated (y/a/n
-- keypress): the user is done with the prompt and wants their editor
-- back. Remote closes (`resolve()` for a stale float) must NOT yank
-- focus — the user may have moved to another window during the wait.
local function close_pending(restore_focus)
	if not pending then return end
	local p = pending
	pending = nil

	if vim.api.nvim_win_is_valid(p.winid) then
		vim.api.nvim_win_close(p.winid, true)
	end
	if vim.api.nvim_buf_is_valid(p.bufnr) then
		vim.api.nvim_buf_delete(p.bufnr, { force = true })
	end
	if restore_focus and p.prev_win and vim.api.nvim_win_is_valid(p.prev_win) then
		vim.api.nvim_set_current_win(p.prev_win)
	end
end

local function make_respond(p)
	return function(decision)
		-- Guard against a stale keypress after resolve() cleared state.
		if not pending or pending.id ~= p.id then return end

		local send = p.send
		local id = p.id
		-- User-initiated close: restore focus to where they were.
		close_pending(true)

		if type(send) == "function" then
			local ok, err = pcall(send, {
				type = "approval_response",
				id = id,
				decision = decision,
			})
			if not ok then
				log.error("approval: failed to send response: " .. tostring(err))
			end
		end
	end
end

-- Full show body. Runs in a UI-safe context (normal or scheduled via
-- `schedule_ui`) — every nvim_* call below would raise E5560 in a fast
-- event context.
local function run_show(req, send)
	if pending then
		-- Defensive: pi should serialize. If two arrive, prefer the
		-- existing float and let pi's queue re-deliver later.
		log.warn("approval: request " .. tostring(req.id) .. " ignored; already showing " .. tostring(pending.id))
		return
	end

	local diff = req.diff or ""
	local path = req.path or ""
	local id = req.id
	if type(id) ~= "string" or id == "" then
		log.warn("approval: missing id, ignoring request")
		return
	end

	-- 1. Create scratch buffer.
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].filetype = "diff"
	-- Force syntax on even if filetype detection is slow in headless.
	vim.api.nvim_set_option_value("syntax", "diff", { buf = bufnr })

	-- 2. Header + diff lines.
	local header = build_header_lines(path)
	local diff_lines = vim.split(diff, "\n", { plain = true })
	-- Trailing newline produces a trailing empty string; trim it.
	if #diff_lines > 0 and diff_lines[#diff_lines] == "" then
		table.remove(diff_lines)
	end
	local all_lines = vim.list_extend(vim.deepcopy(header), diff_lines)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, all_lines)

	-- 3. Compute float dimensions.
	local max_width, _ = compute_dimensions()
	local total_lines = #all_lines
	if total_lines < 1 then total_lines = 1 end
	local height = math.min(total_lines, math.max(1, vim.o.lines - 4))
	local width = max_width
	local row, col = center_position(width, height)

	-- 4. Open the floating window.
	local prev_win = nil
	if vim.api.nvim_win_is_valid(0) then
		prev_win = vim.api.nvim_get_current_win()
	end
	local winid = vim.api.nvim_open_win(bufnr, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " pi edit approval ",
		title_pos = "center",
	})
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		log.error("approval: failed to open window for " .. id)
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end
		return
	end

	vim.api.nvim_set_option_value("wrap", false, { win = winid })
	vim.api.nvim_set_option_value("cursorline", false, { win = winid })

	-- 5. Register pending state and install buffer-local keymaps.
	pending = { id = id, winid = winid, bufnr = bufnr, prev_win = prev_win, send = send }
	local respond = make_respond(pending)

	local function map(lhs, decision)
		vim.keymap.set("n", lhs, function() respond(decision) end, {
			buffer = bufnr,
			nowait = true,
			silent = true,
			desc = "pi approval: " .. decision,
		})
	end
	map("y", "yes")
	map("a", "all")
	map("n", "no")
	vim.keymap.set("n", "<Esc>", function() respond("no") end, {
		buffer = bufnr,
		nowait = true,
		silent = true,
		desc = "pi approval: no (esc)",
	})

	-- 6. Ack immediately so pi stops its fallback timer. This MUST
	-- happen after the window is on screen — the plan's protocol
	-- contract is "ack within 1s" and we want pi to see nvim is alive.
	if type(send) == "function" then
		local ok, err = pcall(send, { type = "approval_ack", id = id })
		if not ok then
			log.error("approval: failed to send ack: " .. tostring(err))
		end
	end

	log.info("approval: showing float for " .. id .. " (" .. path .. ")")
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
	-- May also be called from the socket fast event (approval_resolved);
	-- same E5560 hazard as show().
	schedule_ui(function()
		if not pending then return end
		if pending.id ~= id then
			-- Stale float for a different id (pi already answered it via
			-- fallback or it was resolved by an earlier event). Leave it
			-- alone — the user can still answer it and pi will see a
			-- response for a no-longer-pending id, which it discards.
			return
		end
		log.info("approval: resolving stale float for " .. tostring(id))
		-- Remote close: do not restore focus (the user may have moved on).
		close_pending(false)
	end)
end

-- Test-only: clear module state. Not part of the public API.
function M._reset()
	enabled = true
	if pending then
		close_pending(false)
		pending = nil
	end
end

return M
