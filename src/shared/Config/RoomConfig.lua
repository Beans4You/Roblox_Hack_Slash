--!strict
--[[
	RoomConfig — the room modules a run is assembled from.

	Rooms are described, not modelled. Each entry is a list of geometry primitives
	that RoomBuilder instantiates, plus the metadata the generator needs: which
	room types the shape can host, where enemies spawn, where the reward stands,
	and where the doors go.

	WHY GEOMETRY IS SHARED ACROSS REGIONS
	The layouts here are region-agnostic. A room's *shape* is a combat problem --
	"a long hall with cover" plays the same way whether it is flooded or on fire --
	and its *dressing* is what tells you where you are. So the twelve layouts below
	are reused by all three regions with different palettes, hazards and props
	pulled from RegionConfig. That is what makes 12 rooms feel like 36 without
	authoring 36, and it is why a region can be added in an afternoon.

	SPAWN POINTS
	Positions are relative to the room origin, which sits at floor level in the
	centre. The generator picks a subset per encounter; it never uses all of them,
	so the same layout does not play identically twice.

	DOORS
	`entrance` is where the player arrives; `exits` are candidate door positions.
	A room needs at least as many exits as the maximum door count it can host.
]]

export type Geometry = {
	kind: string,
	size: Vector3?,
	offset: Vector3?,
	rotation: number?,
	count: number?,
	radius: number?,
	height: number?,
	thickness: number?,
	material: Enum.Material?,
	tint: number?, -- brightness multiplier applied to the region's palette
	collides: boolean?,
}

export type Room = {
	id: string,
	name: string,
	-- Room types this shape can host. The generator matches against these.
	supports: { string },
	-- Rough footprint, used for placement spacing and for the minimap.
	footprint: Vector3,
	-- 1 (open, forgiving) to 5 (cramped, hostile). Feeds encounter budgeting.
	difficulty: number,
	geometry: { Geometry },
	entrance: Vector3,
	exits: { Vector3 },
	spawnPoints: { Vector3 },
	-- Where a pedestal, shrine or chest goes.
	featureAnchor: Vector3,
	-- Extra anchors for rooms that host more than one feature.
	secondaryAnchors: { Vector3 }?,
	-- Tags the generator reads: "Open", "Cover", "Vertical", "Choke", "Arena".
	tags: { string },
	-- Ambient light offset; caves are darker than halls.
	lightScale: number?,
}

local RoomConfig = {}

--- Shorthand for the common case of a rectangular floor slab.
local function floor(width: number, depth: number): Geometry
	return { kind = "Floor", size = Vector3.new(width, 3, depth), offset = Vector3.new(0, -1.5, 0) }
end

local function walls(width: number, depth: number, height: number): Geometry
	return { kind = "Perimeter", size = Vector3.new(width, height, depth), thickness = 4 }
end

RoomConfig.Rooms = {} :: { [string]: Room }
local R = RoomConfig.Rooms

--------------------------------------------------------------------------------
-- Combat layouts
--------------------------------------------------------------------------------

R.Antechamber = {
	id = "Antechamber",
	name = "Antechamber",
	supports = { "Combat", "Start" },
	footprint = Vector3.new(80, 30, 80),
	difficulty = 1,
	geometry = {
		floor(80, 80),
		walls(80, 80, 30),
		{ kind = "PillarRing", count = 8, radius = 28, height = 26, thickness = 3.5 },
		{ kind = "Rubble", count = 10, radius = 34 },
	},
	entrance = Vector3.new(0, 0, 34),
	exits = { Vector3.new(0, 0, -34), Vector3.new(-34, 0, 0), Vector3.new(34, 0, 0) },
	spawnPoints = {
		Vector3.new(0, 0, -18), Vector3.new(-16, 0, -10), Vector3.new(16, 0, -10),
		Vector3.new(-24, 0, -24), Vector3.new(24, 0, -24), Vector3.new(0, 0, -30),
		Vector3.new(-10, 0, 4), Vector3.new(10, 0, 4),
	},
	featureAnchor = Vector3.new(0, 0, -22),
	tags = { "Open", "Cover" },
}

R.LongHall = {
	id = "LongHall",
	name = "The Long Hall",
	supports = { "Combat", "Elite" },
	footprint = Vector3.new(46, 26, 120),
	difficulty = 3,
	geometry = {
		floor(46, 120),
		walls(46, 120, 26),
		-- Two rows of columns turn the hall into a series of short sight-lines,
		-- which is what makes ranged enemies dangerous here and nowhere else.
		{ kind = "PillarRow", count = 6, offset = Vector3.new(-14, 0, 0), radius = 0, height = 24, thickness = 4 },
		{ kind = "PillarRow", count = 6, offset = Vector3.new(14, 0, 0), radius = 0, height = 24, thickness = 4 },
		{ kind = "Banners", count = 8, offset = Vector3.new(0, 14, 0) },
	},
	entrance = Vector3.new(0, 0, 54),
	exits = { Vector3.new(0, 0, -54) },
	spawnPoints = {
		Vector3.new(0, 0, -40), Vector3.new(-12, 0, -24), Vector3.new(12, 0, -24),
		Vector3.new(0, 0, -8), Vector3.new(-14, 0, 8), Vector3.new(14, 0, 8),
		Vector3.new(0, 0, 24), Vector3.new(-12, 0, -48), Vector3.new(12, 0, -48),
	},
	featureAnchor = Vector3.new(0, 0, -46),
	tags = { "Choke", "Cover" },
}

R.SunkenCourt = {
	id = "SunkenCourt",
	name = "The Sunken Court",
	supports = { "Combat", "Elite", "MiniBoss" },
	footprint = Vector3.new(110, 34, 110),
	difficulty = 2,
	geometry = {
		floor(110, 110),
		walls(110, 110, 34),
		-- A depression in the middle: fighting in it means fighting uphill.
		{ kind = "Depression", radius = 34, height = 5 },
		{ kind = "Steps", count = 4, radius = 34, height = 5 },
		{ kind = "PillarRing", count = 12, radius = 46, height = 30, thickness = 4 },
		{ kind = "Rubble", count = 16, radius = 48 },
	},
	entrance = Vector3.new(0, 0, 50),
	exits = { Vector3.new(0, 0, -50), Vector3.new(-50, 0, 0), Vector3.new(50, 0, 0) },
	spawnPoints = {
		Vector3.new(0, 0, -20), Vector3.new(-20, 0, -20), Vector3.new(20, 0, -20),
		Vector3.new(-28, 0, 4), Vector3.new(28, 0, 4), Vector3.new(0, 0, -38),
		Vector3.new(-38, 0, -30), Vector3.new(38, 0, -30), Vector3.new(0, 0, 12),
		Vector3.new(-14, 0, 26), Vector3.new(14, 0, 26),
	},
	featureAnchor = Vector3.new(0, -5, 0),
	secondaryAnchors = { Vector3.new(-40, 0, -40), Vector3.new(40, 0, -40) },
	tags = { "Arena", "Vertical", "Open" },
	lightScale = 1.1,
}

R.BrokenSpan = {
	id = "BrokenSpan",
	name = "The Broken Span",
	supports = { "Combat" },
	footprint = Vector3.new(60, 40, 100),
	difficulty = 4,
	geometry = {
		-- A bridge with a hole in it. Knockback is lethal here and the enemy roster
		-- is picked accordingly: this room prefers things that shove.
		{ kind = "Floor", size = Vector3.new(60, 3, 34), offset = Vector3.new(0, -1.5, 33) },
		{ kind = "Floor", size = Vector3.new(60, 3, 34), offset = Vector3.new(0, -1.5, -33) },
		{ kind = "Floor", size = Vector3.new(18, 3, 32), offset = Vector3.new(0, -1.5, 0) },
		{ kind = "Void", size = Vector3.new(60, 60, 32), offset = Vector3.new(0, -30, 0) },
		{ kind = "Railing", count = 2, offset = Vector3.new(0, 2, 0) },
		{ kind = "PillarRing", count = 4, radius = 24, height = 34, thickness = 5 },
	},
	entrance = Vector3.new(0, 0, 44),
	exits = { Vector3.new(0, 0, -44) },
	spawnPoints = {
		Vector3.new(0, 0, -34), Vector3.new(-18, 0, -40), Vector3.new(18, 0, -40),
		Vector3.new(0, 0, -14), Vector3.new(0, 0, 14), Vector3.new(-16, 0, 34),
		Vector3.new(16, 0, 34),
	},
	featureAnchor = Vector3.new(0, 0, -40),
	tags = { "Choke", "Hazard" },
	lightScale = 0.85,
}

R.Reliquary = {
	id = "Reliquary",
	name = "The Reliquary",
	supports = { "Combat", "Treasure" },
	footprint = Vector3.new(70, 24, 70),
	difficulty = 2,
	geometry = {
		floor(70, 70),
		walls(70, 70, 24),
		{ kind = "Alcoves", count = 8, radius = 30, height = 12 },
		{ kind = "Platform", size = Vector3.new(20, 2, 20), offset = Vector3.new(0, 1, -14) },
		{ kind = "Braziers", count = 4, radius = 22 },
	},
	entrance = Vector3.new(0, 0, 30),
	exits = { Vector3.new(0, 0, -30), Vector3.new(-30, 0, 0) },
	spawnPoints = {
		Vector3.new(-16, 0, -8), Vector3.new(16, 0, -8), Vector3.new(0, 0, -20),
		Vector3.new(-22, 0, 12), Vector3.new(22, 0, 12), Vector3.new(0, 0, 6),
	},
	featureAnchor = Vector3.new(0, 2, -14),
	secondaryAnchors = { Vector3.new(-24, 0, -24), Vector3.new(24, 0, -24) },
	tags = { "Cover", "Open" },
	lightScale = 1.25,
}

R.Gauntlet = {
	id = "Gauntlet",
	name = "The Gauntlet",
	supports = { "Combat", "Elite" },
	footprint = Vector3.new(36, 24, 140),
	difficulty = 5,
	geometry = {
		floor(36, 140),
		walls(36, 140, 24),
		-- Alternating half-walls. There is no room to circle, so weapons that
		-- depend on spacing have to fight on the back foot.
		{ kind = "Baffles", count = 7, size = Vector3.new(22, 10, 3), offset = Vector3.new(0, 5, 0) },
		{ kind = "Braziers", count = 8, radius = 14 },
	},
	entrance = Vector3.new(0, 0, 64),
	exits = { Vector3.new(0, 0, -64) },
	spawnPoints = {
		Vector3.new(0, 0, -50), Vector3.new(-10, 0, -34), Vector3.new(10, 0, -34),
		Vector3.new(0, 0, -18), Vector3.new(-10, 0, 0), Vector3.new(10, 0, 0),
		Vector3.new(0, 0, 18), Vector3.new(0, 0, 36),
	},
	featureAnchor = Vector3.new(0, 0, -58),
	tags = { "Choke", "Cover", "Hazard" },
	lightScale = 0.7,
}

R.Overlook = {
	id = "Overlook",
	name = "The Overlook",
	supports = { "Combat", "Elite" },
	footprint = Vector3.new(96, 44, 96),
	difficulty = 3,
	geometry = {
		floor(96, 96),
		walls(96, 96, 44),
		-- Raised ledges give ranged enemies real value and give the player somewhere
		-- to launch things off. Vertical rooms exist so Vesper and Quarrel matter.
		{ kind = "Platform", size = Vector3.new(30, 3, 24), offset = Vector3.new(-30, 10, -26) },
		{ kind = "Platform", size = Vector3.new(30, 3, 24), offset = Vector3.new(30, 10, -26) },
		{ kind = "Ramp", size = Vector3.new(12, 10, 26), offset = Vector3.new(-30, 5, 2) },
		{ kind = "Ramp", size = Vector3.new(12, 10, 26), offset = Vector3.new(30, 5, 2), rotation = 180 },
		{ kind = "PillarRing", count = 6, radius = 20, height = 40, thickness = 3 },
	},
	entrance = Vector3.new(0, 0, 42),
	exits = { Vector3.new(0, 0, -42), Vector3.new(-42, 0, -20) },
	spawnPoints = {
		Vector3.new(0, 0, -20), Vector3.new(-30, 10, -26), Vector3.new(30, 10, -26),
		Vector3.new(-18, 0, -6), Vector3.new(18, 0, -6), Vector3.new(0, 0, -36),
		Vector3.new(-34, 0, 20), Vector3.new(34, 0, 20),
	},
	featureAnchor = Vector3.new(0, 0, -32),
	tags = { "Vertical", "Open", "Arena" },
}

--------------------------------------------------------------------------------
-- Non-combat layouts
--------------------------------------------------------------------------------

R.Shrine = {
	id = "Shrine",
	name = "Shrine of the Faded",
	supports = { "Grace", "Event" },
	footprint = Vector3.new(52, 30, 52),
	difficulty = 1,
	geometry = {
		{ kind = "Floor", size = Vector3.new(52, 3, 52), offset = Vector3.new(0, -1.5, 0) },
		walls(52, 52, 30),
		{ kind = "Depression", radius = 16, height = 3 },
		{ kind = "PillarRing", count = 5, radius = 18, height = 22, thickness = 2.5 },
		{ kind = "Braziers", count = 5, radius = 18 },
	},
	entrance = Vector3.new(0, 0, 22),
	exits = { Vector3.new(0, 0, -22) },
	spawnPoints = {},
	featureAnchor = Vector3.new(0, -3, 0),
	tags = { "Safe" },
	lightScale = 1.5,
}

R.Wellhouse = {
	id = "Wellhouse",
	name = "The Wellhouse",
	supports = { "Rest", "Forge" },
	footprint = Vector3.new(44, 24, 44),
	difficulty = 1,
	geometry = {
		floor(44, 44),
		walls(44, 44, 24),
		{ kind = "Platform", size = Vector3.new(10, 4, 10), offset = Vector3.new(0, 2, 0) },
		{ kind = "Braziers", count = 4, radius = 14 },
		{ kind = "Rubble", count = 5, radius = 18 },
	},
	entrance = Vector3.new(0, 0, 18),
	exits = { Vector3.new(0, 0, -18) },
	spawnPoints = {},
	featureAnchor = Vector3.new(0, 4, 0),
	tags = { "Safe" },
	lightScale = 1.35,
}

R.Cache = {
	id = "Cache",
	name = "The Cache",
	supports = { "Treasure", "Event" },
	footprint = Vector3.new(48, 22, 48),
	difficulty = 1,
	geometry = {
		floor(48, 48),
		walls(48, 48, 22),
		{ kind = "Alcoves", count = 6, radius = 20, height = 10 },
		{ kind = "Rubble", count = 12, radius = 20 },
	},
	entrance = Vector3.new(0, 0, 20),
	exits = { Vector3.new(0, 0, -20) },
	-- An "empty" treasure room that occasionally is not: the generator can
	-- upgrade this to an ambush, which is why it has spawn points at all.
	spawnPoints = {
		Vector3.new(-12, 0, -12), Vector3.new(12, 0, -12), Vector3.new(0, 0, -16),
		Vector3.new(-14, 0, 6), Vector3.new(14, 0, 6),
	},
	featureAnchor = Vector3.new(0, 0, -10),
	secondaryAnchors = { Vector3.new(-16, 0, 0), Vector3.new(16, 0, 0) },
	tags = { "Safe", "Cover" },
	lightScale = 0.9,
}

R.Crossing = {
	id = "Crossing",
	name = "The Crossing",
	supports = { "Event" },
	footprint = Vector3.new(64, 26, 64),
	difficulty = 1,
	geometry = {
		floor(64, 64),
		walls(64, 64, 26),
		{ kind = "PillarRing", count = 4, radius = 14, height = 24, thickness = 4 },
		{ kind = "Braziers", count = 3, radius = 20 },
	},
	entrance = Vector3.new(0, 0, 28),
	-- Three exits: this is the room the generator uses when it wants to give a
	-- wide choice.
	exits = { Vector3.new(0, 0, -28), Vector3.new(-28, 0, -12), Vector3.new(28, 0, -12) },
	spawnPoints = {},
	featureAnchor = Vector3.new(0, 0, 0),
	tags = { "Safe", "Junction" },
	lightScale = 1.2,
}

R.WardenGate = {
	id = "WardenGate",
	name = "The Warden's Gate",
	supports = { "Boss" },
	footprint = Vector3.new(180, 60, 180),
	difficulty = 5,
	geometry = {
		{ kind = "Floor", size = Vector3.new(180, 4, 180), offset = Vector3.new(0, -2, 0) },
		{ kind = "Perimeter", size = Vector3.new(180, 60, 180), thickness = 6 },
		{ kind = "PillarRing", count = 6, radius = 62, height = 56, thickness = 7, tint = 0.85 },
		{ kind = "Steps", count = 3, radius = 70, height = 3 },
		{ kind = "Braziers", count = 8, radius = 74 },
	},
	entrance = Vector3.new(0, 0, 76),
	exits = {},
	-- Boss arenas spawn adds at the ring, never on top of the player.
	spawnPoints = {
		Vector3.new(-40, 0, -40), Vector3.new(40, 0, -40), Vector3.new(-40, 0, 40),
		Vector3.new(40, 0, 40), Vector3.new(0, 0, -56), Vector3.new(-56, 0, 0),
		Vector3.new(56, 0, 0),
	},
	featureAnchor = Vector3.new(0, 0, -50),
	tags = { "Arena", "Open" },
	lightScale = 0.95,
}

--------------------------------------------------------------------------------
-- Room types
--
-- What the generator can put *in* a layout. `weight` is the base likelihood; the
-- generator adjusts it by run state (a hurt player sees more Rest, a player with
-- no Graces sees more Grace).
--------------------------------------------------------------------------------

export type RoomType = {
	id: string,
	name: string,
	-- Shown on the door before you commit.
	preview: string,
	icon: string,
	weight: number,
	color: Color3,
	-- Encounter budget multiplier; 0 means no fight.
	combatScale: number,
	rewards: { string },
}

RoomConfig.Types = {
	Combat = {
		id = "Combat",
		name = "COMBAT",
		preview = "Something is waiting.",
		icon = "swords",
		weight = 100,
		color = Color3.fromRGB(228, 226, 220),
		combatScale = 1.0,
		rewards = { "Motes" },
	},
	Grace = {
		id = "Grace",
		name = "GRACE",
		preview = "One of the Faded is here.",
		icon = "flame",
		weight = 62,
		color = Color3.fromRGB(255, 186, 74),
		combatScale = 0.0,
		rewards = { "Boon" },
	},
	Elite = {
		id = "Elite",
		name = "ELITE",
		preview = "Something worse is waiting.",
		icon = "skull",
		weight = 40,
		color = Color3.fromRGB(214, 62, 84),
		combatScale = 1.6,
		rewards = { "Boon", "Motes", "Relic" },
	},
	Treasure = {
		id = "Treasure",
		name = "CACHE",
		preview = "Somebody left something.",
		icon = "chest",
		weight = 34,
		color = Color3.fromRGB(186, 148, 84),
		combatScale = 0.0,
		rewards = { "Motes", "Relic" },
	},
	Rest = {
		id = "Rest",
		name = "WELL",
		preview = "Still water.",
		icon = "drop",
		weight = 30,
		color = Color3.fromRGB(126, 205, 255),
		combatScale = 0.0,
		rewards = { "Heal" },
	},
	Event = {
		id = "Event",
		name = "?",
		preview = "You cannot tell from here.",
		icon = "question",
		weight = 26,
		color = Color3.fromRGB(150, 118, 220),
		combatScale = 0.0,
		rewards = { "Unknown" },
	},
	Forge = {
		id = "Forge",
		name = "FORGE",
		preview = "A working anvil, somehow.",
		icon = "hammer",
		weight = 22,
		color = Color3.fromRGB(255, 122, 48),
		combatScale = 0.0,
		rewards = { "WeaponUpgrade" },
	},
	MiniBoss = {
		id = "MiniBoss",
		name = "TALLIER",
		preview = "One of the Warden's officers.",
		icon = "crown",
		weight = 0, -- placed by the generator at a fixed index, never rolled
		color = Color3.fromRGB(255, 200, 110),
		combatScale = 2.2,
		rewards = { "Boon", "Relic", "Motes" },
	},
	Boss = {
		id = "Boss",
		name = "WARDEN",
		preview = "The end of the region.",
		icon = "warden",
		weight = 0,
		color = Color3.fromRGB(255, 96, 96),
		combatScale = 0.0,
		rewards = { "Sable", "Relic", "Unlock" },
	},
	Start = {
		id = "Start",
		name = "THRESHOLD",
		preview = "",
		icon = "door",
		weight = 0,
		color = Color3.fromRGB(180, 180, 190),
		combatScale = 0.0,
		rewards = {},
	},
}

--------------------------------------------------------------------------------
-- Events
--
-- Short interactions with a real decision in them. Kept text-only and quick;
-- the brief is explicit about not interrupting the pace with cutscenes.
--------------------------------------------------------------------------------

RoomConfig.Events = {
	{
		id = "TheDebt",
		title = "A HAND FROM THE WATER",
		body = "Something is holding a fistful of Motes just under the surface. It does not "
			.. "let go when you pull.",
		choices = {
			{ label = "Take them", outcome = { motes = 120, damagePercent = 0.15 } },
			{ label = "Leave it", outcome = { motes = 0, heal = 10 } },
		},
	},
	{
		id = "TheOffer",
		title = "AN UNATTENDED SHRINE",
		body = "Somebody has already been here and taken the Grace. The plinth is still warm.",
		choices = {
			{ label = "Break the plinth", outcome = { boonRarityUpgrade = 1, maxHealthPercent = -0.08 } },
			{ label = "Leave it standing", outcome = { motes = 45 } },
		},
	},
	{
		id = "TheWager",
		title = "TWO DOORS, ONE LIT",
		body = "One of them has something good in it. The other has a Tallier. There is no "
			.. "way to tell which from here.",
		choices = {
			{ label = "The lit door", outcome = { forceRoomType = "Elite", rewardMultiplier = 2 } },
			{ label = "The dark door", outcome = { forceRoomType = "Treasure" } },
		},
	},
	{
		id = "TheCount",
		title = "A TALLY ON THE WALL",
		body = "Scratches, in groups of five. Hundreds of them. The last group is unfinished.",
		choices = {
			{ label = "Add a mark", outcome = { sable = 25, heatIncrease = 1 } },
			{ label = "Scratch them all out", outcome = { heal = 35, loreUnlock = "VhalricTally" } },
		},
	},
	{
		id = "TheTrade",
		title = "A SMITH'S ABANDONED KIT",
		body = "Half-finished work, still clamped. You could take the temper off it, but the "
			.. "edge would go.",
		choices = {
			{ label = "Take the temper", outcome = { damageBonus = 0.15, maxHealthPercent = -0.12 } },
			{ label = "Take the plate", outcome = { maxHealthPercent = 0.15, damageBonus = -0.08 } },
			{ label = "Take neither", outcome = { motes = 60 } },
		},
	},
}

--------------------------------------------------------------------------------
-- Accessors
--------------------------------------------------------------------------------

function RoomConfig.Get(roomId: string): Room?
	return R[roomId]
end

--- Every layout that can host `roomType`.
function RoomConfig.LayoutsFor(roomType: string): { Room }
	local result = {}
	for _, room in R do
		if table.find(room.supports, roomType) then
			table.insert(result, room)
		end
	end
	table.sort(result, function(a, b)
		return a.id < b.id
	end)
	return result
end

function RoomConfig.GetEvent(eventId: string)
	for _, event in RoomConfig.Events do
		if event.id == eventId then
			return event
		end
	end
	return nil
end

function RoomConfig.Validate(): { string }
	local problems = {}

	for id, room in R do
		if room.id ~= id then
			table.insert(problems, ("%s has mismatched id %q"):format(id, room.id))
		end
		if #room.supports == 0 then
			table.insert(problems, id .. " supports no room types")
		end
		for _, supported in room.supports do
			if not RoomConfig.Types[supported] then
				table.insert(problems, ("%s supports unknown room type %q"):format(id, supported))
			end
		end
		-- Every layout except the boss arena has to lead somewhere.
		if #room.exits == 0 and not table.find(room.supports, "Boss") then
			table.insert(problems, id .. " has no exits")
		end
		if table.find(room.supports, "Combat") and #room.spawnPoints < 4 then
			table.insert(problems, ("%s hosts combat but has only %d spawn points"):format(id, #room.spawnPoints))
		end
	end

	for roomType in RoomConfig.Types do
		if #RoomConfig.LayoutsFor(roomType) == 0 then
			table.insert(problems, ("no layout can host room type %q"):format(roomType))
		end
	end

	return problems
end

return RoomConfig
