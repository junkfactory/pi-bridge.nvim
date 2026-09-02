-- Socket discovery: walk up the directory tree from cwd to home,
-- probing each level for an active Unix socket.
--
-- Design decisions:
--
--   Why walk up, not just cwd:
--   Users often open nvim in a subdirectory of their project (e.g.
--   src/foo/bar/). The pi instance runs at the project root. Walking
--   up finds the socket without requiring the user to cd first.
--
--   Why a standalone probe, not socket.connect():
--   socket.connect() manages global connection state. Probing must not
--   interfere with an existing connection or leave stale state behind.
--   A lightweight pipe:connect + close is safer and avoids reentrancy
--   issues with vim.wait() inside socket.connect().
--
--   Why cache:
--   Walking is O(depth) connect attempts. Caching the result means
--   subsequent prompts skip the walk entirely. The cache is validated
--   on each call — if the cached socket is gone, we re-walk.

local log = require("pi-bridge.log")

local M = {}

local cached_path = nil

local PROBE_TIMEOUT_MS = 100

--- Compute the socket path for a given directory.
--- Mirrors pi-bridge.ext's hashCwd: sha256, hex, truncated to 16 chars.
---@param dir string absolute directory path
---@return string socket path
function M.socket_path_for_dir(dir)
	local hash = vim.fn.sha256(dir):sub(1, 16)
	return vim.fn.expand("~/.pi/agent/pi-bridge/sockets/") .. hash .. ".sock"
end

--- Clear the cached socket path. Call after launching pi so the next
--- find_socket() re-walks.
function M.clear_cache()
	cached_path = nil
end

--- Probe a single socket path by attempting a raw pipe connection.
--- Returns true if the socket is accepting connections.
--- Does NOT touch socket.lua's global state.
---@param path string socket file path
---@return boolean
local function probe(path)
	-- Quick check: does the file exist at all?
	local stat = vim.uv.fs_stat(path)
	if not stat then
		return false
	end

	local pipe = vim.uv.new_pipe(false)
	if not pipe then
		return false
	end

	local result = { ok = false, done = false }

	pipe:connect(path, function(err)
		if err then
			result.ok = false
		else
			result.ok = true
		end
		result.done = true
		if not pipe:is_closing() then
			pipe:close()
		end
	end)

	vim.wait(PROBE_TIMEOUT_MS, function()
		return result.done
	end, 5)

	-- Safety: ensure pipe is closed even if vim.wait timed out
	if not pipe:is_closing() then
		pipe:close()
	end

	return result.ok
end

--- Find the nearest active socket by walking from cwd up to home.
--- Returns the socket path via callback, or nil if none found.
---@param cb fun(path: string|nil)
function M.find_socket(cb)
	if cached_path then
		-- Validate cached path is still alive
		if probe(cached_path) then
			log.debug("resolve: using cached path " .. cached_path)
			cb(cached_path)
			return
		end
		log.debug("resolve: cached path stale, re-walking")
		cached_path = nil
	end

	local dir = vim.fn.getcwd()
	local home = vim.fn.expand("~")

	while true do
		local path = M.socket_path_for_dir(dir)
		log.debug("resolve: probing " .. path)

		if probe(path) then
			log.debug("resolve: found active socket at " .. path)
			cached_path = path
			cb(path)
			return
		end

		-- Reached home and it didn't have a socket — stop
		if dir == home then
			break
		end

		local parent = vim.fn.fnamemodify(dir, ":h")

		-- Reached filesystem root (parent == dir)
		if parent == dir then
			break
		end

		dir = parent
	end

	log.debug("resolve: no active socket found in cwd or parent directories")
	cb(nil)
end

return M
