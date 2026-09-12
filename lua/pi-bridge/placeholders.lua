local log = require("pi-bridge.log")

local M = {}

local VISUAL_MODES = { v = true, V = true, ["\22"] = true }

local SEVERITY_NAMES = {
	[1] = "ERROR",
	[2] = "WARN",
	[3] = "INFO",
	[4] = "HINT",
}

local function resolve_this()
	local row = vim.api.nvim_win_get_cursor(0)[1]
	local line = vim.api.nvim_get_current_line()
	return string.format("line %d: %s", row, line)
end

-- Extract the text spanned by two marks. `linewise` keeps full lines
-- (V selections span whole lines; column trimming would cut them).
local function extract_selection(start_pos, end_pos, linewise)
	local start_line = start_pos[2]
	local start_col = start_pos[3]
	local end_line = end_pos[2]
	local end_col = end_pos[3]

	-- normalize so start < end
	if start_line > end_line or (start_line == end_line and start_col > end_col) then
		start_line, end_line = end_line, start_line
		start_col, end_col = end_col, start_col
	end

	local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
	if #lines == 0 then
		return ""
	end

	if linewise then
		return table.concat(lines, "\n")
	end

	-- trim first line to start_col, last line to end_col
	if #lines == 1 then
		lines[1] = string.sub(lines[1], start_col, end_col)
	else
		lines[1] = string.sub(lines[1], start_col)
		lines[#lines] = string.sub(lines[#lines], 1, end_col)
	end

	return table.concat(lines, "\n")
end

local function resolve_selection()
	local mode = vim.fn.mode()
	if VISUAL_MODES[mode] then
		-- Active visual mode: the '< and '> marks are NOT set yet — they are
		-- only written when visual mode exits. A visual keymap that opens a
		-- prompt (nvim 0.12's ui.input runs in cmdline mode and restores
		-- visual mode afterwards) reaches resolve() while visual is still
		-- active. Read the 'v and '.' marks, which are valid then.
		return extract_selection(vim.fn.getpos("v"), vim.fn.getpos("."), mode == "V")
	end

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
	return extract_selection(vim.fn.getpos("'<"), vim.fn.getpos("'>"), last_visual == "V")
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

	if #content <= CONTENT_BYTE_LIMIT then
		return content
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
	return table.concat(kept, "\n") .. "\n" .. format_truncation_notice(shown, total, #content)
end

local RESOLVERS = {
	this = resolve_this,
	selection = resolve_selection,
	diagnostics = resolve_diagnostics,
	buffer = resolve_buffer,
	buffers = resolve_buffers,
	content = resolve_content,
}

M.PLACEHOLDERS = vim.tbl_keys(RESOLVERS)
table.sort(M.PLACEHOLDERS)

function M.resolve(text)
	if type(text) ~= "string" or text == "" then
		return text or ""
	end

	return (string.gsub(text, "@(%w+)", function(key)
		local resolver = RESOLVERS[key]
		if not resolver then
			return nil -- unknown placeholder: keep literal
		end
		-- A resolver that errors must not break the whole send: fall
		-- back to the literal placeholder like the empty case below.
		local ok, value = pcall(resolver)
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
		return value
	end))
end

return M