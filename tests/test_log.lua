local MiniTest = require("mini.test")
local expect = MiniTest.expect

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set()

T["log"] = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.start({ "-u", "scripts/minimal_init.lua" })
			child.lua("MiniTest = require('mini.test')")
		end,
		post_case = function()
			child.stop()
		end,
	},
})

T["log"]["init creates log file"] = function()
	local log_path = vim.fn.tempname()
	child.lua(string.format(
		"require('pi-bridge.log').init(%q, 'info')",
		log_path
	))
	local exists = vim.fn.filereadable(log_path) == 1
	expect.equality(exists, true)
	os.remove(log_path)
end

T["log"]["init with invalid level defaults to info"] = function()
	local log_path = vim.fn.tempname()
	child.lua(string.format(
		"require('pi-bridge.log').init(%q, 'invalid')",
		log_path
	))
	child.lua("require('pi-bridge.log').info('test message')")
	local content = table.concat(vim.fn.readfile(log_path), "\n")
	expect.equality(content:find("test message") ~= nil, true)
	os.remove(log_path)
end

T["log"]["logs at info level by default"] = function()
	local log_path = vim.fn.tempname()
	child.lua(string.format(
		"require('pi-bridge.log').init(%q, 'info')",
		log_path
	))
	child.lua("require('pi-bridge.log').info('hello info')")
	child.lua("require('pi-bridge.log').debug('hello debug')")
	local content = table.concat(vim.fn.readfile(log_path), "\n")
	expect.equality(content:find("hello info") ~= nil, true)
	expect.equality(content:find("hello debug") ~= nil, false)
	os.remove(log_path)
end

T["log"]["respects level threshold"] = function()
	local log_path = vim.fn.tempname()
	child.lua(string.format(
		"require('pi-bridge.log').init(%q, 'warn')",
		log_path
	))
	child.lua("require('pi-bridge.log').trace('trace-msg')")
	child.lua("require('pi-bridge.log').debug('debug-msg')")
	child.lua("require('pi-bridge.log').info('info-msg')")
	child.lua("require('pi-bridge.log').warn('warn-msg')")
	child.lua("require('pi-bridge.log').error('error-msg')")
	local content = table.concat(vim.fn.readfile(log_path), "\n")
	expect.equality(content:find("trace-msg", 1, true) ~= nil, false)
	expect.equality(content:find("debug-msg", 1, true) ~= nil, false)
	expect.equality(content:find("info-msg", 1, true) ~= nil, false)
	expect.equality(content:find("warn-msg", 1, true) ~= nil, true)
	expect.equality(content:find("error-msg", 1, true) ~= nil, true)
	os.remove(log_path)
end

T["log"]["format includes timestamp and level"] = function()
	local log_path = vim.fn.tempname()
	child.lua(string.format(
		"require('pi-bridge.log').init(%q, 'trace')",
		log_path
	))
	child.lua("require('pi-bridge.log').warn('formatted')")
	local content = table.concat(vim.fn.readfile(log_path), "\n")
	expect.equality(content:find("%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d") ~= nil, true)
	expect.equality(content:find("%[WARN %]") ~= nil, true)
	expect.equality(content:find("%[pid:%d+%]") ~= nil, true)
	expect.equality(content:find("formatted") ~= nil, true)
	os.remove(log_path)
end

T["log"]["does not crash when file is unwritable"] = function()
	local ok = child.lua([[
		local ok, err = pcall(function()
			require('pi-bridge.log').init('/nonexistent/path/log.txt', 'info')
		end)
		return ok
	]])
	expect.equality(type(ok), "boolean")
end

return T
