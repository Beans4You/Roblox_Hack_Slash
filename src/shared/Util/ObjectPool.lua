--!strict
--[[
	ObjectPool — recycles Instances instead of churning them.

	Hit sparks, damage numbers and slash trails are created dozens of times a
	second during a fight. Creating and destroying Instances at that rate is one of
	the few things that will reliably tank frame time on a Roblox client, so
	anything that spawns per-hit comes from a pool.
]]

local ObjectPool = {}
ObjectPool.__index = ObjectPool

export type Class = typeof(setmetatable({}, ObjectPool))

--- `factory` builds a fresh item; `reset` returns a used one to a neutral state.
function ObjectPool.new(factory: () -> any, reset: ((any) -> ())?, maxSize: number?): Class
	return setmetatable({
		_factory = factory,
		_reset = reset,
		_idle = {},
		_maxSize = maxSize or 64,
		_created = 0,
	}, ObjectPool)
end

function ObjectPool:Get(): any
	local item = table.remove(self._idle)
	if item then
		return item
	end
	self._created += 1
	return self._factory()
end

function ObjectPool:Release(item: any)
	if item == nil then
		return
	end
	if #self._idle >= self._maxSize then
		-- Pool is saturated; let this one go rather than growing without bound.
		if typeof(item) == "Instance" then
			item:Destroy()
		end
		return
	end
	if self._reset then
		self._reset(item)
	end
	table.insert(self._idle, item)
end

--- Convenience: hand out an item and automatically reclaim it after `seconds`.
function ObjectPool:GetFor(seconds: number, use: (any) -> ()): ()
	local item = self:Get()
	use(item)
	task.delay(seconds, function()
		self:Release(item)
	end)
end

function ObjectPool:PreWarm(count: number)
	for _ = 1, count do
		self._created += 1
		table.insert(self._idle, self._factory())
	end
end

function ObjectPool:Destroy()
	for _, item in self._idle do
		if typeof(item) == "Instance" then
			item:Destroy()
		end
	end
	table.clear(self._idle)
end

return ObjectPool
