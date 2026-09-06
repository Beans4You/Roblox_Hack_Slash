--!strict
--[[
	RunGenerator — decides what the next room could be.

	The route is generated in two stages, and the split is the important part.

	SKELETON, AT RUN START
	Fixed structure only: how many rooms, where the mini-boss sits, which junctions
	offer a third door, and the seed. This is what makes a run reproducible -- two
	players given the same seed get the same shape.

	CANDIDATES, AT EACH JUNCTION
	The two or three doors you are actually offered are rolled when you reach the
	junction, from live run state. A player at 20% health sees more Wells. A player
	who has taken no Graces sees more shrines. A player with a full build sees more
	elites, because that is what they are now shopping for.

	Rolling late is what makes the choice feel like a choice rather than a slot
	machine, and it costs nothing: the same Rng stream, forked per slot, keeps the
	whole thing deterministic anyway.

	DOORS ARE NEVER IDENTICAL
	Two doors offering the same room type is a non-choice. The roller rejects
	duplicates and falls back through the weight table until it finds something
	different, which is why Combat is not simply the most likely thing three times.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local GameConfig = require(Shared.Config.GameConfig)
local RoomConfig = require(Shared.Config.RoomConfig)
local RegionConfig = require(Shared.Config.RegionConfig)
local DamageMath = require(Shared.Combat.DamageMath)
local Rng = require(Shared.Util.Rng)

local RunGenerator = {}

export type RoomPlan = {
	slot: number,
	roomType: string,
	layoutId: string,
	-- Encounter points to spend on enemies. Zero for non-combat rooms.
	budget: number,
	eliteCount: number,
	healthScale: number,
	damageScale: number,
	eventId: string?,
	-- What the door shows before you walk through it.
	preview: {
		name: string,
		description: string,
		icon: string,
		color: Color3,
		rewards: { string },
	},
}

export type Route = {
	seed: number,
	regionId: string,
	roomCount: number,
	miniBossSlot: number,
	wideChoiceSlots: { number },
	-- Rooms actually taken, in order.
	taken: { RoomPlan },
}

--------------------------------------------------------------------------------
-- Skeleton
--------------------------------------------------------------------------------

function RunGenerator.CreateRoute(regionId: string, seed: number?): Route
	local resolvedSeed = seed or math.random(1, 2 ^ 30)

	return {
		seed = resolvedSeed,
		regionId = regionId,
		roomCount = GameConfig.Run.RoomsPerRegion,
		miniBossSlot = GameConfig.Run.MiniBossRoom,
		wideChoiceSlots = table.clone(GameConfig.Run.WideChoiceRooms),
		taken = {},
	}
end

--------------------------------------------------------------------------------
-- Weighting
--------------------------------------------------------------------------------

--[[
	Adjusts base room-type weights by what the run currently needs.

	The adjustments are deliberately blunt and few. Subtle adaptive difficulty is
	hard to tune and easy to feel as the game patronising you; these four rules are
	legible enough that a player can notice them and play around them, which is
	better than a hidden system that quietly smooths every run into the same shape.
]]
local function weightsFor(run: any, slot: number): { [string]: number }
	local weights: { [string]: number } = {}
	for id, roomType in RoomConfig.Types do
		if roomType.weight > 0 then
			weights[id] = roomType.weight
		end
	end

	local healthFraction = run.healthFraction or 1
	local boonCount = run.boonCount or 0

	-- Hurt: more Wells, fewer elites.
	if healthFraction < 0.45 then
		weights.Rest = (weights.Rest or 0) * 2.4
		weights.Elite = (weights.Elite or 0) * 0.45
	elseif healthFraction > 0.9 then
		weights.Rest = (weights.Rest or 0) * 0.5
	end

	-- No build yet: shrines get much likelier, because a run with no Graces at
	-- room five is not a difficulty problem, it is a boring run.
	if boonCount <= 1 and slot > 2 then
		weights.Grace = (weights.Grace or 0) * 2.6
	elseif boonCount >= GameConfig.Boons.MaxActiveBoons - 2 then
		weights.Grace = (weights.Grace or 0) * 0.4
		weights.Elite = (weights.Elite or 0) * 1.4
	end

	-- Elites ramp in over the run rather than showing up in room two.
	local progress = slot / math.max(1, run.route.roomCount)
	weights.Elite = (weights.Elite or 0) * (0.35 + progress * 1.4)

	-- A Forge is only interesting once there is a weapon worth tempering.
	if slot < 3 then
		weights.Forge = 0
	end

	-- Do not offer the same type you just cleared; repetition is the main thing
	-- that makes a procedural run feel thin.
	if run.lastRoomType then
		weights[run.lastRoomType] = (weights[run.lastRoomType] or 0) * 0.35
	end

	return weights
end

--------------------------------------------------------------------------------
-- Planning one room
--------------------------------------------------------------------------------

local function pickLayout(roomType: string, region: any, rng: any): string
	local candidates = {}
	for _, room in RoomConfig.LayoutsFor(roomType) do
		-- Regions restrict which layouts they use, so the Sunken March never
		-- builds the Cinder Reach's Gauntlet.
		if #region.roomPool == 0 or table.find(region.roomPool, room.id) then
			table.insert(candidates, room)
		end
	end
	if #candidates == 0 then
		candidates = RoomConfig.LayoutsFor(roomType)
	end
	local chosen = rng:Pick(candidates)
	return chosen and chosen.id or "Antechamber"
end

local function planRoom(run: any, slot: number, roomType: string, rng: any): RoomPlan
	local region = RegionConfig.Get(run.route.regionId)
	local typeConfig = RoomConfig.Types[roomType]
	local layoutId = pickLayout(roomType, region, rng)
	local layout = RoomConfig.Get(layoutId)

	local healthScale, damageScale = DamageMath.RunScaling(slot, region.difficultyScale)
	local heatScale = 1 + (run.heat or 0) * 0.06
	healthScale *= heatScale
	damageScale *= heatScale

	-- Encounter budget grows with depth and with the layout's own difficulty
	-- rating, so a cramped room at room ten is genuinely worse than an open one.
	local budget = 0
	local eliteCount = 0
	if typeConfig.combatScale > 0 then
		budget = (14 + slot * 5) * typeConfig.combatScale * (0.8 + (layout and layout.difficulty or 3) * 0.08)
		if roomType == "Elite" then
			eliteCount = 1
		elseif roomType == "MiniBoss" then
			eliteCount = 1
		end
	end

	local eventId: string? = nil
	if roomType == "Event" then
		local event = rng:Pick(RoomConfig.Events)
		eventId = event and event.id or nil
	end

	return {
		slot = slot,
		roomType = roomType,
		layoutId = layoutId,
		budget = budget,
		eliteCount = eliteCount,
		healthScale = healthScale,
		damageScale = damageScale,
		eventId = eventId,
		preview = {
			name = typeConfig.name,
			description = typeConfig.preview,
			icon = typeConfig.icon,
			color = typeConfig.color,
			rewards = typeConfig.rewards,
		},
	}
end

--------------------------------------------------------------------------------
-- Candidates
--------------------------------------------------------------------------------

--[[
	Rolls the doors offered at `slot`. Returns a list of RoomPlans, one per door.

	Fixed slots (mini-boss, boss) return a single door: some things are not a
	choice, and pretending otherwise would be worse than being honest about it.
]]
function RunGenerator.RollCandidates(run: any, slot: number): { RoomPlan }
	local route = run.route
	local rng = Rng.new(route.seed + slot * 7919)

	if slot > route.roomCount then
		return { planRoom(run, slot, "Boss", rng) }
	end
	if slot == route.miniBossSlot then
		return { planRoom(run, slot, "MiniBoss", rng) }
	end
	if slot == 1 then
		-- The first room is always a straightforward fight. The player is learning
		-- which buttons do what; a Grace shrine here teaches nothing.
		return { planRoom(run, slot, "Combat", rng) }
	end

	local doorCount = GameConfig.Run.DoorChoices
	if table.find(route.wideChoiceSlots, slot) then
		doorCount += 1
	end

	local weights = weightsFor(run, slot)
	local plans: { RoomPlan } = {}
	local usedTypes: { [string]: boolean } = {}

	for door = 1, doorCount do
		local entries = {}
		for roomType, weight in weights do
			if weight > 0 and not usedTypes[roomType] then
				table.insert(entries, { roomType = roomType, weight = weight })
			end
		end
		table.sort(entries, function(a, b)
			return a.roomType < b.roomType
		end)

		if #entries == 0 then
			break
		end

		local chosen = rng:Weighted(entries, function(entry)
			return entry.weight
		end)
		if not chosen then
			break
		end

		usedTypes[chosen.roomType] = true
		table.insert(plans, planRoom(run, slot, chosen.roomType, rng:Fork(door)))
	end

	-- Guarantee at least one door exists even if the weight table somehow empties.
	if #plans == 0 then
		table.insert(plans, planRoom(run, slot, "Combat", rng))
	end

	return plans
end

--- The Warden's arena, which always follows the last room.
function RunGenerator.BossPlan(run: any): RoomPlan
	local rng = Rng.new(run.route.seed + 104729)
	local plan = planRoom(run, run.route.roomCount + 1, "Boss", rng)
	plan.layoutId = "WardenGate"
	return plan
end

--------------------------------------------------------------------------------

function RunGenerator.Init() end

return RunGenerator
