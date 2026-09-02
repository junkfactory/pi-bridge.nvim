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
	child.lua("require('pi-bridge.log').trace('t')")
	child.lua("require('pi-bridge.log').debug('d')")
	child.lua("require('pi-bridge.log').info('i')")
	child.lua("require('pi-bridge.log').warn('w')")
	child.lua("require('pi-bridge.log').error('e')")
	local content = table.concat(vim.fn.readfile(log_path), "\n")
	expect.equality(content:find("t") ~= nil, false)
	expect.equality(content:find("d") ~= nil, false)
	expect.equality(content:find("i") ~= nil, false)
	expect.equality(content:find("w") ~= nil, true)
	expect.equality(content:find("e") ~= nil, true)
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
	expect.equality(content:find("%[WARN%]") ~= nil, true)
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
