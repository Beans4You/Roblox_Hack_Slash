--!strict
--[[
	BossConfig — the three Wardens.

	Rules this file is written against, taken straight from the brief:
	  - No boss is a health bar. Every phase changes what the fight *is*, not how
	    long it takes.
	  - Every attack has a telegraph long enough to read across a whole arena.
	  - Bosses remember you. Their opening line is a function of how many times
	    they have already killed you, and the run is genuinely different once one
	    of them starts recognising you.

	PHASES
	A phase owns its own attack list, movement, and aggression. Crossing a phase
	threshold plays a transition: the boss is invulnerable, the arena changes, and
	the player gets a free breath. Phase transitions are also where the fight's
	dialogue lands, because that is when the player is not being asked to dodge.

	WEAK POINTS
	A weak point is a named part on the rig that takes multiplied damage while a
	condition holds -- usually "the boss is recovering from its biggest attack".
	Hitting them is how a good player shortens the fight.
]]

local PoseLibrary = require(script.Parent.PoseLibrary)
local Lore = require(script.Parent.Lore)

export type BossAttack = {
	id: string,
	name: string,
	clip: string,
	telegraph: number,
	windup: number,
	active: number,
	recovery: number,
	damage: number,
	knockback: number,
	hitbox: any,
	minRange: number,
	maxRange: number,
	cooldown: number,
	weight: number,
	telegraphShape: ("Cone" | "Line" | "Circle" | "Ring")?,
	motion: { distance: number, duration: number }?,
	-- Repeats the whole attack this many times before recovery.
	repeats: number?,
	repeatInterval: number?,
	applies: string?,
	-- Opens the boss's weak points for this long after recovery ends.
	exposesFor: number?,
	spawns: any?,
	arenaEffect: any?,
	sfx: string?,
	-- Cannot be dodged through, only avoided by position. Used very sparingly.
	undodgeable: boolean?,
}

export type BossPhase = {
	id: string,
	-- Phase becomes active when health drops to or below this fraction.
	healthThreshold: number,
	name: string,
	moveSpeed: number,
	aggression: number,
	-- Multiplies the gap between attacks. Lower is more relentless.
	tempo: number,
	damageTakenMultiplier: number?,
	attacks: { BossAttack },
	transition: {
		clip: string,
		duration: number,
		invulnerable: boolean,
		arenaEffect: any?,
		spawns: any?,
		line: string?,
	}?,
	weakPointsActive: boolean?,
}

local BossConfig = {}

BossConfig.Bosses = {}

--------------------------------------------------------------------------------
-- VHALRIC, THE TALLYMAN — the Sunken March
--
-- The tutorial boss, in the sense that it teaches the three things the game is
-- about: read the telegraph, punish the recovery, and use the arena. It is also
-- the only boss with a mechanic built on the player's death count, because it is
-- the one the player will die to first.
--------------------------------------------------------------------------------

BossConfig.Bosses.Vhalric = {
	id = "Vhalric",
	displayName = "VHALRIC, THE TALLYMAN",
	subtitle = "Warden of the Sunken March",
	region = "SunkenMarch",
	description = Lore.Wardens.Vhalric.description,
	music = "BossVhalric",

	rig = {
		scale = 2.3,
		palette = {
			primary = Color3.fromRGB(40, 54, 62),
			secondary = Color3.fromRGB(24, 34, 42),
			accent = Color3.fromRGB(255, 200, 110),
			eye = Color3.fromRGB(255, 226, 160),
		},
		silhouette = { "pauldrons", "cloak", "crest", "horns" },
		material = Enum.Material.Slate,
		glow = true,
	},

	stats = {
		maxHealth = 3200,
		-- Bosses are never staggered by normal hits; poise damage fills a break
		-- meter that only empties them when it is full. Chip damage cannot chain
		-- them into helplessness.
		breakThreshold = 900,
		breakDuration = 3.4,
		breakDamageMultiplier = 1.6,
		detectionRange = 200,
		weight = 6,
	},

	arena = {
		radius = 78,
		-- Pillars start intact and are broken during phase two, changing the space.
		pillars = 6,
		pillarRadius = 44,
		hazardType = "Water",
		ambientColor = Color3.fromRGB(52, 78, 92),
	},

	weakPoints = {
		{ part = "Head", multiplier = 2.0, name = "the ledger-eye" },
		{ part = "Torso", multiplier = 1.5, name = "the tally-plate" },
	},

	phases = {
		{
			id = "Measured",
			healthThreshold = 1.0,
			name = "MEASURED",
			moveSpeed = 12,
			aggression = 0.5,
			tempo = 1.0,
			attacks = {
				{
					id = "Assize",
					name = "Assize",
					clip = "Boss_Sweep",
					telegraph = 0.62, windup = 0.62, active = 0.18, recovery = 0.55,
					damage = 26, knockback = 34,
					hitbox = { shape = "Arc", range = 22, angle = 150, height = 12 },
					minRange = 0, maxRange = 22, cooldown = 4.5, weight = 4,
					telegraphShape = "Cone", sfx = "BossSweep",
					exposesFor = 1.1,
				},
				{
					id = "Sentence",
					name = "Sentence",
					clip = "Boss_Overhead",
					telegraph = 0.78, windup = 0.78, active = 0.18, recovery = 0.59,
					damage = 42, knockback = 44,
					hitbox = { shape = "Sphere", range = 18, height = 12 },
					minRange = 0, maxRange = 20, cooldown = 7.5, weight = 3,
					telegraphShape = "Circle", sfx = "BossOverhead",
					exposesFor = 1.8,
					arenaEffect = { kind = "Shockwave", radius = 34, delay = 0.1, damage = 14 },
				},
				{
					id = "Approach",
					name = "Approach",
					clip = "Boss_Charge",
					telegraph = 0.50, windup = 0.50, active = 0.30, recovery = 0.30,
					damage = 30, knockback = 40,
					hitbox = { shape = "Box", range = 40, width = 8, height = 12, offset = Vector3.new(0, 0, -18) },
					minRange = 22, maxRange = 70, cooldown = 9, weight = 3,
					motion = { distance = 42, duration = 0.34 },
					telegraphShape = "Line", sfx = "BossCharge",
					exposesFor = 1.4,
				},
			},
		},

		{
			id = "Contested",
			healthThreshold = 0.65,
			name = "CONTESTED",
			moveSpeed = 15,
			aggression = 0.7,
			tempo = 0.82,
			transition = {
				clip = "Boss_Roar",
				duration = 2.6,
				invulnerable = true,
				-- He breaks the hall to stop you circling him. The pillars become cover
				-- and the water rises, so the ground you learned in phase one is gone.
				arenaEffect = { kind = "ShatterPillars", count = 4, debrisDamage = 18, floodDepth = 2 },
				spawns = { { enemy = "Marchman", count = 3 }, { enemy = "Fletcher", count = 1 } },
				line = "Vhalric_Phase2",
			},
			attacks = {
				{
					id = "Assize",
					name = "Assize",
					clip = "Boss_Sweep",
					telegraph = 0.62, windup = 0.62, active = 0.18, recovery = 0.55,
					damage = 28, knockback = 34,
					hitbox = { shape = "Arc", range = 24, angle = 170, height = 12 },
					minRange = 0, maxRange = 24, cooldown = 3.6, weight = 4,
					repeats = 2, repeatInterval = 0.4,
					telegraphShape = "Cone", sfx = "BossSweep",
					exposesFor = 1.3,
				},
				{
					id = "Reckoning",
					name = "Reckoning",
					clip = "Boss_Stomp",
					telegraph = 0.68, windup = 0.68, active = 0.16, recovery = 0.66,
					damage = 34, knockback = 50,
					hitbox = { shape = "Sphere", range = 26, height = 14 },
					minRange = 0, maxRange = 26, cooldown = 8, weight = 3,
					telegraphShape = "Ring", sfx = "BossStomp",
					arenaEffect = { kind = "RingWave", innerRadius = 10, outerRadius = 46, speed = 40, damage = 22 },
					exposesFor = 1.6,
				},
				{
					id = "Levy",
					name = "Levy",
					clip = "Boss_Roar",
					telegraph = 0.90, windup = 0.90, active = 0.20, recovery = 0.90,
					damage = 0, knockback = 0,
					hitbox = { shape = "Sphere", range = 1, height = 1 },
					minRange = 0, maxRange = 999, cooldown = 22, weight = 2,
					telegraphShape = "Circle", sfx = "BossRoar",
					-- Adds exist to break your rhythm, not to kill you. Small and few.
					spawns = { { enemy = "Marchman", count = 2 }, { enemy = "Cutter", count = 2 } },
					exposesFor = 2.4,
				},
				{
					id = "Debris",
					name = "Debris",
					clip = "Boss_Charge",
					telegraph = 0.50, windup = 0.50, active = 0.30, recovery = 0.30,
					damage = 24, knockback = 26,
					hitbox = { shape = "Sphere", range = 12, height = 10 },
					minRange = 25, maxRange = 80, cooldown = 6, weight = 4,
					telegraphShape = "Circle", sfx = "BossThrow",
					arenaEffect = { kind = "ThrownDebris", count = 3, radius = 12, damage = 24, travelTime = 1.1 },
				},
			},
		},

		{
			id = "Overdrawn",
			healthThreshold = 0.30,
			name = "OVERDRAWN",
			moveSpeed = 19,
			aggression = 0.95,
			tempo = 0.62,
			-- The core is out. He hits harder and takes more.
			damageTakenMultiplier = 1.25,
			weakPointsActive = true,
			transition = {
				clip = "Boss_Roar",
				duration = 3.0,
				invulnerable = true,
				arenaEffect = { kind = "ExposeCore", glowColor = Color3.fromRGB(255, 200, 110), drainWater = true },
				line = "Vhalric_Phase3",
			},
			attacks = {
				{
					id = "Overdraw",
					name = "Overdraw",
					clip = "Boss_Sweep",
					telegraph = 0.62, windup = 0.62, active = 0.18, recovery = 0.55,
					damage = 32, knockback = 30,
					hitbox = { shape = "Arc", range = 26, angle = 180, height = 12 },
					minRange = 0, maxRange = 26, cooldown = 2.8, weight = 5,
					repeats = 3, repeatInterval = 0.32,
					telegraphShape = "Cone", sfx = "BossSweep",
					exposesFor = 1.5,
				},
				{
					id = "Foreclose",
					name = "Foreclose",
					clip = "Boss_Overhead",
					telegraph = 0.78, windup = 0.78, active = 0.18, recovery = 0.59,
					damage = 55, knockback = 60,
					hitbox = { shape = "Sphere", range = 22, height = 14 },
					minRange = 0, maxRange = 24, cooldown = 6, weight = 4,
					telegraphShape = "Circle", sfx = "BossOverhead",
					arenaEffect = { kind = "Shockwave", radius = 48, delay = 0.1, damage = 20 },
					exposesFor = 2.2,
				},
				{
					id = "Settlement",
					name = "Settlement",
					clip = "Boss_Stomp",
					telegraph = 0.68, windup = 0.68, active = 0.16, recovery = 0.66,
					damage = 70, knockback = 70,
					hitbox = { shape = "Sphere", range = 34, height = 16 },
					minRange = 0, maxRange = 40, cooldown = 18, weight = 2,
					telegraphShape = "Ring",
					sfx = "BossSettlement",
					-- The one attack in the fight you cannot dodge through: there is a
					-- safe ring, and you have to be standing in it.
					undodgeable = true,
					arenaEffect = { kind = "SafeRing", safeInner = 16, safeOuter = 26, damage = 70, telegraphTime = 2.2 },
					exposesFor = 3.0,
				},
			},
		},
	},

	rewards = {
		sable = 60,
		firstClearSable = 150,
		relic = "TallymansLedger",
		unlocksRegion = "CinderReach",
		unlocksWeapon = "Thresh",
	},

	--[[
		Dialogue. `meet` entries are chosen by how many times Vhalric has personally
		killed this player, highest matching threshold wins. This is the mechanic
		the brief asks for -- the boss noticing -- and it costs nothing but a table.
	]]
	dialogue = {
		meet = {
			{ deaths = 0, line = "You cannot pass. That is the whole of it." },
			{ deaths = 1, line = "Back. Fine. I will write it down again." },
			{ deaths = 3, line = "You again. I had begun a fresh page for you." },
			{ deaths = 5, line = "Four. Five, shortly. The column is getting long." },
			{ deaths = 7, line = "I have killed you seven times. Why do you refuse to stay dead?" },
			{ deaths = 12, line = "I no longer believe you are a person. I think you are a debt." },
			{ deaths = 20, line = "Do you know what happens to a ledger that cannot be balanced? "
				.. "It is burned. Come here." },
		},
		Vhalric_Phase2 = "You have made me stand up. Nobody has made me stand up.",
		Vhalric_Phase3 = "Then we will both be over with.",
		onPlayerDeath = {
			"Recorded.",
			"That is one more.",
			"I will be here.",
			"You are consistent, at least.",
		},
		onDefeat = "Ah. So that is what the number was for.",
		-- Said only once, the first time the player wins.
		onFirstDefeat = "I kept count for four hundred years so that someone would know "
			.. "the size of it. Take the ledger. Tell them.",
	},
}

--------------------------------------------------------------------------------
-- KESSARA, THE ASHMOTHER — the Cinder Reach
--
-- The arena is the mechanic. Kessara does not need to hit you; she needs the
-- floor to. Phases progressively take away safe ground until the fight is fought
-- on a shrinking island.
--------------------------------------------------------------------------------

BossConfig.Bosses.Kessara = {
	id = "Kessara",
	displayName = "KESSARA, THE ASHMOTHER",
	subtitle = "Warden of the Cinder Reach",
	region = "CinderReach",
	description = Lore.Wardens.Kessara.description,
	music = "BossKessara",

	rig = {
		scale = 2.0,
		palette = {
			primary = Color3.fromRGB(58, 34, 30),
			secondary = Color3.fromRGB(34, 20, 18),
			accent = Color3.fromRGB(255, 122, 48),
			eye = Color3.fromRGB(255, 214, 140),
		},
		silhouette = { "horns", "tatters", "halo" },
		material = Enum.Material.Neon,
		glow = true,
	},

	stats = {
		maxHealth = 4100,
		breakThreshold = 1000,
		breakDuration = 3.0,
		breakDamageMultiplier = 1.6,
		detectionRange = 200,
		weight = 5,
	},

	arena = {
		radius = 70,
		pillars = 0,
		hazardType = "Lava",
		ambientColor = Color3.fromRGB(70, 30, 20),
		-- Safe floor tiles that burn away as the fight progresses.
		platforms = 9,
	},

	weakPoints = {
		{ part = "Torso", multiplier = 2.2, name = "the forge-heart" },
	},

	phases = {
		{
			id = "Tending",
			healthThreshold = 1.0,
			name = "TENDING",
			moveSpeed = 14,
			aggression = 0.55,
			tempo = 0.95,
			attacks = {
				{
					id = "Stoke",
					name = "Stoke",
					clip = "Boss_Sweep",
					telegraph = 0.62, windup = 0.62, active = 0.18, recovery = 0.55,
					damage = 28, knockback = 30,
					hitbox = { shape = "Arc", range = 20, angle = 140, height = 11 },
					minRange = 0, maxRange = 20, cooldown = 4, weight = 4,
					applies = "Burn",
					telegraphShape = "Cone", sfx = "BossSweep",
					exposesFor = 1.2,
				},
				{
					id = "Cinderfall",
					name = "Cinderfall",
					clip = "Boss_Roar",
					telegraph = 0.90, windup = 0.90, active = 0.20, recovery = 0.90,
					damage = 22, knockback = 16,
					hitbox = { shape = "Sphere", range = 1, height = 1 },
					minRange = 0, maxRange = 999, cooldown = 11, weight = 3,
					telegraphShape = "Circle", sfx = "BossRoar",
					arenaEffect = { kind = "Meteors", count = 7, radius = 9, damage = 22, warnTime = 1.3, applies = "Burn" },
					exposesFor = 1.8,
				},
			},
		},
		{
			id = "Banking",
			healthThreshold = 0.68,
			name = "BANKING",
			moveSpeed = 16,
			aggression = 0.75,
			tempo = 0.8,
			transition = {
				clip = "Boss_Roar",
				duration = 2.4,
				invulnerable = true,
				arenaEffect = { kind = "BurnPlatforms", count = 3, warnTime = 2 },
				spawns = { { enemy = "Censer", count = 3 } },
				line = "Kessara_Phase2",
			},
			attacks = {
				{
					id = "Bellows",
					name = "Bellows",
					clip = "Boss_Charge",
					telegraph = 0.50, windup = 0.50, active = 0.30, recovery = 0.30,
					damage = 30, knockback = 44,
					hitbox = { shape = "Box", range = 44, width = 10, height = 12, offset = Vector3.new(0, 0, -20) },
					minRange = 14, maxRange = 70, cooldown = 7, weight = 4,
					applies = "Burn",
					telegraphShape = "Line", sfx = "BossFlamethrower",
					exposesFor = 1.6,
				},
				{
					id = "Cinderfall",
					name = "Cinderfall",
					clip = "Boss_Roar",
					telegraph = 0.90, windup = 0.90, active = 0.20, recovery = 0.90,
					damage = 26, knockback = 16,
					hitbox = { shape = "Sphere", range = 1, height = 1 },
					minRange = 0, maxRange = 999, cooldown = 9, weight = 3,
					telegraphShape = "Circle", sfx = "BossRoar",
					arenaEffect = { kind = "Meteors", count = 11, radius = 9, damage = 26, warnTime = 1.1, applies = "Burn" },
					exposesFor = 1.8,
				},
				{
					id = "Smelt",
					name = "Smelt",
					clip = "Boss_Stomp",
					telegraph = 0.68, windup = 0.68, active = 0.16, recovery = 0.66,
					damage = 38, knockback = 40,
					hitbox = { shape = "Sphere", range = 24, height = 12 },
					minRange = 0, maxRange = 24, cooldown = 8, weight = 3,
					applies = "Burn",
					telegraphShape = "Ring", sfx = "BossStomp",
					arenaEffect = { kind = "RingWave", innerRadius = 8, outerRadius = 40, speed = 36, damage = 24 },
					exposesFor = 1.5,
				},
			},
		},
		{
			id = "Spending",
			healthThreshold = 0.32,
			name = "SPENDING",
			moveSpeed = 20,
			aggression = 1.0,
			tempo = 0.6,
			damageTakenMultiplier = 1.2,
			weakPointsActive = true,
			transition = {
				clip = "Boss_Roar",
				duration = 3.2,
				invulnerable = true,
				arenaEffect = { kind = "BurnPlatforms", count = 4, warnTime = 1.6, exposeCore = true },
				line = "Kessara_Phase3",
			},
			attacks = {
				{
					id = "Pyre",
					name = "Pyre",
					clip = "Boss_Overhead",
					telegraph = 0.78, windup = 0.78, active = 0.18, recovery = 0.59,
					damage = 52, knockback = 50,
					hitbox = { shape = "Sphere", range = 22, height = 14 },
					minRange = 0, maxRange = 22, cooldown = 5, weight = 4,
					applies = "Burn",
					telegraphShape = "Circle", sfx = "BossOverhead",
					arenaEffect = { kind = "GroundFire", radius = 20, duration = 6, tickDamage = 8 },
					exposesFor = 2.0,
				},
				{
					id = "Everything",
					name = "Everything I Have",
					clip = "Boss_Roar",
					telegraph = 0.90, windup = 0.90, active = 0.20, recovery = 0.90,
					damage = 40, knockback = 20,
					hitbox = { shape = "Sphere", range = 1, height = 1 },
					minRange = 0, maxRange = 999, cooldown = 20, weight = 2,
					telegraphShape = "Circle", sfx = "BossRoar",
					undodgeable = true,
					arenaEffect = { kind = "Meteors", count = 22, radius = 8, damage = 40, warnTime = 0.9, applies = "Burn" },
					exposesFor = 3.4,
				},
			},
		},
	},

	rewards = {
		sable = 90,
		firstClearSable = 220,
		relic = "AshmothersCoal",
		unlocksRegion = "RimefastSanctum",
		unlocksWeapon = "Grudge",
	},

	dialogue = {
		meet = {
			{ deaths = 0, line = "Oh, good. Something that still burns." },
			{ deaths = 2, line = "You came back. They usually do not come back." },
			{ deaths = 5, line = "I am not cruel. I am the only one still doing the work." },
			{ deaths = 9, line = "Stop. Please. I do not want to be the thing that keeps doing "
				.. "this to you." },
			{ deaths = 15, line = "Then let me finish it properly. It is kinder." },
		},
		Kessara_Phase2 = "The floor was never for you. Nothing here was for you.",
		Kessara_Phase3 = "Fine. FINE. Take it all.",
		onPlayerDeath = { "Rest.", "It is warmer here.", "Sleep, and try again." },
		onDefeat = "Someone has to keep it lit. Someone--",
		onFirstDefeat = "It was never a punishment. The Reforging needs fuel, and I was the "
			.. "only one who would carry it. Now it is you.",
	},
}

--------------------------------------------------------------------------------
-- THE HOARFROST ANCHORITE — the Rimefast Sanctum
--
-- The gimmick: it does not move. It never moves. Everything else in the arena
-- does, and the fight is a puzzle about closing distance under fire, then getting
-- back out before it exhales.
--------------------------------------------------------------------------------

BossConfig.Bosses.Anchorite = {
	id = "Anchorite",
	displayName = "THE HOARFROST ANCHORITE",
	subtitle = "Warden of the Rimefast Sanctum",
	region = "RimefastSanctum",
	description = Lore.Wardens.Anchorite.description,
	music = "BossAnchorite",

	rig = {
		scale = 2.6,
		palette = {
			primary = Color3.fromRGB(120, 142, 162),
			secondary = Color3.fromRGB(78, 96, 116),
			accent = Color3.fromRGB(210, 240, 255),
			eye = Color3.fromRGB(240, 252, 255),
		},
		silhouette = { "halo", "cloak", "crest" },
		material = Enum.Material.Ice,
		glow = true,
	},

	stats = {
		maxHealth = 5200,
		breakThreshold = 1400,
		breakDuration = 4.0,
		breakDamageMultiplier = 2.0,
		detectionRange = 999,
		weight = 99,
	},

	arena = {
		radius = 84,
		pillars = 8,
		pillarRadius = 52,
		hazardType = "Ice",
		ambientColor = Color3.fromRGB(120, 150, 180),
		-- The floor is frictionless in patches; movement is part of the puzzle.
		slipPatches = 6,
	},

	weakPoints = {
		{ part = "Head", multiplier = 2.6, name = "the open eye" },
		{ part = "LeftArm", multiplier = 1.8, name = "the raised hand" },
		{ part = "RightArm", multiplier = 1.8, name = "the lowered hand" },
	},

	phases = {
		{
			id = "Silence",
			healthThreshold = 1.0,
			name = "SILENCE",
			moveSpeed = 0,
			aggression = 0.4,
			tempo = 1.1,
			attacks = {
				{
					id = "Recitation",
					name = "Recitation",
					clip = "Boss_Cast",
					telegraph = 0.72, windup = 0.72, active = 0.12, recovery = 0.56,
					damage = 24, knockback = 18,
					hitbox = { shape = "Sphere", range = 1, height = 1 },
					minRange = 0, maxRange = 999, cooldown = 5, weight = 4,
					applies = "Chill",
					telegraphShape = "Line", sfx = "BossCast",
					arenaEffect = { kind = "IceLances", count = 5, width = 6, length = 80, damage = 24, warnTime = 1.2 },
				},
				{
					id = "Rebuke",
					name = "Rebuke",
					clip = "Boss_Sweep",
					telegraph = 0.62, windup = 0.62, active = 0.18, recovery = 0.55,
					damage = 34, knockback = 46,
					hitbox = { shape = "Arc", range = 26, angle = 200, height = 14 },
					minRange = 0, maxRange = 26, cooldown = 3, weight = 5,
					applies = "Chill",
					telegraphShape = "Cone", sfx = "BossSweep",
					exposesFor = 1.4,
				},
			},
		},
		{
			id = "Attention",
			healthThreshold = 0.66,
			name = "ATTENTION",
			moveSpeed = 0,
			aggression = 0.7,
			tempo = 0.85,
			transition = {
				clip = "Boss_Roar",
				duration = 2.8,
				invulnerable = true,
				arenaEffect = { kind = "RaiseIceWalls", count = 6, height = 20, duration = 999 },
				spawns = { { enemy = "Vesper", count = 4 } },
				line = "Anchorite_Phase2",
			},
			attacks = {
				{
					id = "Recitation",
					name = "Recitation",
					clip = "Boss_Cast",
					telegraph = 0.72, windup = 0.72, active = 0.12, recovery = 0.56,
					damage = 28, knockback = 18,
					hitbox = { shape = "Sphere", range = 1, height = 1 },
					minRange = 0, maxRange = 999, cooldown = 4, weight = 4,
					applies = "Chill",
					telegraphShape = "Line", sfx = "BossCast",
					arenaEffect = { kind = "IceLances", count = 9, width = 6, length = 80, damage = 28, warnTime = 1.0 },
				},
				{
					id = "Exhale",
					name = "Exhale",
					clip = "Boss_Roar",
					telegraph = 0.90, windup = 0.90, active = 0.20, recovery = 0.90,
					damage = 44, knockback = 60,
					hitbox = { shape = "Sphere", range = 40, height = 20 },
					minRange = 0, maxRange = 40, cooldown = 13, weight = 3,
					applies = "Frozen",
					telegraphShape = "Ring", sfx = "BossExhale",
					arenaEffect = { kind = "SafeRing", safeInner = 42, safeOuter = 70, damage = 44, telegraphTime = 2.4 },
					undodgeable = true,
					exposesFor = 2.6,
				},
			},
		},
		{
			id = "Answer",
			healthThreshold = 0.30,
			name = "ANSWER",
			moveSpeed = 8,
			aggression = 1.0,
			tempo = 0.65,
			damageTakenMultiplier = 1.3,
			weakPointsActive = true,
			transition = {
				clip = "Boss_Roar",
				duration = 3.4,
				invulnerable = true,
				-- It moves. That is the whole shock of the phase.
				arenaEffect = { kind = "ShatterIceWalls", debrisDamage = 26, exposeCore = true },
				line = "Anchorite_Phase3",
			},
			attacks = {
				{
					id = "Verdict",
					name = "Verdict",
					clip = "Boss_Overhead",
					telegraph = 0.78, windup = 0.78, active = 0.18, recovery = 0.59,
					damage = 60, knockback = 56,
					hitbox = { shape = "Sphere", range = 24, height = 16 },
					minRange = 0, maxRange = 26, cooldown = 5, weight = 4,
					applies = "Chill",
					telegraphShape = "Circle", sfx = "BossOverhead",
					arenaEffect = { kind = "Shockwave", radius = 44, delay = 0.1, damage = 24 },
					exposesFor = 2.0,
				},
				{
					id = "Closing",
					name = "Closing Argument",
					clip = "Boss_Charge",
					telegraph = 0.50, windup = 0.50, active = 0.30, recovery = 0.30,
					damage = 46, knockback = 60,
					hitbox = { shape = "Box", range = 50, width = 12, height = 16, offset = Vector3.new(0, 0, -22) },
					minRange = 18, maxRange = 90, cooldown = 8, weight = 4,
					motion = { distance = 50, duration = 0.34 },
					telegraphShape = "Line", sfx = "BossCharge",
					exposesFor = 2.4,
				},
				{
					id = "Everything",
					name = "The Last Line",
					clip = "Boss_Cast",
					telegraph = 0.72, windup = 0.72, active = 0.12, recovery = 0.56,
					damage = 36, knockback = 20,
					hitbox = { shape = "Sphere", range = 1, height = 1 },
					minRange = 0, maxRange = 999, cooldown = 16, weight = 2,
					applies = "Frozen",
					telegraphShape = "Line", sfx = "BossCast",
					arenaEffect = { kind = "IceLances", count = 16, width = 6, length = 90, damage = 36, warnTime = 0.85 },
					exposesFor = 2.8,
				},
			},
		},
	},

	rewards = {
		sable = 130,
		firstClearSable = 320,
		relic = "AnchoritesSilence",
		unlocksWeapon = "Quarrel",
		unlocksEnding = true,
	},

	dialogue = {
		meet = {
			{ deaths = 0, line = "..." },
			{ deaths = 1, line = "..." },
			{ deaths = 4, line = "(It has not moved. You are almost certain it is looking at you.)" },
			{ deaths = 8, line = "(Something in the ice has changed position since last time.)" },
			{ deaths = 14, line = "You are the noise. I had almost finished." },
		},
		Anchorite_Phase2 = "You are the noise.",
		Anchorite_Phase3 = "Very well. I will come down.",
		onPlayerDeath = { "...", "...", "Quiet, now." },
		onDefeat = "Then it was never a question of holding still.",
		onFirstDefeat = "We wrote the answer and froze the room so nobody could change it. "
			.. "We did not consider that the answer might be wrong. Go and be wrong somewhere else.",
	},
}

--------------------------------------------------------------------------------
-- Accessors
--------------------------------------------------------------------------------

BossConfig.Order = { "Vhalric", "Kessara", "Anchorite" }

function BossConfig.Get(bossId: string)
	return BossConfig.Bosses[bossId]
end

function BossConfig.ForRegion(regionId: string)
	for _, boss in BossConfig.Bosses do
		if boss.region == regionId then
			return boss
		end
	end
	return nil
end

--- Highest-threshold greeting the boss has earned against this player.
function BossConfig.MeetLine(bossId: string, deathsToThisBoss: number): string?
	local boss = BossConfig.Bosses[bossId]
	if not boss then
		return nil
	end
	local chosen
	for _, entry in boss.dialogue.meet do
		if deathsToThisBoss >= entry.deaths then
			if not chosen or entry.deaths > chosen.deaths then
				chosen = entry
			end
		end
	end
	return chosen and chosen.line or nil
end

--- The phase a boss should be in at a given health fraction.
function BossConfig.PhaseFor(bossId: string, healthFraction: number): (number, any)
	local boss = BossConfig.Bosses[bossId]
	if not boss then
		return 1, nil
	end
	local index = 1
	for phaseIndex, phase in boss.phases do
		if healthFraction <= phase.healthThreshold then
			index = phaseIndex
		end
	end
	return index, boss.phases[index]
end

function BossConfig.AttackDuration(attack: BossAttack): number
	return attack.windup + attack.active + attack.recovery
end

function BossConfig.Validate(): { string }
	local problems = {}

	for id, boss in BossConfig.Bosses do
		local previousThreshold = math.huge
		for _, phase in boss.phases do
			if phase.healthThreshold > previousThreshold then
				table.insert(problems, ("%s phases are not in descending health order"):format(id))
			end
			previousThreshold = phase.healthThreshold

			for _, attack in phase.attacks do
				local clip = PoseLibrary.Get(attack.clip)
				if not clip then
					table.insert(problems, ("%s/%s references missing clip %q"):format(id, attack.id, attack.clip))
				elseif math.abs(BossConfig.AttackDuration(attack) - clip.duration) > 0.035 then
					table.insert(
						problems,
						("%s/%s timing %.3fs does not match clip %q (%.3fs)")
							:format(id, attack.id, BossConfig.AttackDuration(attack), attack.clip, clip.duration)
					)
				end
				if attack.telegraph > attack.windup + 1e-4 then
					table.insert(problems, ("%s/%s telegraph exceeds its windup"):format(id, attack.id))
				end
			end
		end
		if #boss.phases < 2 then
			table.insert(problems, id .. " has fewer than two phases")
		end
	end

	return problems
end

return BossConfig
