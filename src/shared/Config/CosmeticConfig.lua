--!strict
--[[
	CosmeticConfig — what you wear, and what you had to do to get it.

	The brief's rule, kept literally: the best-looking things are earned by playing
	well, not by playing long, and never by paying. Every entry below names the
	specific act that unlocks it. If a cosmetic's `source` could be satisfied by
	simply grinding, it is the wrong cosmetic.

	Cosmetics are built from primitives at runtime and welded to the character, the
	same way weapons and enemies are, so a new one is a table plus a few parts.
]]

export type Cosmetic = {
	id: string,
	name: string,
	slot: string,
	rarity: "Common" | "Rare" | "Epic" | "Legendary",
	description: string,
	source: string,
	-- How the game knows you earned it. Checked by ProgressionService.
	unlock: any,
	-- Geometry, in the same shape PartFactory understands. Attached to `slot`'s joint.
	build: any,
	hidden: boolean?,
}

local CosmeticConfig = {}

--- Slots, and the rig attachment each hangs from.
CosmeticConfig.Slots = {
	Head = { joint = "Head", label = "HELM" },
	Face = { joint = "Head", label = "MASK" },
	Back = { joint = "Torso", label = "CLOAK" },
	Shoulders = { joint = "Torso", label = "PAULDRONS" },
	Hands = { joint = "RightArm", label = "GLOVES" },
	Feet = { joint = "RightLeg", label = "BOOTS" },
	Aura = { joint = "Torso", label = "AURA" },
	Trail = { joint = "Torso", label = "TRAIL" },
	WeaponSkin = { joint = "Weapon", label = "WEAPON SKIN" },
	Trophy = { joint = "Torso", label = "TROPHY" },
}

local STONE = Color3.fromRGB(150, 154, 164)
local GOLD = Color3.fromRGB(255, 200, 110)
local EMBER = Color3.fromRGB(255, 122, 48)
local RIME = Color3.fromRGB(170, 226, 255)
local HUSH = Color3.fromRGB(150, 118, 220)

CosmeticConfig.Cosmetics = {} :: { [string]: Cosmetic }
local C = CosmeticConfig.Cosmetics

--------------------------------------------------------------------------------
-- Starting kit. Free, plain, and deliberately unimpressive.
--------------------------------------------------------------------------------

C.Wanderer_Hood = {
	id = "Wanderer_Hood",
	name = "TRAVELLER'S HOOD",
	slot = "Head",
	rarity = "Common",
	description = "What you arrived in.",
	source = "Owned from the start.",
	unlock = { kind = "Default" },
	build = {
		{ name = "Hood", size = Vector3.new(1.9, 1.1, 1.9), offset = Vector3.new(0, 0.5, 0), color = Color3.fromRGB(58, 52, 48), material = Enum.Material.Fabric },
		{ name = "HoodBack", size = Vector3.new(1.5, 1.2, 0.5), offset = Vector3.new(0, 0.2, 0.9), color = Color3.fromRGB(48, 42, 40), material = Enum.Material.Fabric },
	},
}

C.Wanderer_Cloak = {
	id = "Wanderer_Cloak",
	name = "TRAVELLER'S CLOAK",
	slot = "Back",
	rarity = "Common",
	description = "Also what you arrived in.",
	source = "Owned from the start.",
	unlock = { kind = "Default" },
	build = {
		{ name = "Cloak", size = Vector3.new(2.2, 3.0, 0.2), offset = Vector3.new(0, -0.4, 0.65), color = Color3.fromRGB(52, 46, 44), material = Enum.Material.Fabric },
	},
}

--------------------------------------------------------------------------------
-- Boss trophies. One per Warden, earned the hard way, not by killing it.
--------------------------------------------------------------------------------

C.Trophy_Vhalric = {
	id = "Trophy_Vhalric",
	name = "THE UNBALANCED COLUMN",
	slot = "Trophy",
	rarity = "Epic",
	description = "Vhalric's tally-plate, still counting, still wrong.",
	source = "Defeat Vhalric without dying during the fight.",
	unlock = { kind = "BossFlawless", boss = "Vhalric" },
	build = {
		{ name = "Plate", size = Vector3.new(1.1, 1.4, 0.16), offset = Vector3.new(-1.3, 0.2, 0.5), color = GOLD, material = Enum.Material.Metal },
		{ name = "Chain", size = Vector3.new(0.1, 1.2, 0.1), offset = Vector3.new(-1.3, 1.1, 0.5), color = STONE, material = Enum.Material.Metal },
	},
}

C.Trophy_Kessara = {
	id = "Trophy_Kessara",
	name = "THE BANKED COAL",
	slot = "Trophy",
	rarity = "Epic",
	description = "It has not gone out. It is not going to.",
	source = "Defeat Kessara without stepping in fire.",
	unlock = { kind = "BossChallenge", boss = "Kessara", challenge = "NoFireDamage" },
	build = {
		{ name = "Coal", size = Vector3.new(0.6, 0.6, 0.6), offset = Vector3.new(1.3, 0.3, 0.5), color = EMBER, material = Enum.Material.Neon },
		{ name = "Cage", size = Vector3.new(0.9, 0.9, 0.9), offset = Vector3.new(1.3, 0.3, 0.5), color = Color3.fromRGB(40, 32, 30), material = Enum.Material.Metal, transparency = 0.4 },
	},
}

C.Trophy_Anchorite = {
	id = "Trophy_Anchorite",
	name = "THE HELD BREATH",
	slot = "Trophy",
	rarity = "Legendary",
	description = "A sliver of the Sanctum's ice. It has not melted and it will not.",
	source = "Defeat the Anchorite without using a single Grace.",
	unlock = { kind = "BossChallenge", boss = "Anchorite", challenge = "NoBoons" },
	build = {
		{ name = "Shard", size = Vector3.new(0.35, 1.6, 0.35), offset = Vector3.new(0, 1.2, 0.7), color = RIME, material = Enum.Material.Ice, transparency = 0.25 },
	},
}

--------------------------------------------------------------------------------
-- Mastery auras. One per weapon at level 30. Visible in the hub; that is the point.
--------------------------------------------------------------------------------

local function auraCosmetic(id: string, weapon: string, name: string, color: Color3): Cosmetic
	return {
		id = id,
		name = name,
		slot = "Aura",
		rarity = "Legendary",
		description = ("Only granted at %s mastery 30."):format(weapon),
		source = ("Reach mastery 30 with %s."):format(weapon),
		unlock = { kind = "Mastery", weapon = weapon, level = 30 },
		build = {
			{ name = "AuraRing", size = Vector3.new(5.5, 0.12, 5.5), offset = Vector3.new(0, -2.6, 0), color = color, material = Enum.Material.Neon, transparency = 0.4, spin = 0.6 },
			{ name = "AuraGlow", size = Vector3.new(3.4, 3.4, 3.4), offset = Vector3.new(0, 0, 0), color = color, material = Enum.Material.Neon, transparency = 0.9, light = 2 },
		},
	}
end

C.Aura_Vigil = auraCosmetic("Aura_Vigil", "Vigil", "THE KEPT WATCH", GOLD)
C.Aura_Grudge = auraCosmetic("Aura_Grudge", "Grudge", "THE SETTLED WEIGHT", EMBER)
C.Aura_Quarrel = auraCosmetic("Aura_Quarrel", "Quarrel", "THE OPEN ARGUMENT", HUSH)
C.Aura_Thresh = auraCosmetic("Aura_Thresh", "Thresh", "THE LONG REACH", RIME)

--------------------------------------------------------------------------------
-- Set completions.
--------------------------------------------------------------------------------

C.WardensMantle = {
	id = "WardensMantle",
	name = "THE WARDEN'S MANTLE",
	slot = "Shoulders",
	rarity = "Legendary",
	description = "Cut from three different uniforms and stitched together badly.",
	source = "Complete the Warden's Due collection.",
	unlock = { kind = "RelicSet", set = "WardensDue" },
	build = {
		{ name = "PauldronL", size = Vector3.new(1.6, 0.8, 1.6), offset = Vector3.new(-1.5, 0.9, 0), color = Color3.fromRGB(52, 66, 74), material = Enum.Material.Metal },
		{ name = "PauldronR", size = Vector3.new(1.6, 0.8, 1.6), offset = Vector3.new(1.5, 0.9, 0), color = Color3.fromRGB(64, 46, 42), material = Enum.Material.Metal },
		{ name = "Collar", size = Vector3.new(2.3, 0.5, 1.4), offset = Vector3.new(0, 1.2, 0.2), color = Color3.fromRGB(126, 146, 166), material = Enum.Material.Metal },
	},
}

C.KeepersLantern = {
	id = "KeepersLantern",
	name = "MIREN'S LANTERN",
	slot = "Back",
	rarity = "Epic",
	description = "She will want it back. She will not ask.",
	source = "Complete the Small Things collection.",
	unlock = { kind = "RelicSet", set = "SmallThings" },
	build = {
		{ name = "Pole", size = Vector3.new(0.14, 3.2, 0.14), offset = Vector3.new(-0.9, 0.4, 0.8), color = Color3.fromRGB(58, 48, 42), material = Enum.Material.Wood },
		{ name = "Lamp", size = Vector3.new(0.7, 0.9, 0.7), offset = Vector3.new(-0.9, 1.9, 0.8), color = GOLD, material = Enum.Material.Neon, light = 3 },
	},
}

C.EmberholdSigil = {
	id = "EmberholdSigil",
	name = "THE EMBERHOLD SIGIL",
	slot = "Face",
	rarity = "Epic",
	description = "Worn by people who intend to come back.",
	source = "Complete the Trade collection.",
	unlock = { kind = "RelicSet", set = "Trade" },
	build = {
		{ name = "Mask", size = Vector3.new(1.7, 0.9, 0.3), offset = Vector3.new(0, 0.1, -0.85), color = Color3.fromRGB(44, 40, 38), material = Enum.Material.Metal },
		{ name = "SigilMark", size = Vector3.new(0.5, 0.5, 0.1), offset = Vector3.new(0, 0.1, -1.0), color = EMBER, material = Enum.Material.Neon },
	},
}

--------------------------------------------------------------------------------
-- Skill unlocks. These are the ones people will actually chase.
--------------------------------------------------------------------------------

C.Crown_Unspent = {
	id = "Crown_Unspent",
	name = "THE UNSPENT CROWN",
	slot = "Head",
	rarity = "Legendary",
	description = "Nobody gave it to you.",
	source = "Complete a full run without dying, at Heat 5 or higher.",
	unlock = { kind = "RunChallenge", challenge = "NoDeath", minHeat = 5 },
	build = {
		{ name = "Band", size = Vector3.new(1.9, 0.34, 1.9), offset = Vector3.new(0, 0.75, 0), color = GOLD, material = Enum.Material.Metal },
		{ name = "SpikeF", size = Vector3.new(0.18, 0.9, 0.18), offset = Vector3.new(0, 1.2, -0.8), color = GOLD, material = Enum.Material.Metal },
		{ name = "SpikeL", size = Vector3.new(0.18, 0.7, 0.18), offset = Vector3.new(-0.8, 1.1, 0), color = GOLD, material = Enum.Material.Metal },
		{ name = "SpikeR", size = Vector3.new(0.18, 0.7, 0.18), offset = Vector3.new(0.8, 1.1, 0), color = GOLD, material = Enum.Material.Metal },
	},
}

C.Trail_Unbroken = {
	id = "Trail_Unbroken",
	name = "UNBROKEN LINE",
	slot = "Trail",
	rarity = "Legendary",
	description = "A line that follows you and does not stop.",
	source = "Clear an entire region without taking damage in any room.",
	unlock = { kind = "RunChallenge", challenge = "FlawlessRegion" },
	build = {
		{ name = "TrailAnchorA", size = Vector3.new(0.2, 0.2, 0.2), offset = Vector3.new(-0.7, 0, 0), transparency = 1 },
		{ name = "TrailAnchorB", size = Vector3.new(0.2, 0.2, 0.2), offset = Vector3.new(0.7, 0, 0), transparency = 1 },
		{ trail = { color = GOLD, lifetime = 0.9, width = 3 } },
	},
}

C.Horns_Verge = {
	id = "Horns_Verge",
	name = "VERGE-HORN",
	slot = "Head",
	rarity = "Epic",
	description = "Grown, not made. You are fairly sure it was not there last cycle.",
	source = "Die 50 times. It is not an achievement, exactly.",
	unlock = { kind = "Deaths", count = 50 },
	build = {
		{ name = "HornL", size = Vector3.new(0.3, 2.0, 0.3), offset = Vector3.new(-0.55, 1.1, 0), rotation = Vector3.new(-14, 0, 22), color = Color3.fromRGB(58, 52, 60), material = Enum.Material.Slate },
		{ name = "HornR", size = Vector3.new(0.3, 2.0, 0.3), offset = Vector3.new(0.55, 1.1, 0), rotation = Vector3.new(-14, 0, -22), color = Color3.fromRGB(58, 52, 60), material = Enum.Material.Slate },
	},
}

C.Mask_Guest = {
	id = "Mask_Guest",
	name = "THE GUEST'S FACE",
	slot = "Face",
	rarity = "Legendary",
	description = "It is not a mask. You have checked.",
	source = "Finish the Guest's story.",
	unlock = { kind = "Story", chapter = "GuestFinal" },
	hidden = true,
	build = {
		{ name = "Face", size = Vector3.new(1.7, 1.5, 0.25), offset = Vector3.new(0, 0, -0.85), color = Color3.fromRGB(226, 222, 214), material = Enum.Material.Marble },
		{ name = "EyeL", size = Vector3.new(0.34, 0.1, 0.08), offset = Vector3.new(-0.36, 0.18, -1.0), color = Color3.fromRGB(20, 20, 24), material = Enum.Material.SmoothPlastic },
		{ name = "EyeR", size = Vector3.new(0.34, 0.1, 0.08), offset = Vector3.new(0.36, 0.18, -1.0), color = Color3.fromRGB(20, 20, 24), material = Enum.Material.SmoothPlastic },
	},
}

C.Gloves_Tallier = {
	id = "Gloves_Tallier",
	name = "TALLIER'S GAUNTLETS",
	slot = "Hands",
	rarity = "Rare",
	description = "Taken from an officer who no longer needs them.",
	source = "Defeat 25 Talliers.",
	unlock = { kind = "EnemyKills", enemy = "Tallier", count = 25 },
	build = {
		{ name = "Gauntlet", size = Vector3.new(1.15, 1.0, 1.15), offset = Vector3.new(0, -0.6, 0), color = Color3.fromRGB(46, 44, 62), material = Enum.Material.Metal },
		{ name = "Knuckle", size = Vector3.new(1.2, 0.22, 1.2), offset = Vector3.new(0, -1.0, 0), color = GOLD, material = Enum.Material.Metal },
	},
}

C.Boots_March = {
	id = "Boots_March",
	name = "MARCH-BOOTS",
	slot = "Feet",
	rarity = "Common",
	description = "Waterlogged past the point of drying.",
	source = "Clear the Sunken March once.",
	unlock = { kind = "RegionClear", region = "SunkenMarch" },
	build = {
		{ name = "Boot", size = Vector3.new(1.15, 0.9, 1.3), offset = Vector3.new(0, -0.75, -0.1), color = Color3.fromRGB(48, 58, 64), material = Enum.Material.Fabric },
	},
}

--------------------------------------------------------------------------------
-- Accessors
--------------------------------------------------------------------------------

function CosmeticConfig.Get(cosmeticId: string): Cosmetic?
	return C[cosmeticId]
end

function CosmeticConfig.BySlot(slot: string): { Cosmetic }
	local result = {}
	for _, cosmetic in C do
		if cosmetic.slot == slot then
			table.insert(result, cosmetic)
		end
	end
	table.sort(result, function(a, b)
		return a.id < b.id
	end)
	return result
end

function CosmeticConfig.Defaults(): { string }
	local defaults = {}
	for id, cosmetic in C do
		if cosmetic.unlock.kind == "Default" then
			table.insert(defaults, id)
		end
	end
	table.sort(defaults)
	return defaults
end

function CosmeticConfig.Validate(): { string }
	local problems = {}
	for id, cosmetic in C do
		if cosmetic.id ~= id then
			table.insert(problems, ("%s has mismatched id %q"):format(id, cosmetic.id))
		end
		if not CosmeticConfig.Slots[cosmetic.slot] then
			table.insert(problems, ("%s uses unknown slot %q"):format(id, cosmetic.slot))
		end
		if not cosmetic.build or #cosmetic.build == 0 then
			table.insert(problems, id .. " has no build geometry")
		end
		if cosmetic.source == "" then
			table.insert(problems, id .. " does not say how it is earned")
		end
	end
	return problems
end

return CosmeticConfig
