local log = require("pi-bridge.log")

local M = {}

local handlers = {}

function M.register(msg_type, fn)
	if type(msg_type) ~= "string" then
		error("dispatch.register: msg_type must be a string")
	end
	if type(fn) ~= "function" then
		error("dispatch.register: fn must be a function")
	end
	handlers[msg_type] = fn
	log.debug("dispatch: registered handler for " .. msg_type)
end

function M.dispatch(msg)
	if type(msg) ~= "table" or not msg.type then
		log.warn("dispatch: invalid message (missing type)")
		return
	end

	local handler = handlers[msg.type]
	if not handler then
		log.debug("dispatch: no handler for message type '" .. msg.type .. "'")
		return
	end

	local ok, err = pcall(handler, msg)
	if not ok then
		log.error("dispatch: handler error for '" .. msg.type .. "': " .. tostring(err))
	end
end

function M.get_handlers()
	return vim.deepcopy(handlers)
end

return M
