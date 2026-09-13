-- Shared minimal blocking choice float.
--
-- `vim.ui.select` on a stock Neovim blocks in `inputlist()` and cannot
-- be dismissed programmatically. Plugins like dressing/snacks/fzf
-- change this so the picker returns control to the event loop and a
-- remote caller can close it. To stay usable on stock installs, the
-- edit-approval gate (y/a/n) and the UI prompt mirror's stock-picker
-- path (1..9) each need their own minimal float. The mechanics are
-- identical — scratch buffer, centered float, buffer-local keymaps
-- that close-then-respond, prior-window restore, prune of a window
-- closed behind our back — so they live here; the two callers differ
-- only in rendered lines, keymap spec, and the response message they
-- build (which stays in the caller: this module knows nothing about
-- the protocol).
--
-- Single-flight is PER OWNER, not global: an approval fallback float
-- and a mirror stock float may legitimately coexist in one turn (the
-- edit gate and a ctx.ui.select prompt are different prompts), so
-- each owner tracks its own float. Cross-feature exclusivity is the
-- callers' concern (prompt_mirror guards its own two surfaces).
--
-- Focus:
--   The float is entered on open so buffer-local maps fire. The prior
--   window is captured and restored on close when still valid.
--
-- Lifecycle (per owner):
--   M.open(spec)               open; returns false (logs nothing) if
--                              a float is already open for the owner
--                              spec = {
--                                owner     string  slot key
--                                id        string  request id
--                                title     string  border title
--                                lines     string[]  buffer content
--                                keys      { {key, value} }  keymap
--                                          spec; value may be nil
--                                          (e.g. cancel keys — the
--                                          caller interprets nil)
--                                on_choice fn(value)  called AFTER
--                                          close; caller owns guards
--                                          and message construction
--                                width?    number  default: fit the
--                                          longest line
--                                height?   number  default: #lines
--                              }
--   M.close(owner)             dismiss silently (no echo, no response)
--   M.close_silent(owner, msg) dismiss and echo `pi-bridge: <msg>`
--                              (used by the pi-disconnect path)
--   M.is_open(owner)           true when open; prunes stale state
--   M.get_id(owner)            id of the open float, or nil
--
-- Concurrency:
--   Only one float per owner may be open at a time (defensive; pi
--   serializes same-feature prompts but a stale request could race
--   the wrapper path).

local log = require("pi-bridge.log")

local M = {}

-- Module state keyed by owner; nil entry when no float is open.
local states = {}

local function get_state(owner)
	return states[owner]
end

-- Drop the state handle if the float's window was closed behind our
-- back (:q on the float, :only, a window-management plugin). The
-- scratch buffer is wiped automatically via bufhidden; without this
-- the stale handle would make is_open() lie and the double-open guard
-- would silently swallow every future request for this owner.
-- Must run in a UI-safe context (nvim_win_is_valid raises E5560 in
-- fast events).
local function prune_stale(owner)
	local st = states[owner]
	if not st then return false end
	if not vim.api.nvim_win_is_valid(st.win) then
		states[owner] = nil
		return false
	end
	return true
end

local function restore_prior_window(prev)
	if prev and vim.api.nvim_win_is_valid(prev) then
		pcall(vim.api.nvim_set_current_win, prev)
	end
end

function M.close(owner)
	local st = get_state(owner)
	if not st then return end
	local win, buf, prev_win = st.win, st.buf, st.prev_win
	-- Teardown first, state last: if an API call raises (e.g. E5560 when
	-- called from a fast event), the keymaps must stay live and the
	-- open-state must stay consistent so a retry can still close it.
	if win and vim.api.nvim_win_is_valid(win) then
		pcall(vim.api.nvim_win_close, win, true)
	end
	if buf and vim.api.nvim_buf_is_valid(buf) then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
	states[owner] = nil
	restore_prior_window(prev_win)
	log.debug("choice_float: closed float for " .. tostring(owner))
end

function M.close_silent(owner, reason_msg)
	if not M.is_open(owner) then return end
	log.info("choice_float: dismissed for " .. tostring(owner) .. ": " .. tostring(reason_msg))
	M.close(owner)
	vim.notify("pi-bridge: " .. tostring(reason_msg), vim.log.levels.WARN)
end

function M.is_open(owner)
	if type(owner) ~= "string" then return false end
	return prune_stale(owner)
end

function M.get_id(owner)
	if not M.is_open(owner) then return nil end
	return get_state(owner).id
end

local function install_keymaps(owner, keys, on_choice)
	local buf = get_state(owner).buf
	local function fire(value)
		local st = get_state(owner)
		if not st then return end
		-- Close first so the user sees the float disappear on answer;
		-- then respond. Order matches the previous per-module behavior.
		M.close(owner)
		on_choice(value)
	end
	for _, entry in ipairs(keys) do
		vim.keymap.set("n", entry.key, function()
			fire(entry.value)
		end, { buffer = buf, nowait = true, silent = true })
	end
	-- Any other key: do nothing (avoid buffer edits).
	vim.keymap.set("n", "<Plug>(pi-bridge-choice-float-noop)", function() end, {
		buffer = get_state(owner).buf,
	})
end

function M.open(spec)
	if type(spec) ~= "table" then
		log.warn("choice_float: malformed spec (not a table)")
		return false
	end
	local owner = spec.owner
	if type(owner) ~= "string" or owner == "" then
		log.warn("choice_float: missing owner, ignoring")
		return false
	end
	if type(spec.id) ~= "string" or spec.id == "" then
		log.warn("choice_float: missing id for " .. owner .. ", ignoring")
		return false
	end
	if M.is_open(owner) then
		-- Caller owns the "already open" log (it knows its own context).
		return false
	end
	if type(spec.lines) ~= "table" or #spec.lines == 0 then
		log.warn("choice_float: empty lines for " .. owner .. ", ignoring")
		return false
	end
	if type(spec.on_choice) ~= "function" then
		log.warn("choice_float: missing on_choice for " .. owner .. ", ignoring")
		return false
	end

	local lines = spec.lines
	-- Width sized for the longest line unless the caller pins it.
	local width = spec.width
	if type(width) ~= "number" then
		local max_len = 1
		for _, l in ipairs(lines) do
			if #l > max_len then max_len = #l end
		end
		width = math.max(20, math.min(max_len + 2, vim.o.columns - 4))
	end
	local height = type(spec.height) == "number" and spec.height or #lines

	local buf = vim.api.nvim_create_buf(false, true)
	-- scratch + listed=false so :ls doesn't show it; buftype=nofile.
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	-- Center the float on the editor screen.
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
		title = spec.title or "",
		title_pos = "center",
	})

	states[owner] = {
		win = win,
		buf = buf,
		id = spec.id,
		prev_win = prev_win,
	}
	install_keymaps(owner, spec.keys or {}, spec.on_choice)
	return true
end

-- Test-only: clear module state. Not part of the public API.
function M._reset()
	states = {}
end

return M
