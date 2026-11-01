local MiniTest = require("mini.test")
local expect = MiniTest.expect

local child = MiniTest.new_child_neovim()
local helpers = dofile("tests/helpers.lua")

local T = MiniTest.new_set()

-- Filesystem fixture shared by the path-branch cases. Built in the parent
-- process under a temp directory (helpers.tmpdir -> vim.fn.tempname) so the
-- child neovim sees it as a real directory on disk. No cleanup obligation
-- beyond the OS temp dir.
local fixture

local function build_fixture()
	local dir = helpers.tmpdir()
	vim.fn.mkdir(dir .. "/sub", "p")
	vim.fn.writefile({ "readme" }, dir .. "/readme")
	vim.fn.writefile({ "one" }, dir .. "/sub/one.txt")
	vim.fn.writefile({ "two" }, dir .. "/sub/two.txt")
	-- Resolve symlinks (/tmp -> /private/tmp on macOS): neovim reports
	-- buffer names with the resolved path, and the buffer provider matches
	-- leads by literal prefix.
	return vim.uv.fs_realpath(dir) or dir
end

T["complete"] = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.start({ "-u", "scripts/minimal_init.lua" })
			fixture = build_fixture()
		end,
		post_case = function()
			child.stop()
		end,
	},
})

-- Placeholder branch: expectations are derived from the live PLACEHOLDERS
-- list so the suite does not go stale when resolvers are added or removed.

T["complete"]["placeholder: bare @ returns every @name"] = function()
	local r = child.lua([[
		local names = require('pi-bridge.placeholders').PLACEHOLDERS
		local expected = {}
		for _, name in ipairs(names) do
			table.insert(expected, '@' .. name)
		end
		return { got = require('pi-bridge.complete').complete('@'), expected = expected }
	]])
	expect.equality(#r.expected > 0, true)
	expect.equality(r.got, r.expected)
end

T["complete"]["placeholder: @b returns only @names starting with b"] = function()
	local r = child.lua([[
		local names = require('pi-bridge.placeholders').PLACEHOLDERS
		local expected = {}
		for _, name in ipairs(names) do
			if name:sub(1, 1) == 'b' then
				table.insert(expected, '@' .. name)
			end
		end
		local got = require('pi-bridge.complete').complete('@b')
		local all_prefixed = true
		for _, candidate in ipairs(got) do
			if candidate:sub(1, 2) ~= '@b' then all_prefixed = false end
		end
		return { got = got, expected = expected, all_prefixed = all_prefixed }
	]])
	expect.equality(#r.expected > 0, true)
	expect.equality(r.all_prefixed, true)
	expect.equality(r.got, r.expected)
end

T["complete"]["placeholder: unmatched @token returns nothing"] = function()
	local got = child.lua([[return require('pi-bridge.complete').complete('@zzz_no_such')]])
	expect.equality(got, {})
end

-- Path branch. Plain prose (and the empty lead) must never complete; only
-- path-like leads reach the filesystem/buffer providers.

T["complete"]["path: empty lead and plain words return nothing"] = function()
	local r = child.lua([[
		local complete = require('pi-bridge.complete').complete
		return { empty = complete(''), word = complete('readme') }
	]])
	expect.equality(r.empty, {})
	expect.equality(r.word, {})
end

T["complete"]["path: directory lead lists the fixture entries"] = function()
	local candidates = child.lua(string.format([[
		return require('pi-bridge.complete').complete(%q)
	]], fixture .. "/"))

	local seen = {}
	for _, candidate in ipairs(candidates) do
		seen[candidate] = (seen[candidate] or 0) + 1
	end
	expect.equality(seen[fixture .. "/readme"], 1)
	expect.equality(seen[fixture .. "/sub/"], 1)

	local has_dir = false
	for _, candidate in ipairs(candidates) do
		if candidate:sub(-1) == "/" then has_dir = true end
	end
	expect.equality(has_dir, true)
end

T["complete"]["path: ~/ lead returns candidates"] = function()
	local count = child.lua([[return #require('pi-bridge.complete').complete('~/')]])
	expect.equality(count > 0, true)
end

T["complete"]["path: listed buffers are offered as absolute paths"] = function()
	local one = fixture .. "/sub/one.txt"
	local two = fixture .. "/sub/two.txt"

	local candidates = child.lua(string.format([[
		vim.cmd('edit ' .. vim.fn.fnameescape(%q))
		vim.cmd('edit ' .. vim.fn.fnameescape(%q))
		return require('pi-bridge.complete').complete(%q)
	]], one, two, fixture .. "/sub/"))

	local seen = {}
	for _, candidate in ipairs(candidates) do
		seen[candidate] = (seen[candidate] or 0) + 1
	end
	expect.equality(seen[one], 1)
	expect.equality(seen[two], 1)
end

T["complete"]["path: buffer branch works without filesystem matches"] = function()
	-- Stub getcompletion away so only the listed-buffer provider can answer.
	local one = fixture .. "/sub/one.txt"
	local candidates = child.lua(string.format([[
		vim.cmd('edit ' .. vim.fn.fnameescape(%q))
		vim.fn.getcompletion = function() return {} end
		return require('pi-bridge.complete').complete(%q)
	]], one, fixture .. "/sub/"))

	expect.equality(candidates, { one })
end

T["complete"]["path: candidate reachable both ways appears exactly once"] = function()
	local one = fixture .. "/sub/one.txt"
	local r = child.lua(string.format([[
		vim.cmd('edit ' .. vim.fn.fnameescape(%q))
		local lead = %q
		local out = require('pi-bridge.complete').complete(lead)
		local count = 0
		for _, candidate in ipairs(out) do
			if candidate == %q then count = count + 1 end
		end
		return { count = count, fs_matches = #vim.fn.getcompletion(lead, 'file') }
	]], one, fixture .. "/sub/", one))

	-- Precondition: the file really is in the getcompletion list, so the
	-- dedupe path is actually exercised.
	expect.equality(r.fs_matches > 0, true)
	expect.equality(r.count, 1)
end

-- Wiring: the global dispatcher used by `completion = "customlist,v:lua.…"`
-- must exist and still serve @placeholders.

T["complete"]["wiring: _G._pi_bridge_complete serves @placeholders"] = function()
	local r = child.lua([[
		require('pi-bridge')
		local names = require('pi-bridge.placeholders').PLACEHOLDERS
		local expected = {}
		for _, name in ipairs(names) do
			table.insert(expected, '@' .. name)
		end
		return {
			kind = type(_G._pi_bridge_complete),
			got = _G._pi_bridge_complete('@', 'PiBridge ', 1),
			expected = expected,
		}
	]])
	expect.equality(r.kind, "function")
	expect.equality(#r.expected > 0, true)
	expect.equality(r.got, r.expected)
end

-- 'completefunc' adapter: token_start is pure Lua, completefunc needs a
-- buffer so findstart==1 can read line and cursor from the current window.

T["token_start"] = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.start({ "-u", "scripts/minimal_init.lua" })
		end,
		post_case = function()
			child.stop()
		end,
	},
})

T["token_start"]["nil or blank heads return nil"] = function()
	-- tostring, because RPC turns nils into nothing
	local nil_cases = child.lua([[local m = require('pi-bridge.complete')
		return { tostring(m.token_start(nil, 1)), tostring(m.token_start('@th', nil)), tostring(m.token_start(' ', 1)) }]])
	expect.equality(nil_cases, { 'nil', 'nil', 'nil' })
end

T["token_start"]["@ and @th start at column 0; mid-token cursor completes the prefix"] = function()
	local r = child.lua([[local m = require('pi-bridge.complete')
		return { at = m.token_start('@', 1), th = m.token_start('@th', 3), mid = m.token_start('@th', 2) }]])
	expect.equality(r, { at = 0, th = 0, mid = 0 })
end

T["token_start"]["token after prose and ./path lead report the right start"] = function()
	local r = child.lua([[local m = require('pi-bridge.complete')
		return { prose = m.token_start('see @th', 7), path = m.token_start('./lib/x', 7) }]])
	expect.equality(r, { prose = 4, path = 0 })
end

T["token_start"]["plain words are not completable"] = function()
	local got = child.lua([[return tostring(require('pi-bridge.complete')['token_start']('plain words', 11))]])
	expect.equality(got, 'nil')
end

T["completefunc"] = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.start({ "-u", "scripts/minimal_init.lua" })
		end,
		post_case = function()
			child.stop()
		end,
	},
})

T["completefunc"]["findstart==1 returns the byte column in a scratch buffer"] = function()
	local start = child.lua([[vim.cmd('new')
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'see @th' })
		vim.api.nvim_win_set_cursor(0, { 1, 7 })
		return require('pi-bridge.complete').completefunc(1, '')]])
	expect.equality(start, 4)
end

T["completefunc"]["findstart==1 returns -3 for plain prose"] = function()
	local code = child.lua([[vim.cmd('new')
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'plain words' })
		vim.api.nvim_win_set_cursor(0, { 1, 11 })
		return require('pi-bridge.complete').completefunc(1, '')]])
	expect.equality(code, -3)
end

T["completefunc"]["findstart==0 returns the placeholder matches"] = function()
	local r = child.lua([[local names = require('pi-bridge.placeholders').PLACEHOLDERS
		local got = require('pi-bridge.complete').completefunc(0, '@th')
		local all_prefixed = #got > 0
		for _, c in ipairs(got) do
			if c:sub(1, 3) ~= '@th' then all_prefixed = false end
		end
		return { got = got, all_prefixed = all_prefixed }]])
	expect.equality(#r.got > 0, true)
	expect.equality(r.all_prefixed, true)
end

return T
