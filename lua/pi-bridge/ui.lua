local log = require("pi-bridge.log")

local M = {}

-- Send/receive toast toggle, assigned from config in init.setup()
-- (cfg.notify). Errors and disconnect warnings bypass this gate —
-- they use direct vim.notify and stay always visible.
M.notify_enabled = true

function M.notify(msg, level)
	if not M.notify_enabled then return end
	level = level or vim.log.levels.INFO
	vim.schedule(function()
		vim.notify("𝜋 " .. msg, level)
	end)
end

-- Border accent for the pi-bridge float family (prompt input and the
-- choice_float boxes), resolved at every box open:
--
--   1. A `PiBridgeFloatBorder` definition with concrete colors (fg/bg)
--      is treated as the user's or colorscheme's own styling and
--      untouched. (A session can set or change it externally; we only
--      ever write an indirect link when nothing concrete exists.)
--   2. Otherwise, when snacks.nvim is active, its themed input border
--      group `SnacksInputBorder` is linked instead — it follows the
--      active colorscheme (LazyVim loads snacks, so this resolves on
--      the typical setup).
--   3. Fallback: the dim Comment link from before the themed path
--      existed.
--
-- The concrete-colors guard means a user override survives: the
-- window-local mapping stays `FloatBorder:PiBridgeFloatBorder`, only
-- what that group links to changes.
function M.border_hl()
	local name = "PiBridgeFloatBorder"
	local base = "Comment"
	if vim.fn.hlexists("SnacksInputBorder") == 1 then
		base = "SnacksInputBorder"
	end
	if vim.fn.hlexists(name) == 1 then
		local def = vim.api.nvim_get_hl(0, { name = name })
		local concrete = def
			and (def.fg ~= nil or def.bg ~= nil or def.ctermfg ~= nil or def.ctermbg ~= nil)
		if concrete then
			-- User/ colorscheme owns the border colors: leave it alone.
			return name
		end
	end
	vim.api.nvim_set_hl(0, name, { default = true, link = base })
	return name
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

function M.on_error(msg)
	local detail = msg.message or "delivery error"
	log.error("error event: " .. (msg.code or "unknown") .. ": " .. detail)
	vim.schedule(function()
		vim.notify("𝜋 " .. detail, vim.log.levels.ERROR)
	end)
end

return M
