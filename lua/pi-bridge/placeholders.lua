local log = require("pi-bridge.log")

local M = {}

local VISUAL_MODES = { v = true, V = true, ["\22"] = true }

local SEVERITY_NAMES = {
	[1] = "ERROR",
	[2] = "WARN",
	[3] = "INFO",
	[4] = "HINT",
}

local function buf_filetype()
	local ft = vim.bo.filetype
	return ft ~= "" and ft or "text"
end

-- Opening fence long enough to survive backtick runs in the content
-- (CommonMark: a closing fence is a line-start run >= opening length,
-- so opening with longest-run+1 can never be closed early).
local function fence_marker(value)
	local longest = 0
	for _, line in ipairs(vim.split(value, "\n")) do
		local run = line:match("^`+")
		if run and #run > longest then longest = #run end
	end
	return string.rep("`", math.max(3, longest + 1))
end

-- Format a substitution as a markdown fenced code block. No space between
-- the marker and the language (canonical info-string form). Blank lines
-- pad both sides so surrounding text ("in @this replace foo") forms its
-- own paragraphs — a fence must start at line start, and padding prevents
-- lazy continuation.
local function format_fence(value, filetype)
	local marker = fence_marker(value)
	return "\n\n" .. marker .. filetype .. "\n" .. value .. "\n" .. marker .. "\n\n"
end

local function resolve_this()
	local row = vim.api.nvim_win_get_cursor(0)[1]
	local line = vim.api.nvim_get_current_line()
	return format_fence(line, buf_filetype()), row, row
end

-- getpos returns BYTE columns. For charwise selections we want CHAR columns
-- (so a multibyte char on the boundary is included whole instead of being
-- sliced in half by byte-based string.sub). vim.fn.charcol({lnum,col})
-- does NOT convert byte col to char col (it treats col as charcol), so we
-- walk the line's chars and tally bytes. The byte col is 1-indexed to
-- match getpos.
local function bytecol_to_charcol(line, bytecol)
	local byte = 1
	local char = 1
	while byte < bytecol do
		local ch = vim.fn.strcharpart(line, char - 1, 1)
		if ch == "" then
			break
		end
		local w = #ch
		-- bytecol landing inside a multibyte char snaps to that char's
		-- start so the selection ends on the START of the multibyte char
		-- rather than cutting it in half.
		if byte + w > bytecol then
			break
		end
		byte = byte + w
		char = char + 1
	end
	return char
end

-- For blockwise selections the cursor moves on SCREEN (virtual) columns —
-- not bytes. Using the byte col directly with string.sub would land inside
-- a multibyte char on the edge and produce invalid UTF-8. virtcol({lnum,
-- bytecol}) interprets bytecol as a byte position and returns the virtcol
-- at that byte (right edge of the char containing it for wide chars).
local function bytecol_to_virtcol(pos)
	return vim.fn.virtcol({ pos[2], pos[3] })
end

-- Slice `line` by 1-based CHAR columns [start_char, end_char], inclusive.
-- Equivalent to string.sub for ASCII (each char is one byte wide).
local function sub_chars(line, start_char, end_char)
	if end_char < start_char then
		return ""
	end
	return vim.fn.strcharpart(line, start_char - 1, end_char - start_char + 1)
end

-- Extract the text spanned by two marks. `linewise` keeps full lines
-- (V selections span whole lines; column trimming would cut them).
local function extract_selection(start_pos, end_pos, linewise)
	local start_line = start_pos[2]
	local end_line = end_pos[2]

	-- normalize line order first so we fetch the right lines
	if start_line > end_line then
		start_line, end_line = end_line, start_line
		start_pos, end_pos = end_pos, start_pos
	end

	local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
	if #lines == 0 then
		return ""
	end

	-- Convert the byte cols to char cols against the actual line text.
	-- For the start line, use that line; for the end line, use the
	-- corresponding line in the fetched list (last element when more
	-- than one line was fetched).
	local start_byte_col = start_pos[3]
	local end_byte_col = end_pos[3]
	local start_col = bytecol_to_charcol(lines[1], start_byte_col)
	local end_col = bytecol_to_charcol(lines[#lines], end_byte_col)

	-- normalize char-col order for same-line selections
	if start_line == end_line and start_col > end_col then
		start_col, end_col = end_col, start_col
	end

	if linewise then
		return table.concat(lines, "\n"), start_line, end_line
	end

	-- trim first line from start_col to end-of-line, last line from 1 to end_col
	if #lines == 1 then
		lines[1] = sub_chars(lines[1], start_col, end_col)
	else
		lines[1] = sub_chars(lines[1], start_col, vim.fn.strchars(lines[1]))
		lines[#lines] = sub_chars(lines[#lines], 1, end_col)
	end

	return table.concat(lines, "\n"), start_line, end_line
end

-- Blockwise (Ctrl-V): apply the block's screen-column range to every line
-- individually. Lines whose display width is shorter than the block's start
-- column are excluded, matching vim's own behavior when yanking a block.
-- Each kept line is sliced by WHOLE characters — a multibyte char whose
-- span crosses the block edge is included or excluded whole, never split
-- mid-byte.
local function extract_block_selection(pos_a, pos_b)
	local start_line = math.min(pos_a[2], pos_b[2])
	local end_line = math.max(pos_a[2], pos_b[2])
	local start_vcol = math.min(bytecol_to_virtcol(pos_a), bytecol_to_virtcol(pos_b))
	local end_vcol = math.max(bytecol_to_virtcol(pos_a), bytecol_to_virtcol(pos_b))

	local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
	local out = {}
	for _, line in ipairs(lines) do
		if vim.fn.strdisplaywidth(line) >= start_vcol then
			-- Walk chars; include iff the char's starting screen col is
			-- inside [start_vcol, end_vcol]. A wide/multibyte char whose
			-- start col equals end_vcol is included (that's the inclusive
			-- right edge), but a char starting past it is excluded.
			local pieces = {}
			local col = 1
			local nchars = vim.fn.strchars(line)
			for i = 1, nchars do
				if col > end_vcol then
					break
				end
				local ch = vim.fn.strcharpart(line, i - 1, 1)
				local w = vim.fn.strdisplaywidth(ch)
				-- Include iff the char's virtcol range overlaps the block's
				-- range: char's right edge (col + w - 1) >= block start AND
				-- char's left edge (col) <= block end. The break above
				-- already enforces the left-edge test, so only the right-
				-- edge test remains.
				if col + w - 1 >= start_vcol then
					table.insert(pieces, ch)
				end
				col = col + w
			end
			table.insert(out, table.concat(pieces, ""))
		end
	end
	return table.concat(out, "\n"), start_line, end_line
end

local function resolve_selection()
	local mode = vim.fn.mode()
	local text, start_line, end_line
	if VISUAL_MODES[mode] then
		-- Active visual mode: the '< and '> marks are NOT set yet — they are
		-- only written when visual mode exits. A visual keymap that opens a
		-- prompt (nvim 0.12's ui.input runs in cmdline mode and restores
		-- visual mode afterwards) reaches resolve() while visual is still
		-- active. Read the 'v and '.' marks, which are valid then.
		if mode == "\22" then
			text, start_line, end_line = extract_block_selection(vim.fn.getpos("v"), vim.fn.getpos("."))
		else
			text, start_line, end_line = extract_selection(vim.fn.getpos("v"), vim.fn.getpos("."), mode == "V")
		end
	else
		-- Exited visual mode: the input widget the keymap opened has taken
		-- focus. Which one decides the state we see here — a floating input
		-- (e.g. snacks.nvim overriding vim.ui.input under LazyVim) exits
		-- visual mode, so '< and '> are set; the nvim 0.12 builtin cmdline
		-- input restores visual mode instead (handled above). Either way
		-- vim.fn.visualmode() returns the last visual mode used ('v', 'V',
		-- or '\22') and persists after exiting, unlike vim.fn.mode().
		local last_visual = vim.fn.visualmode()
		if not VISUAL_MODES[last_visual] then
			return ""
		end
		if last_visual == "\22" then
			text, start_line, end_line = extract_block_selection(vim.fn.getpos("'<"), vim.fn.getpos("'>"))
		else
			text, start_line, end_line = extract_selection(vim.fn.getpos("'<"), vim.fn.getpos("'>"), last_visual == "V")
		end
	end
	if not text or text == "" then
		return ""
	end
	return format_fence(text, buf_filetype()), start_line, end_line
end

local function format_diagnostic(diag)
	local lnum = diag.lnum + 1
	local col = diag.col + 1
	local severity = SEVERITY_NAMES[diag.severity] or "UNKNOWN"
	return string.format("L%d:C%d [%s] %s", lnum, col, severity, diag.message)
end

local function resolve_diagnostics()
	local all_diags = vim.diagnostic.get(0)

	-- Collect all LSP diagnostic namespaces (both push and pull models).
	-- Neovim 0.10+ uses pull diagnostics by default for many servers,
	-- which store diagnostics under a different namespace than the
	-- traditional push model. We match by the nvim.lsp.* naming pattern.
	local lsp_namespaces = {}
	for ns_id, ns_meta in pairs(vim.diagnostic.get_namespaces()) do
		if ns_meta.name and ns_meta.name:find("^nvim%.lsp%.") then
			lsp_namespaces[ns_id] = true
		end
	end

	local diags = all_diags
	if not vim.tbl_isempty(lsp_namespaces) then
		diags = {}
		for _, diag in ipairs(all_diags) do
			if lsp_namespaces[diag.namespace] then
				table.insert(diags, diag)
			end
		end
	end

	if #diags == 0 then
		return "No diagnostics"
	end

	local lines = {}
	for _, diag in ipairs(diags) do
		table.insert(lines, format_diagnostic(diag))
	end
	return table.concat(lines, "\n")
end

local function resolve_buffer()
	return vim.api.nvim_buf_get_name(0)
end

local function resolve_buffers()
	local paths = {}
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.bo[bufnr].buflisted then
			local name = vim.api.nvim_buf_get_name(bufnr)
			if name ~= "" then
				table.insert(paths, name)
			end
		end
	end
	return table.concat(paths, "\n")
end

-- 900 KiB cap so payloads stay well under typical socket/transport limits
-- while still preserving meaningful context.
local CONTENT_BYTE_LIMIT = 900 * 1024

local function format_truncation_notice(shown, total, bytes_total)
	local mb_total = bytes_total / (1024 * 1024)
	return string.format(
		"[truncated: showing %d of %d lines, ~900KB of ~%.2fMB]",
		shown,
		total,
		mb_total
	)
end

local function resolve_content()
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local total = #lines
	local content = table.concat(lines, "\n")

	-- Empty buffer keeps the literal placeholder (pre-existing guard; the
	-- outer `value == ""` check in resolve_with_range preserves it).
	if content == "" then
		return ""
	end

	if #content <= CONTENT_BYTE_LIMIT then
		return format_fence(content, buf_filetype())
	end

	-- Take lines from the top until we'd exceed the byte budget, leaving
	-- room for the truncation notice itself.
	local kept = {}
	local kept_bytes = 0
	for _, line in ipairs(lines) do
		-- +1 accounts for the joining newline between lines
		local line_bytes = #line + 1
		if kept_bytes + line_bytes > CONTENT_BYTE_LIMIT then
			break
		end
		table.insert(kept, line)
		kept_bytes = kept_bytes + line_bytes
	end

	local shown = #kept
	local truncated = table.concat(kept, "\n") .. "\n" .. format_truncation_notice(shown, total, #content)
	return format_fence(truncated, buf_filetype())
end

-- Look up a single mark. `name` is one char: A-Z (global), a-z / 0-9
-- (buffer-local). Returns nil if the mark is unset (getpos lnum == 0)
-- or its buffer no longer exists.
local function get_mark(name)
	local pos = vim.fn.getpos("'" .. name)
	local bufnr, lnum = pos[1], pos[2]
	if lnum == 0 then return nil end
	if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
	if not vim.api.nvim_buf_is_valid(bufnr) then return nil end
	return { bufnr = bufnr, lnum = lnum }
end

-- Inline code span that survives backtick runs in the content
-- (CommonMark: a code span's delimiter run must be longer than any
-- backtick run inside, so opening with longest-run+1 can never close
-- early). Space-padded when the content itself starts or ends with a
-- backtick, as CommonMark requires for safe parsing. An empty line
-- yields an empty span ("``").
local function inline_code(value)
	local longest = 0
	for run in value:gmatch("`+") do
		if #run > longest then longest = #run end
	end
	local marker = string.rep("`", longest + 1)
	if value:sub(1, 1) == "`" or value:sub(-1) == "`" then
		return marker .. " " .. value .. " " .. marker
	end
	return marker .. value .. marker
end

-- Marks are context, not code to edit: cap the inline line so a huge
-- line can't flood the prompt. Char-based slicing keeps multibyte
-- characters whole.
local MAX_MARK_LINE_CHARS = 200

local function inline_mark_line(line)
	if vim.fn.strchars(line) <= MAX_MARK_LINE_CHARS then return line end
	return vim.fn.strcharpart(line, 0, MAX_MARK_LINE_CHARS) .. "…"
end

-- One mark rendered as a single line:
--   "Vim mark A - [file.lua:42](/abs/path/to/file.lua): `line content`"
-- mirroring the ext side's "File: [basename:line](abs)" link shape, so
-- the ref is clickable in pi's TUI and the model still sees the abs
-- path. Inline code instead of a fence: a mark is one line, and the
-- fence padding that made multi-mark prompts readable as blocks is
-- noise for a list of one-liners. The header carries file:line because
-- ctx.range is scoped to the current buffer and would lie for a mark in
-- another file. A mark in a NOT-LOADED buffer renders the header only:
-- fetching its line would force-load the buffer, and
-- nvim_buf_get_lines errors on unloaded ones. Unnamed buffers get a
-- plain "[No Name]:LINE:" header — there is no path to link to.
-- Block separation (blank line before the header) is added by the
-- callers, mirroring how format_fence pads its substitutions.
local function format_mark_block(name, mark)
	local path = vim.api.nvim_buf_get_name(mark.bufnr)
	local header
	if path == "" then
		header = string.format("Vim mark %s - [No Name]:%d:", name, mark.lnum)
	else
		local label = vim.fn.fnamemodify(path, ":t") .. ":" .. mark.lnum
		header = string.format("Vim mark %s - [%s](%s):", name, label, path)
	end
	if not vim.api.nvim_buf_is_loaded(mark.bufnr) then
		return header
	end
	local line = vim.api.nvim_buf_get_lines(mark.bufnr, mark.lnum - 1, mark.lnum, false)[1] or ""
	return header .. " " .. inline_code(inline_mark_line(line))
end

-- @marks: every set LETTER mark — globals A-Z first, then buffer-local
-- a-z across all listed buffers (getmarklist(buf) reports one buffer's
-- locals). Digits 0-9 are excluded: '0 and '1-'9 are auto-managed
-- (last-exit position / jump-and-delete stack) and churn without user
-- intent; @mN still accepts them for manual lookups. "" when none so the
-- caller keeps the literal placeholder.
local function resolve_marks()
	local blocks = {}

	local function add(m)
		local name = m.mark:match("%a") -- tolerates "'A" and "A" forms
		local bufnr, lnum = m.pos[1], m.pos[2]
		if not name or lnum == 0 then return end
		if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
		if not vim.api.nvim_buf_is_valid(bufnr) then return end
		table.insert(blocks, format_mark_block(name, { bufnr = bufnr, lnum = lnum }))
	end

	for _, m in ipairs(vim.fn.getmarklist()) do
		add(m)
	end
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.bo[bufnr].buflisted then
			for _, m in ipairs(vim.fn.getmarklist(bufnr)) do
				add(m)
			end
		end
	end

	-- "\n\n" before the first header keeps it on its own line when the
	-- placeholder fires mid-sentence, with a blank line of separation like
	-- a fence gets. Blocks are one-liners now, so the "\n" join lists
	-- them on consecutive lines. No marks -> "" so the caller keeps the
	-- literal.
	if #blocks == 0 then return "", nil, nil end
	return "\n\n" .. table.concat(blocks, "\n"), nil, nil
end

-- @mN: one mark, any letter/digit. Unset -> "" -> literal kept.
local function resolve_mark(name)
	local mark = get_mark(name)
	if not mark then return "" end
	-- Same padding resolve_marks gives its first block.
	return "\n\n" .. format_mark_block(name, mark), nil, nil
end

local RESOLVERS = {
	this = resolve_this,
	selection = resolve_selection,
	diagnostics = resolve_diagnostics,
	buffer = resolve_buffer,
	buffers = resolve_buffers,
	content = resolve_content,
	marks = resolve_marks,
}

M.PLACEHOLDERS = vim.tbl_keys(RESOLVERS)
table.sort(M.PLACEHOLDERS)

-- Like resolve(), but also returns a compact range string for the ranged
-- placeholders that fired ("25", "12-200", "25,40-45"), or nil.
--
-- The match also captures the spaces/tabs hugging the placeholder. When
-- the substitution is a block (fence or mark header, always starting
-- with "\n"), that adjacent whitespace is dropped: the block brings its
-- own blank-line padding, so "combining @this with" must not render as
-- "combining \n\n```...```\n\n with". Inline values (@buffer, @diagnostics,
-- ...) keep their surrounding spaces — they read like words in the
-- sentence ("see @buffer for details").
function M.resolve_with_range(text)
	local spans = {}
	local out = (string.gsub(text or "", "([ \t]*)@(%w+)([ \t]*)", function(pre, key, post)
		local resolver = RESOLVERS[key]
		-- @mN: a two-char key "m<mark>" is not in RESOLVERS; dispatch to
		-- the single-mark resolver. One-char "m" and longer keys fall
		-- through (all static names are >=3 chars, so no collision).
		if not resolver and #key == 2 and key:byte(1) == 109 then
			local n = key:sub(2, 2)
			if n:match("%w") then
				resolver = function() return resolve_mark(n) end
			end
		end
		if not resolver then
			return nil -- unknown placeholder: keep literal (with its spaces)
		end
		-- A resolver that errors must not break the whole send: fall
		-- back to the literal placeholder like the empty case below.
		local ok, value, start_line, end_line = pcall(resolver)
		if not ok then
			log.warn("placeholder @" .. key .. " failed to resolve: " .. tostring(value))
			return nil
		end
		if value == "" then
			-- Nothing to substitute (e.g. @selection with no selection):
			-- keep the literal so the user sees the placeholder didn't
			-- fire instead of silently losing it.
			return nil
		end
		if start_line then
			table.insert(spans, { start = start_line, ["end"] = end_line })
		end
		if value:sub(1, 1) == "\n" then
			return value -- block: drop the captured surrounding spaces
		end
		return pre .. value .. post
	end))
	table.sort(spans, function(a, b)
		return a.start < b.start or (a.start == b.start and a["end"] < b["end"])
	end)
	local parts, seen = {}, {}
	for _, r in ipairs(spans) do
		local s = r.start == r["end"] and tostring(r.start)
			or string.format("%d-%d", r.start, r["end"])
		if not seen[s] then
			seen[s] = true
			table.insert(parts, s)
		end
	end
	if #parts == 0 then return out, nil end
	return out, table.concat(parts, ",")
end

function M.resolve(text)
	return (M.resolve_with_range(text))
end

return M