--!strict
--[[
	Maid — tracks anything that needs cleaning up and disposes of it in one call.

	Every transient thing in this game (a run's rooms, an enemy's connections, a
	UI screen) is owned by exactly one Maid. When the owner dies, the Maid runs.
	This is how we guarantee a finished run leaves nothing behind in the DataModel.
]]

local Maid = {}
Maid.__index = Maid

export type Task = Instance | RBXScriptConnection | (() -> ()) | { Destroy: (any) -> () } | thread

function Maid.new()
	return setmetatable({ _tasks = {} }, Maid)
end

function Maid:Add<T>(item: T & any): T
	table.insert(self._tasks, item)
	return item
end

--- Adds a task under a name; adding again under the same name cleans the old one first.
function Maid:AddNamed(name: string, item: any): any
	local existing = self._tasks[name]
	if existing then
		Maid._clean(existing)
	end
	self._tasks[name] = item
	return item
end

function Maid:Remove(item: any)
	for index, candidate in self._tasks do
		if candidate == item then
			self._tasks[index] = nil
			return
		end
	end
end

function Maid._clean(item: any)
	local kind = typeof(item)
	if kind == "Instance" then
		item:Destroy()
	elseif kind == "RBXScriptConnection" then
		item:Disconnect()
	elseif kind == "function" then
		item()
	elseif kind == "thread" then
		-- Cancelling the currently running thread would kill the cleanup itself.
		if coroutine.running() ~= item then
			pcall(task.cancel, item)
		end
	elseif kind == "table" and typeof(item.Destroy) == "function" then
		item:Destroy()
	elseif kind == "table" and typeof(item.Disconnect) == "function" then
		item:Disconnect()
	end
end

function Maid:DoCleaning()
	local tasks = self._tasks
	self._tasks = {}

	-- Array part in reverse (children before parents), then the named part.
	for index = #tasks, 1, -1 do
		local item = tasks[index]
		tasks[index] = nil
		local ok, err = pcall(Maid._clean, item)
		if not ok then
			warn("[Maid] cleanup error: " .. tostring(err))
		end
	end
	for key, item in tasks do
		tasks[key] = nil
		local ok, err = pcall(Maid._clean, item)
		if not ok then
			warn("[Maid] cleanup error: " .. tostring(err))
		end
	end
end

Maid.Destroy = Maid.DoCleaning

return Maid
