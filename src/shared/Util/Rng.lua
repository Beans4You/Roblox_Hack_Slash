--!strict
--[[
	Rng — a seeded random stream.

	Run generation, boon offers and loot rolls all pull from a per-run stream
	seeded by the run's seed. Two players given the same seed (daily challenge,
	weekly modifier, a bug report) get the identical run, which is the only way
	procedural content stays debuggable.
]]

local Rng = {}
Rng.__index = Rng

export type Class = typeof(setmetatable({}, Rng))

function Rng.new(seed: number?): Class
	return setmetatable({
		_random = Random.new(seed or os.clock() * 1e6 % 2 ^ 31),
		_seed = seed,
	}, Rng)
end

--- Derives an independent stream from this one. Lets a room roll its own contents
--- without perturbing the parent sequence that decides the rest of the route.
function Rng:Fork(salt: number): Class
	return Rng.new(self:Int(1, 2 ^ 30) + salt * 7919)
end

function Rng:Float(min: number?, max: number?): number
	return self._random:NextNumber(min or 0, max or 1)
end

function Rng:Int(min: number, max: number): number
	return self._random:NextInteger(min, max)
end

function Rng:Chance(probability: number): boolean
	return self._random:NextNumber() < probability
end

function Rng:Pick<T>(list: { T }): T?
	if #list == 0 then
		return nil
	end
	return list[self._random:NextInteger(1, #list)]
end

--- Fisher-Yates, in place.
function Rng:Shuffle<T>(list: { T }): { T }
	for index = #list, 2, -1 do
		local swap = self._random:NextInteger(1, index)
		list[index], list[swap] = list[swap], list[index]
	end
	return list
end

--- Picks `count` distinct entries without mutating the source.
function Rng:Sample<T>(list: { T }, count: number): { T }
	local pool = table.clone(list)
	self:Shuffle(pool)
	local result = {}
	for index = 1, math.min(count, #pool) do
		result[index] = pool[index]
	end
	return result
end

--[[
	Weighted pick over `{ {item = x, weight = n}, ... }`, or over any list when a
	`weightOf` accessor is supplied. Entries with weight <= 0 are skipped, which
	is how we mask out content the player has not unlocked yet.
]]
function Rng:Weighted<T>(entries: { T }, weightOf: ((T) -> number)?): T?
	local total = 0
	for _, entry in entries do
		local weight = weightOf and weightOf(entry) or (entry :: any).weight or 1
		if weight > 0 then
			total += weight
		end
	end
	if total <= 0 then
		return nil
	end

	local roll = self._random:NextNumber() * total
	for _, entry in entries do
		local weight = weightOf and weightOf(entry) or (entry :: any).weight or 1
		if weight > 0 then
			roll -= weight
			if roll <= 0 then
				return entry
			end
		end
	end
	return entries[#entries]
end

function Rng:UnitVector(): Vector3
	return self._random:NextUnitVector()
end

--- Random point on a circle in the XZ plane, for spawn scatter.
function Rng:PointInDisc(radius: number): Vector3
	local angle = self._random:NextNumber() * math.pi * 2
	local distance = math.sqrt(self._random:NextNumber()) * radius
	return Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
end

return Rng
