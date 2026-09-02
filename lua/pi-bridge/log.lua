local M = {}

local LEVELS = {
	trace = 0,
	debug = 1,
	info = 2,
	warn = 3,
	error = 4,
}

local LEVEL_NAMES = { "TRACE", "DEBUG", "INFO", "WARN", "ERROR" }

local log_path = nil
local level_threshold = LEVELS.info

local function timestamp()
	return os.date("%Y-%m-%d %H:%M:%S")
end

local function write_line(line)
	if not log_path then return end
	local f = io.open(log_path, "a")
	if not f then return end
	f:write(line .. "\n")
	f:close()
end

function M.init(path, level)
	level_threshold = LEVELS[level] or LEVELS.info

	local dir = vim.fn.fnamemodify(path, ":h")
	vim.fn.mkdir(dir, "p")

	log_path = path
	M.info("log opened: " .. path)
end

function M.log(level, msg)
	if LEVELS[level] == nil then return end
	if LEVELS[level] < level_threshold then return end

	local idx = LEVELS[level] + 1
	local line = string.format("[%s] [%s] %s", timestamp(), LEVEL_NAMES[idx], msg)
	write_line(line)
end

function M.trace(msg) M.log("trace", msg) end
function M.debug(msg) M.log("debug", msg) end
function M.info(msg)  M.log("info", msg) end
function M.warn(msg)  M.log("warn", msg) end
function M.error(msg) M.log("error", msg) end

return M
