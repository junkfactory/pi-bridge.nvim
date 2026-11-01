-- Editable, self-growing prompt float.
--
-- The interactive prompt used to go through `vim.ui.input`, which on
-- LazyVim resolves to snacks.nvim's input: a single-line `height = 1`
-- float whose width is re-computed from the text length on every
-- keystroke, so long prompts grow horizontally instead of wrapping.
-- snacks exposes no wrap or height-growth lever, so pi-bridge owns the
-- surface here, the same way `choice_float` already owns the pickers.
--
-- Shape: one centered, fixed-width (WIDTH, clamped to the editor)
-- float over a plain scratch buffer with 'wrap' and 'linebreak'. The
-- height follows the wrapped row count (1..MAX_HEIGHT) via
-- `nvim_win_text_height` on every text change and on editor resize,
-- then the box scrolls. Geometry is only pushed when it actually
-- changed, so typing does not trigger a redraw storm.
--
-- No padding is written into the buffer: the buffer holds exactly the
-- prompt text, so submit, cursor and completion columns stay honest.
--
-- Lifecycle:
--   M.open({ on_submit = fn })  open the box; returns false when
--                               already open or the float could not
--                               be created
--   M.is_open()                 true while the float is valid
--   M.close(reason)             dismiss without submitting
--   M._reset()                  test hook: drop state, touch nothing
--
-- Keys are buffer-local (see install_keymaps): <CR> submits (accepting
-- a visible completion first), <C-j>/<S-CR> insert a newline, <Tab>
-- completes, <Up>/<Down> move by display row, <C-c>/<Esc><Esc> cancel.

local log = require("pi-bridge.log")

local M = {}

-- Text-area width; clamped to `columns - 4` so the box stays inside the
-- editor with the border on both sides. MAX_HEIGHT caps the wrapped rows
-- before the box starts scrolling.
local WIDTH = 60
local MAX_HEIGHT = 10
local AUGROUP = "pi-bridge-input"

-- Single-flight state; nil when nothing is open.
local state = nil

-- Clamped text-area width for the current editor size (never below 1).
local function box_width()
	return math.max(1, math.min(WIDTH, vim.o.columns - 4))
end

-- Top-left corner that centers a width x height box on the screen.
local function box_origin(width, height)
	local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
	local col = math.max(0, math.floor((vim.o.columns - width) / 2))
	return row, col
end

-- Wrapped row count, capped to the box range. A raising API call must
-- not break typing, so fall back to the tallest box.
local function target_height(win)
	local ok, h = pcall(vim.api.nvim_win_text_height, win, {})
	if not ok then return MAX_HEIGHT end
	return math.max(1, math.min(MAX_HEIGHT, h.all or 1))
end

-- After a geometry change, re-anchor the viewport. A height-1 box
-- force-scrolls topline to the cursor when a <C-j> newline makes the
-- cursor momentarily invisible (verified: topline snapped to the cursor
-- line), and nvim_win_set_config PRESERVES that stale topline while the
-- box grows afterwards — hiding the top line(s) until the next event.
-- Resetting topline=1 (leftcol/skipcol too) lets nvim minimal-scroll
-- for cursor visibility: full context while everything fits, natural
-- tail-scroll once MAX_HEIGHT caps the box.
local function reanchor(st)
	vim.api.nvim_win_call(st.win, function()
		pcall(vim.fn.winrestview, { topline = 1, leftcol = 0, skipcol = 0 })
	end)
end

local function resize()
	local st = state
	if not st then
		-- The autocmds fired with no state at all: the box was closed
		-- behind our back and the state was already pruned (:q, :only,
		-- a window-management plugin, or an is_open() check). The
		-- VimResized handler is the group's last automatic tick —
		-- drop the group so no dormant handler survives the close.
		pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
		return
	end
	if not vim.api.nvim_win_is_valid(st.win) then
		-- Same external-close case with the state handle still around:
		-- drop the state AND the group in one go.
		pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
		state = nil
		return
	end
	local width = box_width()
	local row, col
	-- Height measured at the window's CURRENT width; 'wrap' counts
	-- rows against it.
	local height = target_height(st.win)
	-- Unchanged geometry: stay silent (this runs per keystroke).
	if width == st.width and height == st.height then return end
	if width ~= st.width then
		-- Width FIRST, height second: after the width changes, the
		-- wrapped row count must be measured at that new width, or a
		-- narrowed editor (VimResized) would get a stale, too-short
		-- box until the next text change. nvim_win_text_height needs
		-- no redraw after nvim_win_set_config (verified on nvim 0.12).
		row, col = box_origin(width, st.height)
		local ok, err = pcall(vim.api.nvim_win_set_config, st.win, {
			relative = "editor",
			row = row,
			col = col,
			width = width,
		})
		st.width = width
		if not ok then
			log.warn("input: resize failed: " .. tostring(err))
			return
		end
		height = target_height(st.win)
		-- The width moved even when the re-measured height did not;
		-- the viewport can be stale after the geometry change.
		reanchor(st)
	end
	if height == st.height then return end
	st.height = height
	row, col = box_origin(width, height)
	local ok, err = pcall(vim.api.nvim_win_set_config, st.win, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
	})
	if not ok then
		log.warn("input: resize failed: " .. tostring(err))
		return
	end
	reanchor(st)
end

-- Buffer text with trailing whitespace stripped; "" for an empty box.
local function text(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	return (table.concat(lines, "\n"):gsub("%s+$", ""))
end

local function submit()
	local st = state
	if not st then return end
	local value = text(st.buf)
	M.close("submit")
	-- Nothing typed: treat as a cancel, do not call back.
	if value == "" then return end
	if type(st.on_submit) == "function" then
		local ok, err = pcall(st.on_submit, value)
		if not ok then log.error("input: on_submit failed: " .. tostring(err)) end
	end
end

-- <CR> is an expr map so it can defer to an open completion popup; text
-- must not change inside expr context, so submit is scheduled.
local function submit_later()
	vim.schedule(submit)
	return ""
end

local function cancel()
	M.close("cancel")
end

local function install_keymaps(buf)
	local function map(mode, lhs, rhs, opts)
		opts = opts or {}
		opts.buffer = buf
		opts.nowait = true
		opts.silent = true
		vim.keymap.set(mode, lhs, rhs, opts)
	end

	-- Insert mode: completion first, submit otherwise.
	map("i", "<CR>", function()
		if vim.fn.pumvisible() == 1 then return "<C-y>" end
		return submit_later()
	end, { expr = true })
	-- <C-j> inserts a newline natively; <S-CR> only arrives where the
	-- terminal negotiates an extended key encoding, so the map is
	-- guarded and a no-op elsewhere.
	pcall(vim.keymap.set, "i", "<S-CR>", "<C-j>", {
		buffer = buf,
		nowait = true,
		silent = true,
	})
	map("i", "<Tab>", function()
		if vim.fn.pumvisible() == 1 then return "<C-n>" end
		return "<C-x><C-u>"
	end, { expr = true })
	map("i", "<S-Tab>", function()
		if vim.fn.pumvisible() == 1 then return "<C-p>" end
		return ""
	end, { expr = true })
	-- Display-row movement, so a wrapped paragraph moves line by line.
	map("i", "<Up>", "<C-o>gk")
	map("i", "<Down>", "<C-o>gj")
	map("i", "<C-c>", cancel)
	-- <Esc> stays native: stopinsert, then the normal-mode maps apply.
	map("n", "<CR>", submit)
	map("n", "<Esc>", cancel)
	map("n", "q", cancel)
	map("n", "<C-c>", cancel)
end

function M.is_open()
	local st = state
	if not st then return false end
	if not vim.api.nvim_win_is_valid(st.win) then
		state = nil
		return false
	end
	return true
end

function M.close(reason)
	local st = state
	if not st then return end
	-- Teardown first, state last (as in choice_float.close): if an API
	-- call raises, the maps stay live so a retry can still close it.
	if st.win and vim.api.nvim_win_is_valid(st.win) then
		pcall(vim.api.nvim_win_close, st.win, true)
	end
	if st.buf and vim.api.nvim_buf_is_valid(st.buf) then
		pcall(vim.api.nvim_buf_delete, st.buf, { force = true })
	end
	if st.prev_win and vim.api.nvim_win_is_valid(st.prev_win) then
		pcall(vim.api.nvim_set_current_win, st.prev_win)
	end
	pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
	if state == st then state = nil end
	log.debug("input: closed prompt (" .. tostring(reason or "no reason") .. ")")
end

function M.open(opts)
	if M.is_open() then
		log.warn("input: prompt already open, ignoring open request")
		return false
	end
	opts = opts or {}

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].modifiable = true
	-- No 'filetype': a third-party ftplugin would change indent and
	-- completion behaviour under us.
	vim.bo[buf].completefunc = "v:lua._pi_bridge_input_complete"

	local border_hl = require("pi-bridge.ui").border_hl()

	local width = box_width()
	local height = 1
	local row, col = box_origin(width, height)
	local prev_win = vim.api.nvim_get_current_win()
	local ok, win = pcall(vim.api.nvim_open_win, buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "single",
		title = " π > ",
		title_pos = "center",
	})
	if not ok then
		log.error("input: could not open prompt float: " .. tostring(win))
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
		return false
	end

	local wo = vim.wo[win]
	wo.winhl = "FloatBorder:" .. border_hl
	wo.wrap = true
	wo.linebreak = true
	wo.breakindent = false
	wo.scrolloff = 0
	wo.sidescrolloff = 0
	wo.signcolumn = "no"
	wo.foldcolumn = "0"
	wo.number = false
	wo.relativenumber = false
	wo.cursorline = false
	wo.spell = false
	wo.list = false
	wo.conceallevel = 0

	state = {
		win = win,
		buf = buf,
		prev_win = prev_win,
		on_submit = opts.on_submit,
		width = width,
		height = height,
	}

	install_keymaps(buf)

	local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
		group = group,
		buffer = buf,
		callback = resize,
	})
	vim.api.nvim_create_autocmd("VimResized", {
		group = group,
		callback = resize,
	})

	vim.cmd("startinsert")
	log.debug("input: opened prompt float")
	return true
end

-- Test-only: drop state without touching windows. Not a public API.
function M._reset()
	state = nil
end

return M
