local log = require("pi-bridge.log")

local M = {}

-- Module-local state
local pi_split = nil -- { win, buf } tracking the pi terminal, or nil
local pending = nil -- { callbacks = { fn, ... } } in-flight launch, or nil

local POLL_INTERVAL_MS = 200

local function socket_exists(path)
	return vim.uv.fs_stat(path) ~= nil
end

local function build_split_cmd(config)
	local size = config.split_size
	if config.split_direction == "vertical" then
		if size then
			return string.format("vsplit | vertical resize %d", size)
		end
		return "vsplit"
	else
		if size then
			return string.format("split | resize %d", size)
		end
		return "split"
	end
end

local function build_terminal_cmd(launch_cmd)
	return "terminal " .. table.concat(launch_cmd, " ")
end

local function poll_socket(path, timeout_sec, cb)
	local timer = vim.uv.new_timer()
	if not timer then
		log.error("failed to create poll timer")
		vim.schedule(function() cb(false) end)
		return
	end

	local deadline_ms = timeout_sec * 1000
	local elapsed_ms = 0
	local done = false

	local function finish(ok)
		if done then
			return
		end
		done = true
		if not timer:is_closing() then
			timer:stop()
			timer:close()
		end
		cb(ok)
	end

	timer:start(POLL_INTERVAL_MS, POLL_INTERVAL_MS, function()
		if done then
			return
		end
		elapsed_ms = elapsed_ms + POLL_INTERVAL_MS
		if socket_exists(path) then
			log.debug("socket appeared after " .. elapsed_ms .. "ms")
			finish(true)
		elseif elapsed_ms >= deadline_ms then
			log.warn("socket did not appear within " .. timeout_sec .. "s")
			finish(false)
		end
	end)
end

local function open_split_and_launch(config)
	vim.cmd(build_split_cmd(config))
	vim.cmd(build_terminal_cmd(config.launch_cmd))

	pi_split = {
		win = vim.api.nvim_get_current_win(),
		buf = vim.api.nvim_get_current_buf(),
	}
	log.info("opened pi split, launching: " .. table.concat(config.launch_cmd, " "))
end

function M.is_pi_split_valid()
	if not pi_split then
		return false
	end
	if not vim.api.nvim_win_is_valid(pi_split.win) then
		log.debug("pi split window no longer valid")
		pi_split = nil
		return false
	end
	if not vim.api.nvim_buf_is_valid(pi_split.buf) then
		log.debug("pi split buffer no longer valid")
		pi_split = nil
		return false
	end
	return true
end

function M.prompt_launch(config, socket_path, on_ready)
	if pending then
		table.insert(pending.callbacks, on_ready)
		log.debug("launch already in progress, queueing callback")
		return
	end

	pending = { callbacks = { on_ready } }

	local function complete(result)
		local queue = pending.callbacks
		pending = nil
		for _, cb in ipairs(queue) do
			cb(result)
		end
	end

	local function start_poll()
		poll_socket(socket_path, config.launch_timeout, function(socket_ready)
			vim.schedule(function()
				if socket_ready then
					log.info("socket detected after launch")
					complete(true)
				else
					vim.notify(
						"pi-bridge: pi failed to start within " .. config.launch_timeout .. "s",
						vim.log.levels.ERROR
					)
					complete(false)
				end
			end)
		end)
	end

	if M.is_pi_split_valid() then
		log.info("pi split already open, polling for socket")
		start_poll()
		return
	end

	vim.ui.select({ "Yes", "No" }, {
		prompt = "No pi instance found. Launch one?",
	}, function(choice)
		if choice ~= "Yes" then
			log.info("user declined to launch pi")
			vim.schedule(function() complete(false) end)
			return
		end

		vim.schedule(function()
			open_split_and_launch(config)
			start_poll()
		end)
	end)
end

return M
