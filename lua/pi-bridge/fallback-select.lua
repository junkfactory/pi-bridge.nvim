-- Fallback approval float for stock `vim.ui.select`.
--
-- `vim.ui.select` on a stock Neovim blocks in `inputlist()` and cannot
-- be dismissed programmatically. Plugins like dressing/snacks/fzf
-- change this so the picker returns control to the event loop and a
-- remote caller can close it. To stay usable on stock installs, we
-- ship our own minimal float for the approval prompt.
--
-- The float mechanics (scratch buffer, centered float, keymaps that
-- close-then-respond, prior-window restore, stale-window pruning) are
-- shared with the UI prompt mirror's stock-picker float via
-- `choice_float.lua`; this module owns the approval-specific content:
-- the prompt text, the y/a/n keymap spec, and the `approval_response`
-- message construction.
--
-- Lifecycle:
--   show(req, send)            open float, install buffer-local maps;
--                              user choice calls send_response then close()
--   close()                    dismiss silently (no echo, no response)
--   close_silent(reason_msg)   dismiss and echo `pi-bridge: <reason_msg>`
--                              (used by the pi-disconnect path)
--
-- Concurrency:
--   Only one float may be open at a time (defensive; pi serializes
--   approval_request but a stale request could race the wrapper path).

local log = require("pi-bridge.log")
local choice_float = require("pi-bridge.choice_float")

local M = {}

-- Owner slot in choice_float. Kept distinct from the mirror's slot so
-- an approval float and a mirror float can coexist.
local OWNER = "approval"

-- Visual styling: modest width, centered-ish, thin border. Width is
-- the TEXT area (choice_float adds its padding on top); sized for the
-- longest label (~50 chars) plus breathing room.
local WIN_WIDTH = 54
local WIN_HEIGHT = 6 -- prompt + blank + 3 choices (padding added by choice_float)

-- Labels mirror approval.lua's CHOICES. The y item avoids the letters
-- 'a'/'n' (and n avoids 'a'/'y') so fuzzy pickers that filter as you
-- type can only match each key to its own item — see approval.lua.
local CHOICE_LINES = {
	"y — yes to this edit",
	"a — approve all edits to this file (this session)",
	"n — reject this edit",
}

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

-- Public API (delegates to choice_float; signature-compatible with the
-- pre-refactor module so approval.lua and its tests are unchanged).

function M.close()
	choice_float.close(OWNER)
end

function M.close_silent(reason_msg)
	choice_float.close_silent(OWNER, reason_msg)
end

function M.is_open()
	return choice_float.is_open(OWNER)
end

function M.get_pending_id()
	return choice_float.get_id(OWNER)
end

function M.show(req, send)
	-- is_open() prunes a stale handle left by an external window close,
	-- so a poisoned state can't swallow the next request.
	if M.is_open() then
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
	local opened = choice_float.open({
		owner = OWNER,
		id = id,
		title = " pi approval ",
		width = WIN_WIDTH,
		height = WIN_HEIGHT,
		lines = vim.list_extend({ prompt, "" }, CHOICE_LINES),
		-- Esc and <C-c> dismiss-as-reject (same semantics as
		-- vim.ui.select).
		keys = {
			{ key = "y", value = "yes" },
			{ key = "a", value = "all" },
			{ key = "n", value = "no" },
			{ key = "<Esc>", value = "no" },
			{ key = "<C-c>", value = "no" },
		},
		on_choice = function(decision)
			-- choice_float closes before calling on_choice, matching the
			-- wrapper path's close-then-send order in approval.lua.
			send_response(send, id, decision)
		end,
	})
	if opened then
		log.info("fallback-select: opened for " .. id)
	end
end

-- Test-only: clear module state. Not part of the public API.
function M._reset()
	choice_float._reset()
end

return M
