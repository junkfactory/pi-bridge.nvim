local MiniTest = require("mini.test")
local expect = MiniTest.expect

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set()

T["resolve"] = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.start({ "-u", "scripts/minimal_init.lua" })
			child.lua("MiniTest = require('mini.test')")
		end,
		post_case = function()
			-- cleanup any test servers
			pcall(function()
				child.lua([[
					if _G._test_servers then
						for _, s in ipairs(_G._test_servers) do pcall(function() s.stop() end) end
					end
					-- restore cwd
					if _G._orig_cwd then vim.cmd.cd(_G._orig_cwd) end
				]])
			end)
			child.stop()
		end,
	},
})

-- Helper: set up a directory tree and mock servers in the child.
-- Returns a table with computed socket paths.
local function setup_tree(server_dirs)
	-- server_dirs: list of dir strings where mock servers should listen
	return child.lua(string.format([[
		local helpers = dofile('tests/helpers.lua')
		local resolve = require('pi-bridge.resolve')
		_G._test_servers = {}
		_G._orig_cwd = vim.fn.getcwd()

		local paths = {}
		for _, dir in ipairs({%s}) do
			vim.fn.mkdir(dir, 'p')
			local sp = resolve.socket_path_for_dir(dir)
			vim.fn.mkdir(vim.fn.fnamemodify(sp, ':h'), 'p')
			local server = helpers.mock_server(sp)
			table.insert(_G._test_servers, server)
			paths[dir] = sp
		end
		return paths
	]], table.concat(
		(function()
			local parts = {}
			for _, d in ipairs(server_dirs) do
				table.insert(parts, string.format("%q", d))
			end
			return parts
		end)(),
		", "
	)))
end

-- socket_path_for_dir

T["resolve"]["socket_path_for_dir returns correct format"] = function()
	child.lua("require('pi-bridge').setup({ log_level = 'error' })")
	local result = child.lua([[
		local resolve = require('pi-bridge.resolve')
		local path = resolve.socket_path_for_dir('/tmp/test-project')
		local hex = path:match('([^/]+)%.sock$')
		return { path = path, hex_len = #hex, has_sock_dir = path:find('pi%-bridge/sockets/') ~= nil }
	]])
	expect.equality(result.hex_len, 16)
	expect.equality(result.has_sock_dir, true)
	expect.equality(result.path:find("%.sock$") ~= nil, true)
end

T["resolve"]["socket_path_for_dir is deterministic"] = function()
	child.lua("require('pi-bridge').setup({ log_level = 'error' })")
	local result = child.lua([[
		local resolve = require('pi-bridge.resolve')
		local a = resolve.socket_path_for_dir('/tmp/same-dir')
		local b = resolve.socket_path_for_dir('/tmp/same-dir')
		return a == b
	]])
	expect.equality(result, true)
end

T["resolve"]["socket_path_for_dir differs for different dirs"] = function()
	child.lua("require('pi-bridge').setup({ log_level = 'error' })")
	local result = child.lua([[
		local resolve = require('pi-bridge.resolve')
		local a = resolve.socket_path_for_dir('/tmp/dir-a')
		local b = resolve.socket_path_for_dir('/tmp/dir-b')
		return a ~= b
	]])
	expect.equality(result, true)
end

-- find_socket: socket at cwd

T["resolve"]["find_socket finds socket at cwd"] = function()
	child.lua("require('pi-bridge').setup({ log_level = 'error' })")
	local result = child.lua([[
		local helpers = dofile('tests/helpers.lua')
		local resolve = require('pi-bridge.resolve')
		local cwd = vim.fn.getcwd()
		local path = resolve.socket_path_for_dir(cwd)
		vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
		local server = helpers.mock_server(path)
		_G._test_servers = { server }

		local found = nil
		resolve.find_socket(function(p) found = p end)
		return { found = found, expected = path }
	]])
	expect.equality(result.found, result.expected)
end

-- find_socket: socket at parent
--
-- Note: on macOS, vim.fn.tempname() returns "/var/folders/..." but
-- vim.fn.getcwd() after cd resolves the symlink to "/private/var/...".
-- We must derive the base from the post-cd getcwd() so the socket
-- hash matches what the walk will probe.

T["resolve"]["find_socket finds socket at parent directory"] = function()
	child.lua("require('pi-bridge').setup({ log_level = 'error' })")
	local result = child.lua([[
		local helpers = dofile('tests/helpers.lua')
		local resolve = require('pi-bridge.resolve')

		-- Create a temp project with a subdirectory, then cd in
		local sub_raw = vim.fn.tempname() .. '/src/deep'
		vim.fn.mkdir(sub_raw, 'p')
		vim.cmd.cd(sub_raw)

		-- Derive base from resolved cwd so hash matches the walk
		local base = vim.fn.fnamemodify(vim.fn.getcwd(), ':h:h')

		-- Put the mock server at the base level
		local base_path = resolve.socket_path_for_dir(base)
		vim.fn.mkdir(vim.fn.fnamemodify(base_path, ':h'), 'p')
		local server = helpers.mock_server(base_path)
		_G._test_servers = { server }

		local found = nil
		resolve.find_socket(function(p) found = p end)
		return { found = found, expected = base_path, base = base }
	]])
	expect.equality(result.found, result.expected)
end

-- find_socket: socket at grandparent

T["resolve"]["find_socket finds socket at grandparent directory"] = function()
	child.lua("require('pi-bridge').setup({ log_level = 'error' })")
	local result = child.lua([[
		local helpers = dofile('tests/helpers.lua')
		local resolve = require('pi-bridge.resolve')

		local deep_raw = vim.fn.tempname() .. '/a/b/c'
		vim.fn.mkdir(deep_raw, 'p')
		vim.cmd.cd(deep_raw)

		-- Derive base from resolved cwd: walk up 3 levels
		local base = vim.fn.fnamemodify(
			vim.fn.fnamemodify(
				vim.fn.fnamemodify(vim.fn.getcwd(), ':h'), ':h'), ':h')

		local base_path = resolve.socket_path_for_dir(base)
		vim.fn.mkdir(vim.fn.fnamemodify(base_path, ':h'), 'p')
		local server = helpers.mock_server(base_path)
		_G._test_servers = { server }

		local found = nil
		resolve.find_socket(function(p) found = p end)
		return { found = found, expected = base_path }
	]])
	expect.equality(result.found, result.expected)
end

-- find_socket: no socket anywhere
--
-- Note: across the child->parent RPC boundary, a Lua nil return becomes
-- vim.NIL. We compare against both.

T["resolve"]["find_socket returns nil when no socket exists"] = function()
	child.lua("require('pi-bridge').setup({ log_level = 'error' })")
	local result = child.lua([[
		local resolve = require('pi-bridge.resolve')
		_G._test_servers = {}

		-- cd to a temp dir with no sockets
		local sub = vim.fn.tempname() .. '/sub'
		vim.fn.mkdir(sub, 'p')
		vim.cmd.cd(sub)

		local found = nil
		resolve.find_socket(function(p) found = p end)
		-- Return whether the result is nil/vim.NIL across the boundary
		return found
	]])
	-- nil and vim.NIL both mean "no result" across the RPC boundary
	expect.equality(result == nil or tostring(result) == 'vim.NIL', true)
end

-- find_socket: closest socket wins (cwd over parent)

T["resolve"]["find_socket prefers closest socket (cwd over parent)"] = function()
	child.lua("require('pi-bridge').setup({ log_level = 'error' })")
	local result = child.lua([[
		local helpers = dofile('tests/helpers.lua')
		local resolve = require('pi-bridge.resolve')

		local sub_raw = vim.fn.tempname() .. '/src'
		vim.fn.mkdir(sub_raw, 'p')
		vim.cmd.cd(sub_raw)

		-- Derive base and sub from resolved cwd
		local sub = vim.fn.getcwd()
		local base = vim.fn.fnamemodify(sub, ':h')

		-- Mock server at BOTH base and sub
		local base_path = resolve.socket_path_for_dir(base)
		local sub_path = resolve.socket_path_for_dir(sub)
		vim.fn.mkdir(vim.fn.fnamemodify(base_path, ':h'), 'p')
		vim.fn.mkdir(vim.fn.fnamemodify(sub_path, ':h'), 'p')
		local s1 = helpers.mock_server(base_path)
		local s2 = helpers.mock_server(sub_path)
		_G._test_servers = { s1, s2 }

		local found = nil
		resolve.find_socket(function(p) found = p end)
		return { found = found, expected = sub_path }
	]])
	expect.equality(result.found, result.expected)
end

-- find_socket: caching
--
-- The cache stores the path found by the first call. On the second
-- call, the cache is validated: if the socket is still alive, the
-- cached path is returned without re-walking. We test this by calling
-- find_socket twice without stopping the server.
--
-- Note: the design validates the cache on every call, so a second
-- call after the server is stopped will detect the stale cache and
-- re-walk (covered by the "stale cache" test below).

T["resolve"]["find_socket caches result on second call"] = function()
	child.lua("require('pi-bridge').setup({ log_level = 'error' })")
	local result = child.lua([[
		local helpers = dofile('tests/helpers.lua')
		local resolve = require('pi-bridge.resolve')

		local sub = vim.fn.tempname() .. '/cache-test'
		vim.fn.mkdir(sub, 'p')
		vim.cmd.cd(sub)

		local path = resolve.socket_path_for_dir(vim.fn.getcwd())
		vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
		local server = helpers.mock_server(path)
		_G._test_servers = { server }

		local found1 = nil
		resolve.find_socket(function(p) found1 = p end)

		-- Second call: server still alive, cache should return the
		-- same path without re-walking
		local found2 = nil
		resolve.find_socket(function(p) found2 = p end)

		return {
			first_matches = found1 == path,
			second_matches = found2 == path,
		}
	]])
	expect.equality(result.first_matches, true)
	expect.equality(result.second_matches, true)
end

-- find_socket: clear_cache forces re-walk

T["resolve"]["clear_cache forces re-walk"] = function()
	child.lua("require('pi-bridge').setup({ log_level = 'error' })")
	local result = child.lua([[
		local helpers = dofile('tests/helpers.lua')
		local resolve = require('pi-bridge.resolve')

		local sub = vim.fn.tempname() .. '/clear-cache-test'
		vim.fn.mkdir(sub, 'p')
		vim.cmd.cd(sub)

		local path = resolve.socket_path_for_dir(vim.fn.getcwd())
		vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
		local server = helpers.mock_server(path)
		_G._test_servers = { server }

		-- First call: finds and caches
		local found1 = nil
		resolve.find_socket(function(p) found1 = p end)

		-- Stop server and clear cache
		server.stop()
		resolve.clear_cache()

		-- Second call: re-walks, server is gone, should return nil
		local found2 = nil
		resolve.find_socket(function(p) found2 = p end)

		return {
			first_matches = found1 == path,
			second_is_nil = found2 == nil or tostring(found2) == 'vim.NIL',
		}
	]])
	expect.equality(result.first_matches, true)
	expect.equality(result.second_is_nil, true)
end

-- find_socket: stale cache validated

T["resolve"]["stale cache is detected and re-walked"] = function()
	child.lua("require('pi-bridge').setup({ log_level = 'error' })")
	local result = child.lua([[
		local helpers = dofile('tests/helpers.lua')
		local resolve = require('pi-bridge.resolve')

		local sub = vim.fn.tempname() .. '/stale-cache-test'
		vim.fn.mkdir(sub, 'p')
		vim.cmd.cd(sub)

		local path = resolve.socket_path_for_dir(vim.fn.getcwd())
		vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
		local server = helpers.mock_server(path)
		_G._test_servers = { server }

		-- First call: finds and caches
		local found1 = nil
		resolve.find_socket(function(p) found1 = p end)

		-- Stop server (socket file removed by stop)
		server.stop()

		-- Second call without clear_cache: should detect stale and return nil
		local found2 = nil
		resolve.find_socket(function(p) found2 = p end)

		return {
			first_matches = found1 == path,
			second_is_nil = found2 == nil or tostring(found2) == 'vim.NIL',
		}
	]])
	expect.equality(result.first_matches, true)
	expect.equality(result.second_is_nil, true)
end

return T
