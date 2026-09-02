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

-- Per-attempt probe budget. Short on purpose: a real pi instance
-- accepts the connection immediately, so anything close to this is
-- suspicious (stale socket, wrong file type, kernel refusing). Keep
-- bounded so a deep directory walk does not stall the UI.
local PROBE_TIMEOUT_MS = 100

--- Compute the socket path for a given directory.
--- Mirrors pi-bridge.ext's hashCwd: sha256, hex, truncated to 16 chars.
---@param dir string absolute directory path
---@return string socket path
function M.socket_path_for_dir(dir)
	local hash = vim.fn.sha256(dir):sub(1, 16)
	return vim.fn.expand("~/.pi/agent/pi-bridge/sockets/") .. hash .. ".sock"
end

--- Probe outcome returned to callers. We carry the raw error so the
--- outer walk can decide whether a "stale-looking" result is worth
--- retrying or just reporting. `ok` is the single boolean we care
--- about; `reason` is for logging.
---@class ResolveProbeResult
---@field ok boolean true if the socket is accepting connections
---@field reason string|nil human-readable failure reason for logs
---@field timed_out boolean true if the probe budget was exhausted

--- Clear the cached socket path. Call after launching pi so the next
--- find_socket() re-walks.
function M.clear_cache()
	cached_path = nil
end

--- Probe a single socket path by attempting a raw pipe connection.
--- Returns a result table; never raises. Does NOT touch socket.lua's
--- global connection state.
---
--- Closing the pipe is centralized in one helper so the success,
--- error, and timeout paths all close exactly once. After the
--- timeout, a late connect callback is treated as no-op: the result
--- is final.
---@param path string socket file path
---@return ResolveProbeResult
local function probe(path)
	local result = { ok = false, reason = nil, timed_out = false }

	-- Quick check: does the file exist at all? Skip pipe creation
	-- entirely for missing sockets; this is the common case during
	-- the upward walk and avoids leaking handles on every probe.
	local stat = vim.uv.fs_stat(path)
	if not stat then
		result.reason = "no such file"
		return result
	end

	local pipe = vim.uv.new_pipe(false)
	if not pipe then
		result.reason = "failed to allocate pipe"
		return result
	end

	-- `finalized` guards against late callbacks flipping a result
	-- after the timeout has already been reported. Once true, the
	-- connect callback only closes the pipe and exits.
	local finalized = false
	local closed = false
	local function close_once()
		if closed then return end
		closed = true
		if pipe and not pipe:is_closing() then
			pipe:close()
		end
	end

	pipe:connect(path, function(err)
		if finalized then
			-- Timed out already. Result is final; just release the handle.
			close_once()
			return
		end

		finalized = true
		if err then
			result.ok = false
			result.reason = tostring(err)
		else
			result.ok = true
		end
		close_once()
	end)

	local wait_ok = vim.wait(PROBE_TIMEOUT_MS, function()
		return finalized
	end, 5)

	if not wait_ok then
		-- Timed out. Mark final and ignore the eventual callback.
		finalized = true
		result.timed_out = true
		result.reason = "probe timed out after " .. PROBE_TIMEOUT_MS .. "ms"
		log.debug("resolve: probe " .. path .. " timed out")
	end

	-- Belt-and-braces: ensure the handle is released even if no
	-- callback ever fires (defensive; libuv guarantees a callback).
	close_once()

	return result
end

--- Find the nearest active socket by walking from cwd up to home.
--- Returns the socket path via callback, or nil if none found.
--- The callback is invoked exactly once, on the next libuv tick.
---@param cb fun(path: string|nil)
function M.find_socket(cb)
	if cached_path then
		-- Validate cached path is still alive
		local cached = probe(cached_path)
		if cached.ok then
			log.debug("resolve: using cached path " .. cached_path)
			cb(cached_path)
			return
		end
		log.debug("resolve: cached path stale (" .. (cached.reason or "unreachable") .. "), re-walking")
		cached_path = nil
	end

	local dir = vim.fn.getcwd()
	local home = vim.fn.expand("~")

	while true do
		local path = M.socket_path_for_dir(dir)

		local p = probe(path)
		if p.ok then
			log.debug("resolve: found active socket at " .. path)
			cached_path = path
			cb(path)
			return
		end

		-- Log useful failure reasons at debug level; "no such file"
		-- is the expected case during most of the walk and stays quiet.
		if p.reason and p.reason ~= "no such file" then
			log.debug("resolve: probe " .. path .. " failed: " .. p.reason)
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
