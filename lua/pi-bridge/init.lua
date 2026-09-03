local log = require("pi-bridge.log")
local socket = require("pi-bridge.socket")
local context = require("pi-bridge.context")
local launch = require("pi-bridge.launch")
local dispatch = require("pi-bridge.dispatch")
local ui = require("pi-bridge.ui")
local placeholders = require("pi-bridge.placeholders")
local resolve = require("pi-bridge.resolve")

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

local function ensure_connection(cb)
	if socket.is_connected() then
		cb(true)
		return
	end

	local on_message = function(msg)
		dispatch.dispatch(msg)
	end

	-- Notify once per remote disconnect; never auto-launch from here.
	-- Suppressed during local VimLeavePre cleanup so users do not see a
	-- spurious message when they quit Neovim normally.
	local on_disconnect = function()
		vim.notify(
			"𝜋 pi session disconnected; launch pi to reconnect",
			vim.log.levels.WARN
		)
		log.info("remote disconnect from pi session")
	end

	resolve.find_socket(function(path)
		if path then
			log.info("connecting to " .. path)
			if socket.connect(path, on_message, on_disconnect) then
				cb(true)
				return
			end
			log.warn("connection failed to " .. path)
		end

		if not config.auto_launch then
			vim.notify(
				"𝜋 no active pi instance found. Launch pi manually in this project or a parent directory.",
				vim.log.levels.ERROR
			)
			cb(false)
			return
		end

		-- Use current cwd's socket path as the launch target
		local cwd_path = resolve.socket_path_for_dir(vim.fn.getcwd())
		launch.prompt_launch(config, cwd_path, function(launched)
			if not launched then
				cb(false)
				return
			end

			resolve.clear_cache()
			if socket.connect(cwd_path, on_message, on_disconnect) then
				log.info("connected after launch")
				cb(true)
			else
				log.warn("still cannot connect after launch")
				vim.notify(
					"𝜋 launched pi but socket still unreachable",
					vim.log.levels.ERROR
				)
				cb(false)
			end
		end)
	end)
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

_G._pi_bridge_complete = function(arglead, _cmdline, _cursorpos)
	local names = require("pi-bridge.placeholders").PLACEHOLDERS
	local prefix = arglead:match("@(%w*)$")
	if not prefix then
		local all = {}
		for _, name in ipairs(names) do
			table.insert(all, "@" .. name)
		end
		return all
	end
	local matches = {}
	for _, name in ipairs(names) do
		if name:find(prefix, 1, true) == 1 then
			table.insert(matches, "@" .. name)
		end
	end
	return matches
end

function M.setup(opts)
	if config then return end -- already setup

	local cfg = vim.tbl_deep_extend("force", defaults, opts or {})

	local err = validate_config(cfg)
	if err then
		error("𝜋 " .. err)
	end

	config = cfg

	log.init(
		vim.fn.stdpath("log") .. "/pi-bridge.nvim.log",
		config.log_level
	)
	log.info("setup called")

	if vim.o.autochdir then
		vim.notify(
			"𝜋 autochdir is not supported. Socket matching uses cwd, which autochdir changes per-file. "
				.. "Disable autochdir or use :lcd/:cd for project-level switching.",
			vim.log.levels.WARN
		)
		log.warn("autochdir is enabled — socket matching may be unreliable")
	end

	vim.g.loaded_pi_bridge = true
	register_command()
	register_keymaps(config)

	dispatch.register("agent_start", ui.on_agent_start)
	dispatch.register("agent_end", ui.on_agent_end)

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
		vim.notify("𝜋 setup() not called", vim.log.levels.ERROR)
		return
	end
	opts = opts or {}

	local mode = opts.mode or "normal"
	if vim.fn.mode() == "v" or vim.fn.mode() == "\22" then
		mode = "visual"
	end

	local function send(text)
		if not text or text == "" then return end

		-- Resolve @this, @selection, @diagnostics placeholders
		local resolved = placeholders.resolve(text)

		local ok_ctx, ctx = pcall(context.get, mode)
		if not ok_ctx then
			log.error("failed to gather context: " .. tostring(ctx))
			vim.notify("𝜋 failed to gather context", vim.log.levels.ERROR)
			return
		end

		log.info("prompt: " .. resolved .. " (" .. ctx.mode .. ", " .. ctx.file .. ")")

		ensure_connection(function(ok)
			if not ok then
				vim.notify("𝜋 not connected. Is pi running?", vim.log.levels.ERROR)
				return
			end

			local ok_send, send_err = pcall(socket.send, {
				type = "prompt",
				text = resolved,
				context = ctx,
			})
			if not ok_send then
				log.error("failed to send message: " .. tostring(send_err))
				vim.notify("𝜋 failed to send message", vim.log.levels.ERROR)
			end
		end)
	end

	if opts.text then
		send(opts.text)
	else
		vim.ui.input({
			prompt = "π > ",
			completion = "customlist,v:lua._pi_bridge_complete",
		}, function(input)
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
