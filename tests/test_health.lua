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
		-- Stub fs_stat to make all extension paths not exist
		_G._orig_fs_stat = vim.uv.fs_stat
		vim.uv.fs_stat = function(path)
			if path:find('pi%-bridge') and (path:find('%.ts$') or path:find('index%.ts$')) then return nil end
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

T["health"]["check detects git-installed extension"] = function()
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
		-- Stub fs_stat to make git package path exist but legacy path not
		_G._orig_fs_stat = vim.uv.fs_stat
		vim.uv.fs_stat = function(path)
			if path:find('git/github.com/junkfactory/pi%-bridge%.ext') then
				return { type = 'file' }
			end
			if path:find('extensions/pi%-bridge%.ts$') then return nil end
			return _G._orig_fs_stat(path)
		end
		require('pi-bridge.health').check()
		vim.uv.fs_stat = _G._orig_fs_stat
	]])
	local output = child.lua("return _G.health_output")
	local has_ext_ok = false
	for _, entry in ipairs(output) do
		if entry.kind == "ok" and entry.msg and entry.msg:find("pi%-bridge extension found") then
			has_ext_ok = true
			break
		end
	end
	expect.equality(has_ext_ok, true)
end

-- Socket status: persistent Neovim connection
--
-- When socket.is_connected() is true, health must report OK without
-- touching the resolver or probing anything.

T["health"]["reports OK when persistent connection is up"] = function()
	local result = child.lua([[
		require('pi-bridge').setup({ log_level = 'error' })
		_G.health_output = {}
		vim.health = {
			start = function(name) end,
			ok = function(msg) table.insert(_G.health_output, { kind = 'ok', msg = msg }) end,
			warn = function(msg, adv) table.insert(_G.health_output, { kind = 'warn', msg = msg }) end,
			error = function(msg, adv) table.insert(_G.health_output, { kind = 'error', msg = msg }) end,
			info = function(msg) table.insert(_G.health_output, { kind = 'info', msg = msg }) end,
		}
		-- Force socket.is_connected() = true
		local socket = require('pi-bridge.socket')
		socket.is_connected = function() return true end
		require('pi-bridge.health').check()
		-- Check whether the resolver was touched
		local resolve = require('pi-bridge.resolve')
		local resolve_called = false
		local orig_find = resolve.find_socket
		resolve.find_socket = function(cb)
			resolve_called = true
			cb(nil)
		end
		require('pi-bridge.health').check()
		resolve.find_socket = orig_find
		return { output = _G.health_output, resolve_called = resolve_called }
	]])
	local has_connected_ok = false
	for _, entry in ipairs(result.output) do
		if entry.kind == "ok" and entry.msg and entry.msg:find("Socket: connected") then
			has_connected_ok = true
			break
		end
	end
	expect.equality(has_connected_ok, true)
	expect.equality(result.resolve_called, false)
end

-- Socket status: server available, Neovim not connected
--
-- When no persistent connection exists but a real server is listening
-- at the cwd socket path, health reports info (not warn) with advice
-- to run :PiBridge.

T["health"]["reports info when server up but Neovim not connected"] = function()
	local result = child.lua([[
		require('pi-bridge').setup({ log_level = 'error' })
		local helpers = dofile('tests/helpers.lua')
		_G.health_output = {}
		vim.health = {
			start = function(name) end,
			ok = function(msg) table.insert(_G.health_output, { kind = 'ok', msg = msg }) end,
			warn = function(msg, adv) table.insert(_G.health_output, { kind = 'warn', msg = msg }) end,
			error = function(msg, adv) table.insert(_G.health_output, { kind = 'error', msg = msg }) end,
			info = function(msg, adv) table.insert(_G.health_output, { kind = 'info', msg = msg, adv = adv }) end,
		}
		-- Force disconnected
		local socket = require('pi-bridge.socket')
		socket.is_connected = function() return false end

		-- Start a real mock server at the cwd socket path
		local resolve = require('pi-bridge.resolve')
		local cwd = vim.fn.getcwd()
		local cwd_path = resolve.socket_path_for_dir(cwd)
		vim.fn.mkdir(vim.fn.fnamemodify(cwd_path, ':h'), 'p')
		local server = helpers.mock_server(cwd_path)
		_G._test_servers = { server }

		require('pi-bridge.health').check()
		server.stop()

		return _G.health_output
	]])
	local has_available_info = false
	for _, entry in ipairs(result) do
		if entry.kind == "info" and entry.msg and entry.msg:find("Socket available, Neovim not connected") then
			has_available_info = true
			break
		end
	end
	expect.equality(has_available_info, true)
end

-- Socket status: socket file present but unreachable
--
-- A regular file at the socket path (leftover from a crashed pi)
-- should be reported as a warning, not info, with the kernel reason.

T["health"]["warns when socket file present but unreachable"] = function()
	local result = child.lua([[
		require('pi-bridge').setup({ log_level = 'error' })
		_G.health_output = {}
		vim.health = {
			start = function(name) end,
			ok = function(msg) table.insert(_G.health_output, { kind = 'ok', msg = msg }) end,
			warn = function(msg, adv) table.insert(_G.health_output, { kind = 'warn', msg = msg, adv = adv }) end,
			error = function(msg, adv) table.insert(_G.health_output, { kind = 'error', msg = msg }) end,
			info = function(msg) table.insert(_G.health_output, { kind = 'info', msg = msg }) end,
		}
		-- Force disconnected
		local socket = require('pi-bridge.socket')
		socket.is_connected = function() return false end

		-- Place a regular file at the cwd socket path (stale leftover)
		local resolve = require('pi-bridge.resolve')
		local cwd_path = resolve.socket_path_for_dir(vim.fn.getcwd())
		vim.fn.mkdir(vim.fn.fnamemodify(cwd_path, ':h'), 'p')
		local f = io.open(cwd_path, 'w')
		f:write('not a socket')
		f:close()

		require('pi-bridge.health').check()

		os.remove(cwd_path)
		return _G.health_output
	]])
	local has_unreachable_warn = false
	for _, entry in ipairs(result) do
		if entry.kind == "warn" and entry.msg and entry.msg:find("Socket file present but unreachable") then
			has_unreachable_warn = true
			break
		end
	end
	expect.equality(has_unreachable_warn, true)
end

-- Socket status: no socket file at all
--
-- Default state for a fresh cwd with no pi running: info-level
-- "not connected" message.

T["health"]["reports info when no socket file in cwd"] = function()
	local result = child.lua([[
		require('pi-bridge').setup({ log_level = 'error' })
		_G.health_output = {}
		vim.health = {
			start = function(name) end,
			ok = function(msg) table.insert(_G.health_output, { kind = 'ok', msg = msg }) end,
			warn = function(msg, adv) table.insert(_G.health_output, { kind = 'warn', msg = msg }) end,
			error = function(msg, adv) table.insert(_G.health_output, { kind = 'error', msg = msg }) end,
			info = function(msg) table.insert(_G.health_output, { kind = 'info', msg = msg }) end,
		}
		-- Force disconnected
		local socket = require('pi-bridge.socket')
		socket.is_connected = function() return false end

		-- cd to a fresh empty temp dir to guarantee no socket file
		local sub = vim.fn.tempname() .. '/health-empty'
		vim.fn.mkdir(sub, 'p')
		vim.cmd.cd(sub)

		require('pi-bridge.health').check()
		return _G.health_output
	]])
	local has_unavailable_info = false
	for _, entry in ipairs(result) do
		if entry.kind == "info" and entry.msg and entry.msg:find("Socket: not connected") then
			has_unavailable_info = true
			break
		end
	end
	expect.equality(has_unavailable_info, true)
end

return T
