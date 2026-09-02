local MiniTest = require("mini.test")
local expect = MiniTest.expect

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set()

T["dispatch"] = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.start({ "-u", "scripts/minimal_init.lua" })
			child.lua("MiniTest = require('mini.test')")
			child.lua("require('pi-bridge.dispatch')")
		end,
		post_case = function()
			child.stop()
		end,
	},
})

T["dispatch"]["register and dispatch routes to handler"] = function()
	child.lua([[
		_G.handled = nil
		local dispatch = require('pi-bridge.dispatch')
		dispatch.register('test_type', function(msg)
			_G.handled = msg
		end)
		dispatch.dispatch({ type = 'test_type', data = 'hello' })
	]])
	local handled = child.lua("return _G.handled")
	expect.equality(handled ~= nil, true)
	expect.equality(handled.type, "test_type")
	expect.equality(handled.data, "hello")
end

T["dispatch"]["dispatch ignores unknown message types"] = function()
	child.lua([[
		_G.handled = nil
		local dispatch = require('pi-bridge.dispatch')
		dispatch.register('known', function(msg)
			_G.handled = msg
		end)
		dispatch.dispatch({ type = 'unknown_type', data = 'test' })
	]])
	-- _G.handled is nil, but becomes vim.NIL across child boundary
	local handled = child.lua("return _G.handled == nil")
	expect.equality(handled, true)
end

T["dispatch"]["dispatch handles missing type field"] = function()
	child.lua([[
		_G.handled = nil
		local dispatch = require('pi-bridge.dispatch')
		dispatch.register('test', function(msg)
			_G.handled = msg
		end)
		-- should not error
		dispatch.dispatch({ data = 'no type' })
	]])
	-- _G.handled is nil, but becomes vim.NIL across child boundary
	local handled = child.lua("return _G.handled == nil")
	expect.equality(handled, true)
end

T["dispatch"]["dispatch handles non-table message"] = function()
	child.lua([[
		local dispatch = require('pi-bridge.dispatch')
		-- should not error
		dispatch.dispatch(nil)
		dispatch.dispatch('string')
		dispatch.dispatch(42)
	]])
end

T["dispatch"]["register overwrites previous handler"] = function()
	child.lua([[
		local dispatch = require('pi-bridge.dispatch')
		dispatch.register('overwrite_test', function(msg)
			_G.result = 'first'
		end)
		dispatch.register('overwrite_test', function(msg)
			_G.result = 'second'
		end)
		dispatch.dispatch({ type = 'overwrite_test' })
	]])
	local result = child.lua("return _G.result")
	expect.equality(result, "second")
end

T["dispatch"]["register rejects non-string type"] = function()
	local ok = child.lua([[
		local ok, err = pcall(require('pi-bridge.dispatch').register, 123, function() end)
		return ok
	]])
	expect.equality(ok, false)
end

T["dispatch"]["register rejects non-function handler"] = function()
	local ok = child.lua([[
		local ok, err = pcall(require('pi-bridge.dispatch').register, 'test', 'not a function')
		return ok
	]])
	expect.equality(ok, false)
end

T["dispatch"]["get_handlers returns registered handlers"] = function()
	child.lua([[
		local dispatch = require('pi-bridge.dispatch')
		dispatch.register('alpha', function() end)
		dispatch.register('beta', function() end)
	]])
	-- Functions can't cross the child boundary, check keys via type assertion
	local has_alpha = child.lua("return type(require('pi-bridge.dispatch').get_handlers().alpha) == 'function'")
	local has_beta = child.lua("return type(require('pi-bridge.dispatch').get_handlers().beta) == 'function'")
	expect.equality(has_alpha, true)
	expect.equality(has_beta, true)
end

T["dispatch"]["get_handlers returns copy not reference"] = function()
	child.lua([[
		local dispatch = require('pi-bridge.dispatch')
		dispatch.register('gamma', function() end)
		_G.h1 = dispatch.get_handlers()
		_G.h2 = dispatch.get_handlers()
	]])
	-- Tables with functions can't cross the boundary, compare identity inside child
	local same_ref = child.lua("return rawequal(_G.h1, _G.h2)")
	expect.equality(same_ref, false)
end

T["dispatch"]["handler errors are caught"] = function()
	child.lua([[
		local dispatch = require('pi-bridge.dispatch')
		dispatch.register('error_type', function(msg)
			error('intentional error')
		end)
		-- should not propagate the error
		dispatch.dispatch({ type = 'error_type' })
	]])
end

return T
