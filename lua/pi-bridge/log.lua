local M = {}

local LEVELS = {
	trace = 0,
	debug = 1,
	info = 2,
	warn = 3,
	error = 4,
}

local LEVEL_NAMES = { "TRACE", "DEBUG", "INFO", "WARN", "ERROR" }

local fd = nil
local level_threshold = LEVELS.info

local function timestamp()
	return os.date("%Y-%m-%d %H:%M:%S")
end

local function write_line(line)
	if not fd then return end
	local ok, err = pcall(vim.uv.fs_write, fd, line .. "\n", -1)
	if not ok then
		-- swallow I/O errors — logging must never crash
	end
end

function M.init(path, level)
	level_threshold = LEVELS[level] or LEVELS.info

	local dir = vim.fn.fnamemodify(path, ":h")
	vim.fn.mkdir(dir, "p")

	local err, handle = vim.uv.fs_open(path, "a", 438) -- 0666
	if handle then
		fd = handle
		M.info("log opened: " .. path)
	else
		-- can't open log file — silently continue
	end
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
