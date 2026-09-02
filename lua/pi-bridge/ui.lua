local log = require("pi-bridge.log")

local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("pi-bridge")

function M.notify(msg, level)
	level = level or vim.log.levels.INFO
	vim.notify("pi-bridge: " .. msg, level)
end

function M.on_agent_start(msg)
	local detail = msg.message or "working..."
	log.info("agent_start: " .. detail)
	M.notify("▸ " .. detail, vim.log.levels.INFO)
end

function M.on_agent_end(msg)
	local detail = msg.message or "done"
	log.info("agent_end: " .. detail)
	M.notify("▪ " .. detail, vim.log.levels.INFO)
end

function M.on_file_edited(msg)
	if not msg.file then
		log.warn("file_edited: missing file field")
		return
	end

	local file = vim.fn.resolve(msg.file)
	log.info("file_edited: " .. file)

	-- Find buffers visiting this file
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.fn.resolve(vim.api.nvim_buf_get_name(buf)) == file then
			-- Clear previous highlights
			vim.api.nvim_buf_clear_namespace(buf, NAMESPACE, 0, -1)

			-- Add a subtle highlight to edited lines
			local line_count = vim.api.nvim_buf_line_count(buf)
			for i = 0, line_count - 1 do
				vim.api.nvim_buf_set_extmark(buf, NAMESPACE, i, 0, {
					line_hl_group = "Visual",
					hl_mode = "blend",
				})
			end

			log.debug("highlighted " .. line_count .. " lines in " .. file)
			break
		end
	end
end

return M
