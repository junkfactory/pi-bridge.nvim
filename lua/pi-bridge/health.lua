local M = {}

local SOCKET_DIR = vim.fn.expand("~/.pi/agent/pi-bridge/sockets/")
local EXTENSION_PATH = vim.fn.expand("~/.pi/agent/extensions/pi-bridge.ts")

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
	local stat = vim.uv.fs_stat(EXTENSION_PATH)
	if stat then
		vim.health.ok("pi-bridge extension found: " .. EXTENSION_PATH)
	else
		vim.health.warn("pi-bridge extension not found: " .. EXTENSION_PATH, {
			"Install pi-bridge.ext for full functionality",
			"See: https://github.com/junkfactory/pi-bridge",
		})
	end
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

local function check_socket_status()
	local socket = require("pi-bridge.socket")
	if socket.is_connected() then
		vim.health.ok("Socket: connected")
	else
		-- Check if the expected socket file exists
		local cwd = vim.fn.getcwd()
		local hash = vim.fn.sha256(cwd):sub(1, 16)
		local path = SOCKET_DIR .. hash .. ".sock"
		local stat = vim.uv.fs_stat(path)
		if stat then
			vim.health.warn("Socket file exists but not connected: " .. path, {
				"Run :PiBridge to connect",
			})
		else
			vim.health.info("Socket: not connected (no socket file for current cwd)")
		end
	end
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
