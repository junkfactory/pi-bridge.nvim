local M = {}

local SOCKET_DIR = vim.fn.expand("~/.pi/agent/pi-bridge/sockets/")
local EXTENSION_PATHS = {
	vim.fn.expand("~/.pi/agent/git/github.com/junkfactory/pi-bridge.ext/src/index.ts"),
	vim.fn.expand("~/.pi/agent/extensions/pi-bridge.ts"),
}

local function check_pi_binary()
	local pi_path = vim.fn.exepath("pi")
	if pi_path ~= "" then
		vim.health.ok("`pi` binary found: " .. pi_path)
	else
		vim.health.error("`pi` binary not found in $PATH", {
			"Install pi or add its directory to $PATH",
		})
	end
end

local function check_socket_dir()
	local stat = vim.uv.fs_stat(SOCKET_DIR)
	if stat and stat.type == "directory" then
		vim.health.ok("Socket directory exists: " .. SOCKET_DIR)
	else
		-- Try to create it (read-only check from user perspective; dir creation is harmless)
		local ok = vim.fn.mkdir(SOCKET_DIR, "p")
		if ok == 1 then
			vim.health.ok("Socket directory created: " .. SOCKET_DIR)
		else
			vim.health.error("Cannot create socket directory: " .. SOCKET_DIR, {
				"Check filesystem permissions",
			})
		end
	end
end

local function check_extension()
	for _, path in ipairs(EXTENSION_PATHS) do
		local stat = vim.uv.fs_stat(path)
		if stat then
			vim.health.ok("pi-bridge extension found: " .. path)
			return
		end
	end
	vim.health.warn("pi-bridge extension not found", {
		"Install pi-bridge.ext for full functionality",
		"See: https://github.com/junkfactory/pi-bridge.ext",
	})
end

local function check_autochdir()
	if vim.o.autochdir then
		vim.health.warn("autochdir is enabled", {
			"pi-bridge uses cwd for socket matching; autochdir changes cwd per-file",
			"Disable autochdir or use :lcd/:cd for project-level switching",
		})
	else
		vim.health.ok("autochdir is disabled")
	end
end

-- Probe a single socket path's availability, mirroring resolve.lua's
-- internal probe but only exposing what health needs: file presence
-- and whether the kernel accepts the connection. Health must never
-- mutate socket.lua's persistent connection state.
---@param path string socket file path
---@return { exists: boolean, accepts: boolean, reason: string|nil }
local function probe_for_health(path)
	local stat = vim.uv.fs_stat(path)
	if not stat then
		return { exists = false, accepts = false, reason = "no such file" }
	end

	local pipe = vim.uv.new_pipe(false)
	if not pipe then
		return { exists = true, accepts = false, reason = "failed to allocate pipe" }
	end

	local result = { accepts = false, done = false, reason = nil }
	local closed = false
	local function close_once()
		if closed then return end
		closed = true
		if pipe and not pipe:is_closing() then
			pipe:close()
		end
	end

	pipe:connect(path, function(err)
		if result.done then
			close_once()
			return
		end
		result.done = true
		if err then
			result.accepts = false
			result.reason = tostring(err)
		else
			result.accepts = true
		end
		close_once()
	end)

	-- Bounded wait; we don't need resolve's full 100ms here because
	-- health is informational. If a probe stalls the call still
	-- returns promptly.
	vim.wait(100, function() return result.done end, 5)

	if not result.done then
		result.done = true
		result.reason = "probe timed out"
	end

	close_once()

	return {
		exists = true,
		accepts = result.accepts,
		reason = result.reason,
	}
end

local function check_socket_status()
	local socket = require("pi-bridge.socket")
	if socket.is_connected() then
		vim.health.ok("Socket: connected")
		return
	end

	-- No persistent Neovim connection. Distinguish three sub-states
	-- using a single probe at the cwd socket path (no upward walk —
	-- health is fast and informational; the full walk belongs to
	-- the runtime resolver).
	local resolve = require("pi-bridge.resolve")
	local cwd_path = resolve.socket_path_for_dir(vim.fn.getcwd())
	local probe = probe_for_health(cwd_path)

	if probe.accepts then
		-- Server is up and listening, but Neovim hasn't connected.
		vim.health.info("Socket available, Neovim not connected: " .. cwd_path, {
			"Run :PiBridge to send a prompt",
		})
		return
	end

	if probe.exists then
		-- File is there but the kernel won't accept the connection
		-- (stale socket, leftover from a crashed pi, or wrong file
		-- type). Surface the reason when we have one.
		local msg = "Socket file present but unreachable: " .. cwd_path
		if probe.reason then
			msg = msg .. " (" .. probe.reason .. ")"
		end
		vim.health.warn(msg, {
			"Remove the stale file or relaunch pi",
		})
		return
	end

	-- No file at all in this cwd. Don't walk upward; that's the
	-- runtime resolver's job. Health reports the local cwd state.
	vim.health.info("Socket: not connected (no socket file in cwd)")
end

function M.check()
	vim.health.start("pi-bridge.nvim")

	check_pi_binary()
	check_socket_dir()
	check_extension()
	check_autochdir()
	check_socket_status()
end

return M
