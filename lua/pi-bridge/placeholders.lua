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

local function resolve_selection()
	-- Check current mode first (works when called directly in visual mode).
	-- If not in visual mode, check if we just exited visual mode via a keymap.
	-- vim.fn.visualmode() returns the last visual mode character ('v', 'V', or '\22')
	-- and persists after exiting visual mode, unlike vim.fn.mode() which returns 'n'.
	local mode = vim.fn.mode()
	if not VISUAL_MODES[mode] then
		local last_visual = vim.fn.visualmode()
		if not VISUAL_MODES[last_visual] then
			return ""
		end
	end

	-- Use persistent marks '< and '> which survive exiting visual mode.
	-- The 'v' and '.' marks are only valid during active visual mode.
	local start_pos = vim.fn.getpos("'<")
	local end_pos = vim.fn.getpos("'>")

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

	-- trim first line to start_col, last line to end_col
	if #lines == 1 then
		lines[1] = string.sub(lines[1], start_col, end_col)
	else
		lines[1] = string.sub(lines[1], start_col)
		lines[#lines] = string.sub(lines[#lines], 1, end_col)
	end

	return table.concat(lines, "\n")
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

local RESOLVERS = {
	this = resolve_this,
	selection = resolve_selection,
	diagnostics = resolve_diagnostics,
}

M.PLACEHOLDERS = vim.tbl_keys(RESOLVERS)
table.sort(M.PLACEHOLDERS)

function M.resolve(text)
	if type(text) ~= "string" or text == "" then
		return text or ""
	end

	return (string.gsub(text, "@(%w+)", function(key)
		local resolver = RESOLVERS[key]
		if resolver then
			return resolver()
		end
		return "@" .. key
	end))
end

return M