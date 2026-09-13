-- Fallback approval float for stock `vim.ui.select`.
--
-- `vim.ui.select` on a stock Neovim blocks in `inputlist()` and cannot
-- be dismissed programmatically. Plugins like dressing/snacks/fzf
-- change this so the picker returns control to the event loop and a
-- remote caller can close it. To stay usable on stock installs, we
-- ship our own minimal float for the approval prompt.
--
-- Lifecycle:
--   show(req, send)            open float, install buffer-local maps;
--                              user choice calls send_response then close()
--   close()                    dismiss silently (no echo, no response)
--   close_silent(reason_msg)   dismiss and echo `pi-bridge: <reason_msg>`
--                              (used by the pi-disconnect path)
--
-- Focus:
--   The float is entered on open so buffer-local maps fire. The prior
--   window is captured and restored on close when still valid.
--
-- Concurrency:
--   Only one float may be open at a time (defensive; pi serializes
--   approval_request but a stale request could race the wrapper path).

local log = require("pi-bridge.log")

local M = {}

-- Module state: nil when no float is open.
local state = nil

-- Visual styling: modest width, centered-ish, single border. Width
-- sized for the longest label (~50 chars) plus padding.
local WIN_WIDTH = 52
local WIN_HEIGHT = 6 -- prompt + blank + 3 choices

local function build_prompt(req)
	local prompt = "approve edit: " .. (req.path or "")
	-- Mirror approval.lua's modified-buffer warning so users see it
	-- regardless of which picker is in use.
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
	return prompt
end

local function restore_prior_window()
	if not state then return end
	local prev = state.prev_win
	if prev and vim.api.nvim_win_is_valid(prev) then
		pcall(vim.api.nvim_set_current_win, prev)
	end
end

function M.close()
	if not state then return end
	local win = state.win
	local buf = state.buf
	state = nil
	if win and vim.api.nvim_win_is_valid(win) then
		pcall(vim.api.nvim_win_close, win, true)
	end
	if buf and vim.api.nvim_buf_is_valid(buf) then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
	restore_prior_window()
	log.debug("fallback-select: closed")
end

function M.close_silent(reason_msg)
	if not state then return end
	log.info("fallback-select: dismissed: " .. tostring(reason_msg))
	M.close()
	vim.notify("pi-bridge: " .. tostring(reason_msg), vim.log.levels.WARN)
end

function M.is_open()
	return state ~= nil
end

function M.get_pending_id()
	if not state then return nil end
	return state.id
end

local function send_response(send, id, decision)
	if type(send) ~= "function" then return end
	local ok, err = pcall(send, {
		type = "approval_response",
		id = id,
		decision = decision,
	})
	if not ok then
		log.error("fallback-select: failed to send response: " .. tostring(err))
	end
end

local function respond(decision)
	if not state then return end
	local id = state.id
	local send = state.send
	-- Close first so the user sees the float disappear on answer; then
	-- send. Order matches the wrapper path in approval.lua.
	M.close()
	send_response(send, id, decision)
end

local function install_keymaps(buf, send)
	local function map(key, decision)
		vim.keymap.set("n", key, function()
			respond(decision)
		end, { buffer = buf, nowait = true, silent = true })
	end
	map("y", "yes")
	map("a", "all")
	map("n", "no")
	-- Esc and <C-c> dismiss-as-reject (same semantics as vim.ui.select).
	vim.keymap.set("n", "<Esc>", function()
		respond("no")
	end, { buffer = buf, nowait = true, silent = true })
	vim.keymap.set("n", "<C-c>", function()
		respond("no")
	end, { buffer = buf, nowait = true, silent = true })
	-- Any other key: do nothing (avoid buffer edits).
	vim.keymap.set("n", "<Plug>(pi-bridge-fallback-noop)", function() end, {
		buffer = buf,
	})
end

function M.show(req, send)
	if state then
		log.warn("fallback-select: already open, ignoring request " .. tostring(req and req.id))
		return
	end
	if type(req) ~= "table" then
		log.warn("fallback-select: malformed request (not a table)")
		return
	end
	local id = req.id
	if type(id) ~= "string" or id == "" then
		log.warn("fallback-select: missing id, ignoring request")
		return
	end

	local prompt = build_prompt(req)

	local buf = vim.api.nvim_create_buf(false, true)
	-- scratch + listed=false so :ls doesn't show it; buftype=nofile.
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		prompt,
		"",
		"y — approve this edit",
		"a — approve all edits to this file (this session)",
		"n — reject this edit",
	})

	-- Center the float on the editor screen.
	local total_lines = vim.o.lines
	local total_cols = vim.o.columns
	local row = math.max(0, math.floor((total_lines - WIN_HEIGHT) / 2) - 1)
	local col = math.max(0, math.floor((total_cols - WIN_WIDTH) / 2))

	local prev_win = vim.api.nvim_get_current_win()
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = WIN_WIDTH,
		height = WIN_HEIGHT,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " pi approval ",
		title_pos = "center",
	})

	state = {
		win = win,
		buf = buf,
		id = id,
		send = send,
		prev_win = prev_win,
	}

	install_keymaps(buf, send)
	log.info("fallback-select: opened for " .. id)
end

-- Test-only: clear module state. Not part of the public API.
function M._reset()
	state = nil
end

return M
