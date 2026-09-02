local H = {}

-- Create a temporary directory for test sockets
function H.tmpdir()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	return dir
end

-- Remove directory recursively
function H.rmdir(dir)
	vim.fn.delete(dir, "rf")
end

-- Create a mock Unix socket server that records received messages
-- Returns { path, messages, send_fn, stop_fn }
function H.mock_server(socket_path)
	local server = vim.uv.new_pipe(false)
	local clients = {}
	local messages = {}

	assert(server:bind(socket_path), "failed to bind mock server to " .. socket_path)

	server:listen(128, function(err)
		assert(not err, "listen error: " .. tostring(err))
		local client = vim.uv.new_pipe(false)
		server:accept(client)

		local buf = ""
		table.insert(clients, client)

		client:read_start(function(read_err, data)
			if read_err or data == nil then
				-- client disconnected
				for i, c in ipairs(clients) do
					if c == client then
						table.remove(clients, i)
						break
					end
				end
				if client and not client:is_closing() then
					client:close()
				end
				return
			end

			buf = buf .. data
			-- split on newlines
			while true do
				local pos = string.find(buf, "\n", 1, true)
				if not pos then break end
				local line = string.sub(buf, 1, pos - 1)
				buf = string.sub(buf, pos + 1)
				if line ~= "" then
					local ok, msg = pcall(vim.json.decode, line)
					if ok then
						table.insert(messages, msg)
					end
				end
			end
		end)
	end)

	return {
		path = socket_path,
		get_messages = function() return messages end,
		send = function(msg)
			local payload = vim.json.encode(msg) .. "\n"
			for _, client in ipairs(clients) do
				if not client:is_closing() then
					client:write(payload)
				end
			end
		end,
		send_raw = function(data)
			for _, client in ipairs(clients) do
				if not client:is_closing() then
					client:write(data)
				end
			end
		end,
		stop = function()
			for _, client in ipairs(clients) do
				if not client and not client:is_closing() then
					client:close()
				end
			end
			if server and not server:is_closing() then
				server:close()
			end
			-- small delay to let close callbacks fire
			vim.uv.run("nowait")
			os.remove(socket_path)
		end,
	}
end

-- Wait for a condition with timeout (ms)
function H.wait_until(fn, timeout, interval)
	timeout = timeout or 2000
	interval = interval or 50
	local elapsed = 0
	while elapsed < timeout do
		if fn() then return true end
		vim.uv.sleep(interval)
		elapsed = elapsed + interval
	end
	return false
end

return H
