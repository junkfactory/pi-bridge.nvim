local MiniTest = require("mini.test")
local expect = MiniTest.expect

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set()

T["health"] = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.start({ "-u", "scripts/minimal_init.lua" })
			child.lua("MiniTest = require('mini.test')")
			child.lua("require('pi-bridge.health')")
		end,
		post_case = function()
			child.stop()
		end,
	},
})

T["health"]["check function exists and is callable"] = function()
	child.lua("require('pi-bridge').setup({ log_level = 'error' })")
	child.lua([[
		_G.health = require('pi-bridge.health')
		_G.has_check = type(_G.health.check) == 'function'
	]])
	local has_check = child.lua("return _G.has_check")
	expect.equality(has_check, true)
end

T["health"]["check runs without error"] = function()
	child.lua("require('pi-bridge').setup({ log_level = 'error' })")
	local ok = child.lua([[
		local ok, err = pcall(require('pi-bridge.health').check)
		return ok
	]])
	expect.equality(ok, true)
end

T["health"]["check detects missing pi binary"] = function()
	child.lua("require('pi-bridge').setup({ log_level = 'error' })")
	child.lua([[
		_G.health_output = {}
		vim.health = {
			start = function(name) table.insert(_G.health_output, { kind = 'start', name = name }) end,
			ok = function(msg) table.insert(_G.health_output, { kind = 'ok', msg = msg }) end,
			warn = function(msg, adv) table.insert(_G.health_output, { kind = 'warn', msg = msg }) end,
			error = function(msg, adv) table.insert(_G.health_output, { kind = 'error', msg = msg }) end,
			info = function(msg) table.insert(_G.health_output, { kind = 'info', msg = msg }) end,
		}
		-- Stub exepath to return empty (pi not found)
		_G._orig_exepath = vim.fn.exepath
		vim.fn.exepath = function(cmd)
			if cmd == 'pi' then return '' end
			return _G._orig_exepath(cmd)
		end
		require('pi-bridge.health').check()
		-- Restore
		vim.fn.exepath = _G._orig_exepath
	]])
	local output = child.lua("return _G.health_output")
	local has_pi_error = false
	for _, entry in ipairs(output) do
		if entry.kind == "error" and entry.msg and entry.msg:find("`pi` binary not found") then
			has_pi_error = true
			break
		end
	end
	expect.equality(has_pi_error, true)
end

T["health"]["check detects autochdir enabled"] = function()
	child.lua([[
		vim.o.autochdir = true
		require('pi-bridge').setup({ log_level = 'error' })
		_G.health_output = {}
		vim.health = {
			start = function(name) end,
			ok = function(msg) table.insert(_G.health_output, { kind = 'ok', msg = msg }) end,
			warn = function(msg, adv) table.insert(_G.health_output, { kind = 'warn', msg = msg }) end,
			error = function(msg, adv) table.insert(_G.health_output, { kind = 'error', msg = msg }) end,
			info = function(msg) table.insert(_G.health_output, { kind = 'info', msg = msg }) end,
		}
		require('pi-bridge.health').check()
	]])
	local output = child.lua("return _G.health_output")
	local has_autochdir_warn = false
	for _, entry in ipairs(output) do
		if entry.kind == "warn" and entry.msg and entry.msg:find("autochdir") then
			has_autochdir_warn = true
			break
		end
	end
	expect.equality(has_autochdir_warn, true)
end

T["health"]["check reports socket status"] = function()
	child.lua("require('pi-bridge').setup({ log_level = 'error' })")
	child.lua([[
		_G.health_output = {}
		vim.health = {
			start = function(name) end,
			ok = function(msg) table.insert(_G.health_output, { kind = 'ok', msg = msg }) end,
			warn = function(msg, adv) table.insert(_G.health_output, { kind = 'warn', msg = msg }) end,
			error = function(msg, adv) table.insert(_G.health_output, { kind = 'error', msg = msg }) end,
			info = function(msg) table.insert(_G.health_output, { kind = 'info', msg = msg }) end,
		}
		require('pi-bridge.health').check()
	]])
	local output = child.lua("return _G.health_output")
	local has_socket_status = false
	for _, entry in ipairs(output) do
		if (entry.kind == "ok" or entry.kind == "warn" or entry.kind == "info") and entry.msg and entry.msg:find("[Ss]ocket") then
			has_socket_status = true
			break
		end
	end
	expect.equality(has_socket_status, true)
end

T["health"]["check detects missing extension"] = function()
	child.lua("require('pi-bridge').setup({ log_level = 'error' })")
	child.lua([[
		_G.health_output = {}
		vim.health = {
			start = function(name) end,
			ok = function(msg) table.insert(_G.health_output, { kind = 'ok', msg = msg }) end,
			warn = function(msg, adv) table.insert(_G.health_output, { kind = 'warn', msg = msg }) end,
			error = function(msg, adv) table.insert(_G.health_output, { kind = 'error', msg = msg }) end,
			info = function(msg) table.insert(_G.health_output, { kind = 'info', msg = msg }) end,
		}
		-- Stub fs_stat to make extension path not exist
		_G._orig_fs_stat = vim.uv.fs_stat
		vim.uv.fs_stat = function(path)
			if path:find('pi%-bridge%.ts') then return nil end
			return _G._orig_fs_stat(path)
		end
		require('pi-bridge.health').check()
		vim.uv.fs_stat = _G._orig_fs_stat
	]])
	local output = child.lua("return _G.health_output")
	local has_ext_warn = false
	for _, entry in ipairs(output) do
		if entry.kind == "warn" and entry.msg and entry.msg:find("extension not found") then
			has_ext_warn = true
			break
		end
	end
	expect.equality(has_ext_warn, true)
end

return T
