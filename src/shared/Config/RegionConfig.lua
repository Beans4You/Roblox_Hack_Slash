--!strict
--[[
	RegionConfig — what makes one region feel unlike the others.

	Room *shapes* are shared (see RoomConfig); a region supplies the dressing, the
	enemy pool, the hazard, and the boss. That split is deliberate: it means a new
	region is a table, not a level-design project, and the combat problems the
	player has already learned to solve transfer cleanly while everything they can
	see changes.

	ENEMY POOLS
	Weights, not lists. The Sunken March leans on Marchmen and Bulwarks; the Cinder
	Reach leans on Censers and Cutters. Same eight enemies, different arithmetic,
	very different fights.
]]

local Lore = require(script.Parent.Lore)

export type Region = {
	id: string,
	displayName: string,
	subtitle: string,
	description: string,
	order: number,
	boss: string,
	unlockedByDefault: boolean,
	-- Multiplies enemy health and damage for the whole region.
	difficultyScale: number,
	palette: {
		stone: Color3,
		accent: Color3,
		trim: Color3,
		floor: Color3,
	},
	lighting: {
		ambient: Color3,
		fogColor: Color3,
		fogEnd: number,
		brightness: number,
		clockTime: number,
	},
	-- Ambient hazard applied to the room floor, if any.
	hazard: any?,
	enemyWeights: { [string]: number },
	-- Layouts this region may use, by RoomConfig id. Empty means "all of them".
	roomPool: { string },
	music: string?,
	ambience: string,
	props: { string },
}

local RegionConfig = {}

RegionConfig.Regions = {} :: { [string]: Region }
local G = RegionConfig.Regions

G.SunkenMarch = {
	id = "SunkenMarch",
	displayName = Lore.Regions.SunkenMarch.title,
	subtitle = Lore.Regions.SunkenMarch.subtitle,
	description = Lore.Regions.SunkenMarch.description,
	order = 1,
	boss = "Vhalric",
	unlockedByDefault = true,
	difficultyScale = 1.0,
	palette = {
		stone = Color3.fromRGB(78, 92, 100),
		accent = Color3.fromRGB(120, 220, 210),
		trim = Color3.fromRGB(52, 64, 72),
		floor = Color3.fromRGB(58, 70, 78),
	},
	lighting = {
		ambient = Color3.fromRGB(30, 44, 52),
		fogColor = Color3.fromRGB(28, 46, 54),
		fogEnd = 320,
		brightness = 1.6,
		clockTime = 5.5,
	},
	-- Shin-deep water everywhere: slows you slightly, and it conducts.
	hazard = {
		kind = "ShallowWater",
		depth = 1.2,
		moveSpeedMultiplier = 0.94,
		-- Skein damage in water arcs to a wider radius. A region-wide build hook.
		amplifies = "Skein",
		amplifyBonus = 0.2,
	},
	enemyWeights = {
		Marchman = 100,
		Bulwark = 55,
		Fletcher = 45,
		Cutter = 40,
		Drudge = 25,
		Vesper = 15,
		Censer = 10,
	},
	roomPool = { "Antechamber", "LongHall", "SunkenCourt", "BrokenSpan", "Reliquary", "Overlook", "Shrine", "Wellhouse", "Cache", "Crossing" },
	music = "MarchTheme",
	ambience = "MarchAmbience",
	props = { "Banners", "Rubble", "Braziers", "Railing" },
}

G.CinderReach = {
	id = "CinderReach",
	displayName = Lore.Regions.CinderReach.title,
	subtitle = Lore.Regions.CinderReach.subtitle,
	description = Lore.Regions.CinderReach.description,
	order = 2,
	boss = "Kessara",
	unlockedByDefault = false,
	difficultyScale = 1.35,
	palette = {
		stone = Color3.fromRGB(64, 46, 42),
		accent = Color3.fromRGB(255, 122, 48),
		trim = Color3.fromRGB(40, 28, 26),
		floor = Color3.fromRGB(48, 34, 32),
	},
	lighting = {
		ambient = Color3.fromRGB(46, 24, 18),
		fogColor = Color3.fromRGB(50, 22, 14),
		fogEnd = 260,
		brightness = 2.2,
		clockTime = 18.5,
	},
	hazard = {
		kind = "EmberFloor",
		-- Patches of hot ground that flare on a cycle. Positional pressure without
		-- taking away the whole floor.
		patchCount = 7,
		patchRadius = 10,
		cycleTime = 6,
		warnTime = 1.2,
		damage = 14,
		applies = "Burn",
	},
	enemyWeights = {
		Censer = 100,
		Cutter = 80,
		Marchman = 60,
		Drudge = 50,
		Vesper = 40,
		Fletcher = 30,
		Bulwark = 20,
	},
	roomPool = { "Antechamber", "LongHall", "SunkenCourt", "Gauntlet", "Reliquary", "Overlook", "BrokenSpan", "Shrine", "Wellhouse", "Cache", "Crossing" },
	music = "ReachTheme",
	ambience = "ReachAmbience",
	props = { "Braziers", "Rubble", "Baffles" },
}

G.RimefastSanctum = {
	id = "RimefastSanctum",
	displayName = Lore.Regions.RimefastSanctum.title,
	subtitle = Lore.Regions.RimefastSanctum.subtitle,
	description = Lore.Regions.RimefastSanctum.description,
	order = 3,
	boss = "Anchorite",
	unlockedByDefault = false,
	difficultyScale = 1.7,
	palette = {
		stone = Color3.fromRGB(126, 146, 166),
		accent = Color3.fromRGB(170, 226, 255),
		trim = Color3.fromRGB(92, 112, 134),
		floor = Color3.fromRGB(150, 172, 192),
	},
	lighting = {
		ambient = Color3.fromRGB(56, 70, 86),
		fogColor = Color3.fromRGB(120, 146, 172),
		fogEnd = 420,
		brightness = 2.6,
		clockTime = 8,
	},
	hazard = {
		kind = "SlickFloor",
		-- Low friction. Every dodge overshoots, which retunes every fight you have
		-- already learned.
		friction = 0.25,
		affectsEnemies = true,
	},
	enemyWeights = {
		Bulwark = 100,
		Fletcher = 80,
		Vesper = 70,
		Marchman = 55,
		Drudge = 45,
		Cutter = 35,
		Censer = 15,
	},
	roomPool = { "Antechamber", "LongHall", "SunkenCourt", "Gauntlet", "Overlook", "Reliquary", "BrokenSpan", "Shrine", "Wellhouse", "Cache", "Crossing" },
	music = "SanctumTheme",
	ambience = "SanctumAmbience",
	props = { "Alcoves", "Rubble", "Braziers" },
}

RegionConfig.Order = { "SunkenMarch", "CinderReach", "RimefastSanctum" }

function RegionConfig.Get(regionId: string): Region?
	return G[regionId]
end

function RegionConfig.First(): Region
	return G.SunkenMarch
end

--- Region that comes after `regionId`, or nil at the end of the run of regions.
function RegionConfig.Next(regionId: string): Region?
	local region = G[regionId]
	if not region then
		return nil
	end
	for _, candidate in G do
		if candidate.order == region.order + 1 then
			return candidate
		end
	end
	return nil
end

function RegionConfig.Validate(): { string }
	local problems = {}
	local seenOrders = {}

	for id, region in G do
		if region.id ~= id then
			table.insert(problems, ("%s has mismatched id %q"):format(id, region.id))
		end
		if seenOrders[region.order] then
			table.insert(problems, ("%s shares order %d with %s"):format(id, region.order, seenOrders[region.order]))
		end
		seenOrders[region.order] = id

		if next(region.enemyWeights) == nil then
			table.insert(problems, id .. " has an empty enemy pool")
		end
		if #region.roomPool < 6 then
			table.insert(problems, ("%s has only %d layouts; runs will repeat"):format(id, #region.roomPool))
		end
	end

	return problems
end

return RegionConfig
