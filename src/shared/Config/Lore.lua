--!strict
--[[
	Lore — the world bible, in one place.

	Everything the player reads comes from here so tone stays consistent and a
	writer can work without touching a system file. This world is original: no
	pantheon, place, weapon or character here is borrowed from an existing
	mythology or another game.

	PREMISE
	The Verge is the edge of a world that was unmade and never finished falling
	apart. It reassembles itself on a cycle called the Reforging. Anything that
	dies inside it is re-knit at the next turn of the cycle -- including you.
	The Wardens were the people who were supposed to shut the cycle down. They
	are still at their posts. They have been at their posts a very long time.

	THE PLAYER
	You are the Unspent: a warrior whose death does not take. Nobody, including
	you, knows why. The Wardens have noticed.
]]

local Lore = {}

Lore.GameName = "HOLLOW VERGE"
Lore.Tagline = "Death is the cheapest thing you own."

Lore.Terms = {
	Verge = "The Verge",
	Cycle = "the Reforging",
	Player = "the Unspent",
	Hub = "Emberhold",
	Boons = "Graces",
	BoonGivers = "the Faded",
	RunCurrency = "Motes",
	MetaCurrency = "Sable",
	WeaponVariant = "Temper",
	Relics = "Keepsakes",
}

--- The Faded: dead things too stubborn to stop giving advice. One per element.
Lore.Faded = {
	Cinder = {
		name = "Orrin, Who Kindled",
		element = "Cinder",
		color = Color3.fromRGB(255, 122, 48),
		epithet = "the first thing that burned here",
		voice = "Warm, unhurried, faintly amused. Speaks like a craftsman.",
		greeting = "Still walking. Good. Take a little of what's left of me.",
	},
	Skein = {
		name = "Talys of the Skein",
		element = "Skein",
		color = Color3.fromRGB(126, 205, 255),
		epithet = "who stitched the sky and was cut for it",
		voice = "Fast, clipped, delighted by patterns.",
		greeting = "Oh, you're a lovely shape. Let me put a thread through you.",
	},
	Rime = {
		name = "The Pale Auditor",
		element = "Rime",
		color = Color3.fromRGB(170, 226, 255),
		epithet = "who counts what the cold is owed",
		voice = "Flat, precise, never raises its voice.",
		greeting = "You are behind on your dying. I will make a note.",
	},
	Hush = {
		name = "Nuil, the Long Quiet",
		element = "Hush",
		color = Color3.fromRGB(150, 118, 220),
		epithet = "who is the space behind you",
		voice = "Whispered, incomplete sentences, trails off.",
		greeting = "You keep looking forward. The interesting part is--",
	},
	Marrow = {
		name = "Vesh, Marrow-Sister",
		element = "Marrow",
		color = Color3.fromRGB(214, 62, 84),
		epithet = "who found the cost and paid it twice",
		voice = "Blunt, physical, affectionate in a frightening way.",
		greeting = "You're leaking. Let's make that useful.",
	},
	Blight = {
		name = "Ghal of the Sump",
		element = "Blight",
		color = Color3.fromRGB(140, 200, 88),
		epithet = "who is patient, and patient, and patient",
		voice = "Slow, wet, kind.",
		greeting = "No hurry. Nothing I give you works quickly.",
	},
	Gale = {
		name = "Ysolde, Nine Winds",
		element = "Gale",
		color = Color3.fromRGB(196, 248, 226),
		epithet = "who never once stood still",
		voice = "Breathless, mid-sentence, already leaving.",
		greeting = "--and if you'd been faster you'd have caught the first half of that.",
	},
}

--- Named weapons. Each has a personality; the Blacksmith talks about them like people.
Lore.Weapons = {
	Vigil = {
		title = "VIGIL",
		subtitle = "the Longsword That Waited",
		flavor = "It belonged to a gatekeeper who never got the order to stand down.",
	},
	Grudge = {
		title = "GRUDGE",
		subtitle = "the Axe of Slow Answers",
		flavor = "Heavy as a decision you put off for a hundred years.",
	},
	Quarrel = {
		title = "QUARREL",
		subtitle = "the Paired Knives",
		flavor = "Two blades that disagree with each other and with you.",
	},
	Thresh = {
		title = "THRESH",
		subtitle = "the Reaching Spear",
		flavor = "Made for keeping things at the distance where they cannot argue.",
	},
}

--- Regions, in run order.
Lore.Regions = {
	SunkenMarch = {
		title = "THE SUNKEN MARCH",
		subtitle = "a kingdom that drowned standing up",
		description = "Flooded halls, banners still hanging, garrison still at post. "
			.. "Nobody here has been told the war ended.",
	},
	CinderReach = {
		title = "THE CINDER REACH",
		subtitle = "where the Reforging shows its seams",
		description = "The furnace floor of the world. Everything here is either burning "
			.. "or waiting its turn.",
	},
	RimefastSanctum = {
		title = "THE RIMEFAST SANCTUM",
		subtitle = "a library of held breath",
		description = "The last people to solve the Verge wrote it all down, then froze "
			.. "the room so nobody could change the answer.",
	},
}

--- Wardens: one per region, each a boss.
Lore.Wardens = {
	Vhalric = {
		title = "VHALRIC, THE TALLYMAN",
		region = "SunkenMarch",
		description = "He is keeping count. He has been keeping count for a long time, and "
			.. "you are the only number that keeps changing.",
	},
	Kessara = {
		title = "KESSARA, THE ASHMOTHER",
		region = "CinderReach",
		description = "She feeds the Reforging. She thinks she is being merciful.",
	},
	Anchorite = {
		title = "THE HOARFROST ANCHORITE",
		region = "RimefastSanctum",
		description = "It has not moved or spoken in an age. It does not intend to start "
			.. "with you.",
	},
}

--- Hub residents.
Lore.NPCs = {
	Halvic = {
		name = "DURN HALVIC",
		role = "Smith",
		description = "Reforges weapons. Was a Warden's armourer once, and does not enjoy "
			.. "being asked about it.",
	},
	Ilka = {
		name = "ILKA THE UNBLINKING",
		role = "Mystic",
		description = "Binds Graces into something permanent. Has not slept since the "
			.. "second cycle and considers this a minor inconvenience.",
	},
	Rannoch = {
		name = "RANNOCH",
		role = "Scout",
		description = "Goes out, comes back, tells you what changed. Does not fight. "
			.. "Has strong opinions about people who do.",
	},
	Miren = {
		name = "KEEPER MIREN",
		role = "Keeper",
		description = "Catalogues the Keepsakes. Believes the collection is a sentence "
			.. "and is close to finishing the first word.",
	},
	Guest = {
		name = "THE GUEST",
		role = "Stranger",
		description = "Arrived before you did. Nobody remembers letting them in. "
			.. "Knows what you are, and is waiting for you to ask.",
	},
}

--- Element display data, shared by boons, damage numbers and status icons.
Lore.Elements = {
	Physical = { name = "Physical", color = Color3.fromRGB(232, 228, 220) },
	Cinder = { name = "Cinder", color = Color3.fromRGB(255, 122, 48) },
	Skein = { name = "Skein", color = Color3.fromRGB(126, 205, 255) },
	Rime = { name = "Rime", color = Color3.fromRGB(170, 226, 255) },
	Hush = { name = "Hush", color = Color3.fromRGB(150, 118, 220) },
	Marrow = { name = "Marrow", color = Color3.fromRGB(214, 62, 84) },
	Blight = { name = "Blight", color = Color3.fromRGB(140, 200, 88) },
	Gale = { name = "Gale", color = Color3.fromRGB(196, 248, 226) },
}

function Lore.ElementColor(element: string): Color3
	local entry = Lore.Elements[element]
	return entry and entry.color or Lore.Elements.Physical.color
end

return Lore
