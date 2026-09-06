--!strict
--[[
	Signal — a lightweight, allocation-frugal event object.

	Roblox BindableEvents serialise their arguments, which breaks tables-by-reference
	and costs more than we want in the combat hot path. This is the standard
	linked-list signal implementation instead.
]]

local Signal = {}
Signal.__index = Signal

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

local Connection = {}
Connection.__index = Connection

function Connection.new(signal, fn)
	return setmetatable({
		Connected = true,
		_signal = signal,
		_fn = fn,
		_next = nil,
	}, Connection)
end

function Connection:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false

	local signal = self._signal
	if signal._head == self then
		signal._head = self._next
	else
		local prev = signal._head
		while prev and prev._next ~= self do
			prev = prev._next
		end
		if prev then
			prev._next = self._next
		end
	end
	self._signal = nil
	self._fn = nil
end

function Signal.new()
	return setmetatable({ _head = nil }, Signal)
end

function Signal:Connect(fn: (...any) -> ()): Connection
	local connection = Connection.new(self, fn)
	connection._next = self._head
	self._head = connection
	return (connection :: any) :: Connection
end

--- Fires once, then disconnects itself.
function Signal:Once(fn: (...any) -> ()): Connection
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		fn(...)
	end)
	return connection
end

--[[
	Handlers run on fresh coroutines so a single erroring listener cannot stop
	the rest of the chain, and so a yielding listener cannot stall the firer.
	We snapshot `_next` before invoking because a handler is allowed to
	disconnect itself (or its neighbours) mid-dispatch.
]]
function Signal:Fire(...)
	local connection = self._head
	while connection do
		local nextConnection = connection._next
		if connection.Connected then
			task.spawn(connection._fn, ...)
		end
		connection = nextConnection
	end
end

--- Same as Fire but runs handlers inline. Use when ordering with the caller matters.
function Signal:FireSync(...)
	local connection = self._head
	while connection do
		local nextConnection = connection._next
		if connection.Connected then
			local ok, err = pcall(connection._fn, ...)
			if not ok then
				warn("[Signal] handler error: " .. tostring(err))
			end
		end
		connection = nextConnection
	end
end

function Signal:Wait()
	local thread = coroutine.running()
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:DisconnectAll()
	local connection = self._head
	while connection do
		connection.Connected = false
		connection = connection._next
	end
	self._head = nil
end

Signal.Destroy = Signal.DisconnectAll

return Signal
