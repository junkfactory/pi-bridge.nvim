local log = require("pi-bridge.log")
local socket = require("pi-bridge.socket")
local context = require("pi-bridge.context")

local M = {}

local config = nil

local defaults = {
	split_direction = "vertical",
	split_size = nil,
	auto_launch = true,
	launch_timeout = 10,
	launch_cmd = { "pi" },
	keymaps = { prompt = "<leader>ai" },
	log_level = "info",
}

local function validate_config(cfg)
	if cfg.split_direction ~= "vertical" and cfg.split_direction ~= "horizontal" then
		return "split_direction must be 'vertical' or 'horizontal'"
	end
	if cfg.split_size ~= nil and (type(cfg.split_size) ~= "number" or cfg.split_size <= 0) then
		return "split_size must be nil or a positive integer"
	end
	if type(cfg.launch_timeout) ~= "number" or cfg.launch_timeout <= 0 then
		return "launch_timeout must be a positive number"
	end
	if type(cfg.launch_cmd) ~= "table" or #cfg.launch_cmd == 0 then
		return "launch_cmd must be a non-empty list of strings"
	end
	for _, v in ipairs(cfg.launch_cmd) do
		if type(v) ~= "string" then
			return "launch_cmd must be a non-empty list of strings"
		end
	end
	local valid_levels = { trace = true, debug = true, info = true, warn = true, error = true }
	if not valid_levels[cfg.log_level] then
		return "log_level must be one of: trace, debug, info, warn, error"
	end
	if cfg.keymaps ~= false then
		if type(cfg.keymaps) ~= "table" then
			return "keymaps must be false or a table"
		end
		if cfg.keymaps.prompt ~= false and type(cfg.keymaps.prompt) ~= "string" then
			return "keymaps.prompt must be a string or false"
		end
	end
	return nil
end

local function socket_path()
	local cwd = vim.fn.getcwd()
	local hash = vim.fn.sha256(cwd)
	return vim.fn.expand("~/.pi/agent/pi-bridge/sockets/") .. hash .. ".sock"
end

local function ensure_connection()
	if socket.is_connected() then return true end

	local path = socket_path()
	log.info("connecting to " .. path)

	local ok = socket.connect(path, function(msg)
		log.info("received: " .. vim.json.encode(msg))
		-- Phase 4: dispatch to handlers
	end)

	if not ok then
		log.warn("connection failed to " .. path)
		return false
	end

	return true
end

local function register_keymaps(cfg)
	if cfg.keymaps == false then return end
	if cfg.keymaps.prompt then
		vim.keymap.set({ "n", "v" }, cfg.keymaps.prompt, function()
			M.prompt()
		end, { desc = "Send prompt to pi" })
	end
end

local function register_command()
	if vim.g.loaded_pi_bridge_cmd then return end
	vim.g.loaded_pi_bridge_cmd = true
	vim.api.nvim_create_user_command("PiBridge", function(args)
		if args.args and args.args ~= "" then
			M.prompt({ text = args.args })
		else
			M.prompt()
		end
	end, { nargs = "?" })
end

function M.setup(opts)
	if config then return end -- already setup

	local cfg = vim.tbl_deep_extend("force", defaults, opts or {})

	local err = validate_config(cfg)
	if err then
		error("pi-bridge: " .. err)
	end

	config = cfg

	log.init(
		vim.fn.stdpath("log") .. "/pi-bridge.nvim.log",
		config.log_level
	)
	log.info("setup called")

	if vim.o.autochdir then
		vim.notify(
			"pi-bridge: autochdir is not supported. Socket matching uses cwd, which autochdir changes per-file. "
				.. "Disable autochdir or use :lcd/:cd for project-level switching.",
			vim.log.levels.WARN
		)
		log.warn("autochdir is enabled — socket matching may be unreliable")
	end

	vim.g.loaded_pi_bridge = true
	register_command()
	register_keymaps(config)

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("pi-bridge", { clear = true }),
		callback = function()
			socket.disconnect()
		end,
	})

	log.info("setup complete")
end

function M.prompt(opts)
	if not config then
		vim.notify("pi-bridge: setup() not called", vim.log.levels.ERROR)
		return
	end
	opts = opts or {}

	local mode = opts.mode or "normal"
	if vim.fn.mode() == "v" or vim.fn.mode() == "\22" then
		mode = "visual"
	end

	local function send(text)
		if not text or text == "" then return end

		local ctx = context.get(mode)
		log.info("prompt: " .. text .. " (" .. ctx.mode .. ", " .. ctx.file .. ")")

		if not ensure_connection() then
			vim.notify("pi-bridge: not connected. Is pi running?", vim.log.levels.ERROR)
			return
		end

		socket.send({
			type = "prompt",
			text = text,
			context = ctx,
		})
	end

	if opts.text then
		send(opts.text)
	else
		vim.ui.input({ prompt = "pi > " }, function(input)
			vim.schedule(function()
				send(input)
			end)
		end)
	end
end

function M.get_config()
	return config
end

return M
