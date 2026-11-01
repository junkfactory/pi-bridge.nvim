local M = {}

-- True when |arglead| looks like a filesystem path rather than prose.
function M.path_like(arglead)
	if type(arglead) ~= "string" then return false end
	if arglead:find("/", 1, true) then return true end
	return arglead:sub(1, 1) == "~"
		or arglead:sub(1, 2) == "./"
		or arglead:sub(1, 3) == "../"
end

-- @placeholder suggestions. Body moved verbatim from the old
-- _pi_bridge_complete in init.lua: a bare "@" still yields the full list,
-- a partial "@pre" yields prefix matches.
function M.placeholder_candidates(arglead)
	local names = require("pi-bridge.placeholders").PLACEHOLDERS
	local prefix = arglead:match("@(%w*)$")
	if not prefix then
		local all = {}
		for _, name in ipairs(names) do
			table.insert(all, "@" .. name)
		end
		return all
	end
	local matches = {}
	for _, name in ipairs(names) do
		if name:find(prefix, 1, true) == 1 then
			table.insert(matches, "@" .. name)
		end
	end
	return matches
end

-- Directories are offered with a trailing separator so the next completion
-- level can be triggered right away.
local function normalize(candidate)
	if candidate ~= "" and candidate:sub(-1) ~= "/" and vim.fn.isdirectory(candidate) == 1 then
		return candidate .. "/"
	end
	return candidate
end

-- Candidates for the prompt input: @placeholder branch first, then the path
-- branch, otherwise nothing (plain words never complete).
-- |dispatcher| is injectable so tests can stub the placeholder provider.
function M.complete(arglead, dispatcher)
	if type(arglead) ~= "string" then return {} end

	if arglead:match("@(%w*)$") then
		return (dispatcher or M.placeholder_candidates)(arglead)
	end

	if not M.path_like(arglead) then return {} end

	local seen, out = {}, {}
	local function add(candidate)
		if candidate == nil or candidate == "" then return end
		local path = normalize(candidate)
		if seen[path] then return end
		seen[path] = true
		table.insert(out, path)
	end

	-- filesystem candidates (getcompletion returns unescaped strings)
	for _, candidate in ipairs(vim.fn.getcompletion(arglead, "file")) do
		add(candidate)
	end

	-- open buffers, kept only when they extend the lead literally
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		local name = ""
		if vim.api.nvim_buf_is_valid(buf) and vim.fn.buflisted(buf) == 1 then
			name = vim.api.nvim_buf_get_name(buf)
		end
		if name ~= "" and name:sub(1, #arglead) == arglead then
			add(name)
		end
	end

	table.sort(out, function(a, b) return a:lower() < b:lower() end)
	return out
end

-- 0-based byte column where the @placeholder / path token under the cursor
-- starts, or nil when the token is not completable.
function M.token_start(line, col)
	if type(line) ~= "string" or type(col) ~= "number" then return nil end
	local head = line:sub(1, col)
	local token = head:match("([^%s]*)$")
	if token == nil or token == "" then return nil end
	local start = col - #token
	if token:match("^@%w*$") or M.path_like(token) then return start end
	return nil
end

-- 'completefunc' adapter: vim.bo.completefunc = "v:lua._pi_bridge_input_complete".
function M.completefunc(findstart, base)
	if findstart == 1 then
		local line = vim.api.nvim_get_current_line()
		local col = vim.api.nvim_win_get_cursor(0)[2]
		local start = M.token_start(line, col)
		if start == nil then return -3 end -- cancel silently, leave completion mode
		return start
	end
	return M.complete(base)
end

return M
