-- Socket transport over Unix domain sockets.
--
-- Design decisions:
--
--   Why `vim.uv` directly, not `vim.fn.sockconnect`:
--   `vim.fn.sockconnect("unix", path, { rpc = true })` expects Neovim's
--   msgpack-RPC protocol. We need raw NDJSON over a Unix socket.
--   `vim.uv.new_pipe()` gives us a raw stream — no protocol mismatch.
--
--   Why connection-per-session, not connect-per-prompt:
--   Connecting on every prompt adds latency and races with pi's socket
--   lifecycle. A persistent connection detects pi exits (EOF) and reconnects
--   cleanly. The connection is a single libuv pipe — negligible resource cost.

local log = require("pi-bridge.log")

local M = {}

local FRAME_DELIMITER = "\n"
local MAX_BUFFER = 1024 * 1024 -- 1MB

local state = nil -- { pipe, path, on_message, read_buffer }

local function parse_message(raw)
	local ok, msg = pcall(vim.json.decode, raw)
	if not ok then
		log.warn("failed to parse message: " .. raw)
		return nil
	end
	if type(msg) ~= "table" or not msg.type then
		log.warn("message missing type field: " .. raw)
		return nil
	end
	return msg
end

local function process_buffer(buf, on_message)
	local messages = {}
	while true do
		local pos = string.find(buf, FRAME_DELIMITER, 1, true)
		if not pos then break end
		local line = string.sub(buf, 1, pos - 1)
		buf = string.sub(buf, pos + 1)
		if line ~= "" then
			local msg = parse_message(line)
			if msg then
				table.insert(messages, msg)
			end
		end
	end
	for _, msg in ipairs(messages) do
		local ok, err = pcall(on_message, msg)
		if not ok then
			log.error("on_message handler error: " .. tostring(err))
		end
	end
	return buf
end

-- Notify the owner about a remote-side disconnect exactly once per
-- connection loss. Called only from EOF/read-error/overflow paths,
-- never from local disconnect(). Guarded so that multiple close
-- triggers (e.g. read_err followed by EOF) fire the callback once.
local function notify_remote_disconnect()
	if not state then return end
	if state.disconnect_notified then return end
	state.disconnect_notified = true
	if type(state.on_disconnect) == "function" then
		local ok, err = pcall(state.on_disconnect)
		if not ok then
			log.error("on_disconnect handler error: " .. tostring(err))
		end
	end
end

function M.connect(path, on_message, on_disconnect, timeout)
	-- Preserve the original (path, on_message, timeout) signature.
	if type(on_disconnect) == "number" and timeout == nil then
		timeout = on_disconnect
		on_disconnect = nil
	end
	if state then
		log.debug("already connected to " .. state.path)
		return true
	end

	if type(timeout) ~= "number" then
		timeout = 1000
	end

	local pipe = vim.uv.new_pipe(false)
	if not pipe then
		log.error("failed to create pipe")
		return false
	end

	local result = { ok = false, done = false }

	pipe:connect(path, function(err)
		if err then
			log.info("connect failed: " .. tostring(err))
			result.ok = false
			result.done = true
			if not pipe:is_closing() then
				pipe:close()
			end
			return
		end

		log.info("connected to " .. path)

		state = {
			pipe = pipe,
			path = path,
			on_message = on_message,
			on_disconnect = on_disconnect,
			read_buffer = "",
			disconnect_notified = false,
		}

		pipe:read_start(function(read_err, data)
			if read_err then
				log.error("read error: " .. tostring(read_err))
				notify_remote_disconnect()
				M.disconnect()
				return
			end

			if data == nil then
				log.info("connection closed (EOF)")
				notify_remote_disconnect()
				M.disconnect()
				return
			end

			state.read_buffer = state.read_buffer .. data

			if #state.read_buffer > MAX_BUFFER then
				log.warn("read buffer overflow, dropping connection")
				notify_remote_disconnect()
				M.disconnect()
				return
			end

			state.read_buffer = process_buffer(state.read_buffer, state.on_message)
		end)

		result.ok = true
		result.done = true
	end)

	vim.wait(timeout, function()
		return result.done
	end, 20)

	if not result.done then
		log.warn("connect timed out after " .. timeout .. "ms")
		if not pipe:is_closing() then
			pipe:close()
		end
		return false
	end

	return result.ok
end

function M.send(msg)
	if not state then
		log.warn("send called but not connected")
		return false
	end

	local ok, encoded = pcall(vim.json.encode, msg)
	if not ok then
		log.error("failed to encode message")
		return false
	end

	local payload = encoded .. FRAME_DELIMITER
	state.pipe:write(payload, function(err)
		if err then
			log.error("write error: " .. tostring(err))
			M.disconnect()
		end
	end)

	log.debug("sent: " .. encoded)
	return true
end

function M.disconnect()
	if not state then return end

	local path = state.path
	if state.pipe and not state.pipe:is_closing() then
		state.pipe:close()
	end
	state = nil
	log.info("disconnected from " .. path)
end

function M.is_connected()
	return state ~= nil
end

return M
