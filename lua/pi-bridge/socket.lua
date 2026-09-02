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

function M.connect(path, on_message, timeout)
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
			read_buffer = "",
		}

		pipe:read_start(function(read_err, data)
			if read_err then
				log.error("read error: " .. tostring(read_err))
				M.disconnect()
				return
			end

			if data == nil then
				log.info("connection closed (EOF)")
				M.disconnect()
				return
			end

			state.read_buffer = state.read_buffer .. data

			if #state.read_buffer > MAX_BUFFER then
				log.warn("read buffer overflow, dropping connection")
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
