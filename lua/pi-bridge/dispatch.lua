-- Message routing table for inbound events.
--
-- Design decision: why dispatch.lua instead of an event bus
--
--   This is a plain table lookup — `handlers[msg.type](msg)`. It is not an
--   event emitter: no wildcard matching, no bubbling, no middleware, no `off()`.
--   Handlers are registered once in `setup()` and never change at runtime.
--
--   The indirection exists so that `socket.lua` stays message-agnostic (it
--   doesn't know what `agent_start` means) and `init.lua` doesn't become a
--   switch statement. Adding a new message type is one `register()` call with
--   no existing code changes.

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
