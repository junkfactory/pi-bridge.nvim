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

local function detect_buffer_state(name)
	if name == "" then
		return "nameless"
	end
	local data_dir = vim.fn.stdpath("data")
	if name:find(data_dir .. "/scratch/", 1, true) then
		return "scratch"
	end
	if vim.fn.filereadable(name) == 0 then
		return "unsaved"
	end
	if vim.bo.modified then
		return "modified"
	end
	return "saved"
end

function M.get(mode)
	mode = mode or "normal"

	local file = vim.api.nvim_buf_get_name(0)
	local cwd = vim.fn.getcwd()
	local filetype = vim.bo.filetype
	local buffer_state = detect_buffer_state(file)

	return {
		file = file,
		cwd = cwd,
		mode = mode,
		filetype = filetype,
		buffer_state = buffer_state,
	}
end

return M
