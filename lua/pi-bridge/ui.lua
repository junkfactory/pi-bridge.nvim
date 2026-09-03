local log = require("pi-bridge.log")

local M = {}

function M.notify(msg, level)
	level = level or vim.log.levels.INFO
	vim.notify("𝜋 " .. msg, level)
end

function M.on_agent_start(msg)
	local detail = msg.message or "working..."
	log.info(msg.type .. ": " .. detail)
	M.notify(detail, vim.log.levels.INFO)
end

function M.on_agent_end(msg)
	local detail = msg.message or "done"
	log.info(msg.type .. ": " .. detail)
	M.notify(detail, vim.log.levels.INFO)
	vim.schedule(function()
		pcall(function() vim.cmd("checktime") end)
	end)
end

return M
