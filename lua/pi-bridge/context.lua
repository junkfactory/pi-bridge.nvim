local M = {}

function M.get_visual_selection()
	local start_pos = vim.fn.getpos("v")
	local end_pos = vim.fn.getpos(".")

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
	if #lines == 0 then return nil, nil, nil end

	-- trim first line to start_col, last line to end_col
	if #lines == 1 then
		lines[1] = string.sub(lines[1], start_col, end_col)
	else
		lines[1] = string.sub(lines[1], start_col)
		lines[#lines] = string.sub(lines[#lines], 1, end_col)
	end

	return lines, start_line, end_line
end

local SURROUND_RADIUS = 10

function M.get(mode)
	mode = mode or "normal"

	local file = vim.api.nvim_buf_get_name(0)
	local cwd = vim.fn.getcwd()
	local filetype = vim.bo.filetype

	local content
	local cursor
	local current_line
	local surrounding

	if mode == "visual" then
		local lines = M.get_visual_selection()
		if lines then
			content = table.concat(lines, "\n")
		end
	else
		-- normal mode: send lightweight context instead of full buffer
		local pos = vim.api.nvim_win_get_cursor(0)
		local row = pos[1]
		local col = pos[2]
		cursor = { line = row, col = col }
		current_line = vim.api.nvim_get_current_line()

		-- surrounding lines for local scope
		local total = vim.api.nvim_buf_line_count(0)
		local start = math.max(1, row - SURROUND_RADIUS)
		local finish = math.min(total, row + SURROUND_RADIUS)
		local lines = vim.api.nvim_buf_get_lines(0, start - 1, finish, false)
		surrounding = table.concat(lines, "\n")
	end

	return {
		file = file,
		cwd = cwd,
		content = content,
		mode = mode,
		filetype = filetype,
		cursor = cursor,
		current_line = current_line,
		surrounding = surrounding,
	}
end

return M
