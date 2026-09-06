--!strict
--[[
	WeaponConfig — the four weapons, as data.

	The design brief for this game is blunt about weapons: they must not be stat
	variations. So a weapon here owns its entire moveset -- every swing's timing,
	hitbox shape, root motion, cancel windows, camera kick and animation clip. The
	combat system contains no weapon-specific code at all; adding a fifth weapon
	means adding a table to this file and a handful of clips to PoseLibrary.

	READING A SWING
	  windup   seconds before the hitbox opens. This is the tell.
	  active   seconds the hitbox is open. Short = precise, long = sweeping.
	  recovery seconds after the hitbox closes before the action ends.
	  cancel   fraction of recovery that must elapse before the next input is
	           allowed, per action type. 0 = cancel the moment the hitbox shuts,
	           1 = you live with the whole thing. This is the single most important
	           number for how a weapon feels: Quarrel sits at 0.12, Grudge at 0.6,
	           and that gap is most of what separates them.

	The three phases must sum to the clip duration, or the blade will look like it
	connects at the wrong moment. There is a check for this in the test harness.

	DAMAGE
	`damage` is a multiplier on the weapon's baseDamage, never a flat number, so
	one stat edit rescales a whole moveset coherently.
]]

local PoseLibrary = require(script.Parent.PoseLibrary)

export type Hitbox = {
	-- Arc: a cone in front of the attacker. Box: a rectangular volume (thrusts).
	-- Sphere: radial, used for slams and spins.
	shape: "Arc" | "Box" | "Sphere",
	range: number,
	-- Arc only: total sweep in degrees, centred on facing.
	angle: number?,
	-- Box only: half-extents.
	width: number?,
	height: number?,
	-- Offset from the attacker's root, in local space.
	offset: Vector3?,
	maxTargets: number?,
}

export type Motion = {
	distance: number,
	duration: number,
	-- Motion is suppressed when the attacker is about to walk off a ledge.
	direction: "Forward" | "Facing" | "Input"?,
}

export type Swing = {
	clip: string,
	windup: number,
	active: number,
	recovery: number,
	damage: number,
	poise: number,
	knockback: number,
	hitbox: Hitbox,
	motion: Motion?,
	-- Fraction of recovery that must elapse before each follow-up becomes legal.
	cancel: { light: number?, heavy: number?, dodge: number?, ability: number? }?,
	-- Frame freeze on a successful hit. The single cheapest way to make a hit
	-- feel like it landed. Scaled down when several enemies are hit at once.
	hitStop: number?,
	camera: { shake: number?, fovKick: number? }?,
	-- Launches the target into the air; enables air-juggle follow-ups.
	launch: number?,
	-- Pulls targets toward the attacker instead of pushing them away.
	pull: number?,
	sfx: string?,
	vfxImpact: string?,
	-- Free-form flags that boons read, e.g. "IsSpin", "IsThrust", "IsFinal".
	tags: { string }?,
}

export type Weapon = {
	id: string,
	displayName: string,
	subtitle: string,
	archetype: string,
	description: string,
	playstyle: string,
	strengths: { string },
	weaknesses: { string },
	unlockedByDefault: boolean,
	unlockCost: number,
	tags: { string },
	stats: {
		baseDamage: number,
		reach: number,
		moveSpeedMultiplier: number,
		staminaCostMultiplier: number,
		-- Multiplies incoming stagger the wielder can absorb before flinching.
		poise: number,
	},
	model: any,
	dodgeStyle: string,
	lightCombo: { Swing },
	heavy: Swing,
	ability: any,
	ultimate: any,
	finisher: any,
	tempers: { any },
}

local WeaponConfig = {}

--------------------------------------------------------------------------------
-- Weapon geometry. Built at runtime and welded to the wielder's grip attachment.
-- Offsets are relative to the grip, +Y along the blade, -Z forward.
--------------------------------------------------------------------------------

local STEEL = Color3.fromRGB(196, 202, 214)
local DARK_STEEL = Color3.fromRGB(96, 102, 116)
local LEATHER = Color3.fromRGB(64, 48, 40)
local BRASS = Color3.fromRGB(186, 148, 84)
local BONE = Color3.fromRGB(214, 206, 184)

WeaponConfig.Models = {
	Vigil = {
		gripOffset = CFrame.new(0, -0.2, 0) * CFrame.Angles(math.rad(-90), 0, 0),
		trail = { from = Vector3.new(0, 0.6, 0), to = Vector3.new(0, 4.4, 0) },
		parts = {
			{ name = "Grip", size = Vector3.new(0.22, 1.0, 0.22), offset = CFrame.new(0, 0, 0), color = LEATHER, material = Enum.Material.Fabric },
			{ name = "Pommel", size = Vector3.new(0.34, 0.3, 0.34), offset = CFrame.new(0, -0.6, 0), color = BRASS, material = Enum.Material.Metal },
			{ name = "Guard", size = Vector3.new(1.5, 0.18, 0.34), offset = CFrame.new(0, 0.58, 0), color = BRASS, material = Enum.Material.Metal },
			{ name = "Blade", size = Vector3.new(0.3, 3.6, 0.09), offset = CFrame.new(0, 2.44, 0), color = STEEL, material = Enum.Material.Metal, reflectance = 0.18 },
			{ name = "Fuller", size = Vector3.new(0.08, 3.2, 0.12), offset = CFrame.new(0, 2.4, 0), color = DARK_STEEL, material = Enum.Material.Metal },
			{ name = "Tip", size = Vector3.new(0.3, 0.5, 0.09), offset = CFrame.new(0, 4.4, 0), color = STEEL, material = Enum.Material.Metal, wedge = true },
		},
	},

	Grudge = {
		gripOffset = CFrame.new(0, -0.4, 0) * CFrame.Angles(math.rad(-90), 0, 0),
		trail = { from = Vector3.new(0, 2.4, 0), to = Vector3.new(0, 4.6, 0) },
		parts = {
			{ name = "Haft", size = Vector3.new(0.28, 4.6, 0.28), offset = CFrame.new(0, 1.6, 0), color = Color3.fromRGB(58, 44, 36), material = Enum.Material.Wood },
			{ name = "Wrap", size = Vector3.new(0.34, 1.2, 0.34), offset = CFrame.new(0, 0.1, 0), color = LEATHER, material = Enum.Material.Fabric },
			{ name = "Butt", size = Vector3.new(0.4, 0.34, 0.4), offset = CFrame.new(0, -0.75, 0), color = DARK_STEEL, material = Enum.Material.Metal },
			{ name = "HeadCore", size = Vector3.new(0.5, 1.5, 0.5), offset = CFrame.new(0, 3.5, 0), color = DARK_STEEL, material = Enum.Material.Metal },
			{ name = "BladeMain", size = Vector3.new(2.1, 2.0, 0.16), offset = CFrame.new(0.9, 3.5, 0), color = STEEL, material = Enum.Material.Metal, reflectance = 0.12 },
			{ name = "BladeBack", size = Vector3.new(1.1, 1.3, 0.14), offset = CFrame.new(-0.6, 3.5, 0), color = STEEL, material = Enum.Material.Metal },
			{ name = "Spike", size = Vector3.new(0.2, 0.9, 0.2), offset = CFrame.new(0, 4.6, 0), color = DARK_STEEL, material = Enum.Material.Metal },
		},
	},

	Quarrel = {
		-- Twin blades: the offhand copy is mirrored onto the left grip at build time.
		gripOffset = CFrame.new(0, -0.1, 0) * CFrame.Angles(math.rad(-90), 0, 0),
		trail = { from = Vector3.new(0, 0.4, 0), to = Vector3.new(0, 2.3, 0) },
		mirrored = true,
		parts = {
			{ name = "Grip", size = Vector3.new(0.18, 0.7, 0.18), offset = CFrame.new(0, 0, 0), color = Color3.fromRGB(38, 34, 44), material = Enum.Material.Fabric },
			{ name = "Guard", size = Vector3.new(0.7, 0.12, 0.24), offset = CFrame.new(0, 0.4, 0), color = DARK_STEEL, material = Enum.Material.Metal },
			{ name = "Blade", size = Vector3.new(0.22, 1.9, 0.07), offset = CFrame.new(0, 1.4, 0), color = Color3.fromRGB(224, 228, 238), material = Enum.Material.Metal, reflectance = 0.3 },
			{ name = "Edge", size = Vector3.new(0.06, 1.9, 0.1), offset = CFrame.new(0.1, 1.4, 0), color = Color3.fromRGB(150, 118, 220), material = Enum.Material.Neon },
			{ name = "Tip", size = Vector3.new(0.22, 0.4, 0.07), offset = CFrame.new(0, 2.5, 0), color = Color3.fromRGB(224, 228, 238), material = Enum.Material.Metal, wedge = true },
		},
	},

	Thresh = {
		gripOffset = CFrame.new(0, -1.2, 0) * CFrame.Angles(math.rad(-90), 0, 0),
		trail = { from = Vector3.new(0, 4.0, 0), to = Vector3.new(0, 5.6, 0) },
		parts = {
			{ name = "Shaft", size = Vector3.new(0.2, 6.4, 0.2), offset = CFrame.new(0, 2.2, 0), color = Color3.fromRGB(72, 60, 52), material = Enum.Material.Wood },
			{ name = "Wrap", size = Vector3.new(0.26, 1.0, 0.26), offset = CFrame.new(0, 0.4, 0), color = LEATHER, material = Enum.Material.Fabric },
			{ name = "Counterweight", size = Vector3.new(0.3, 0.5, 0.3), offset = CFrame.new(0, -1.1, 0), color = DARK_STEEL, material = Enum.Material.Metal },
			{ name = "Collar", size = Vector3.new(0.32, 0.4, 0.32), offset = CFrame.new(0, 4.4, 0), color = BRASS, material = Enum.Material.Metal },
			{ name = "Head", size = Vector3.new(0.26, 1.4, 0.09), offset = CFrame.new(0, 5.2, 0), color = BONE, material = Enum.Material.Marble },
			{ name = "WingLeft", size = Vector3.new(0.5, 0.3, 0.08), offset = CFrame.new(-0.3, 4.7, 0), color = BONE, material = Enum.Material.Marble },
			{ name = "WingRight", size = Vector3.new(0.5, 0.3, 0.08), offset = CFrame.new(0.3, 4.7, 0), color = BONE, material = Enum.Material.Marble },
			{ name = "Tip", size = Vector3.new(0.26, 0.6, 0.09), offset = CFrame.new(0, 6.1, 0), color = BONE, material = Enum.Material.Marble, wedge = true },
		},
	},
}

--------------------------------------------------------------------------------
-- Weapons
--------------------------------------------------------------------------------

WeaponConfig.Weapons = {} :: { [string]: Weapon }

--[[
	VIGIL — the honest option.

	Four-hit chain with real cancel windows, a heavy that is worth committing to,
	and an ability that rewards standing still at exactly the wrong moment. It is
	the weapon that teaches the game: everything Vigil does, another weapon does
	more of and worse.
]]
WeaponConfig.Weapons.Vigil = {
	id = "Vigil",
	displayName = "VIGIL",
	subtitle = "the Longsword That Waited",
	archetype = "Longsword",
	description = "A gatekeeper's sword. Balanced, unhurried, and entirely without opinions "
		.. "about how you use it.",
	playstyle = "Reliable four-hit chains with generous cancels. Forgiving without being safe.",
	strengths = { "Fast recovery on the first two swings", "Best parry follow-up in the game", "No bad matchup" },
	weaknesses = { "No standout damage ceiling", "Short reach against grouped enemies" },
	unlockedByDefault = true,
	unlockCost = 0,
	tags = { "Sword", "Balanced", "Medium" },
	stats = {
		baseDamage = 15,
		reach = 9.5,
		moveSpeedMultiplier = 1.0,
		staminaCostMultiplier = 1.0,
		poise = 1.0,
	},
	model = WeaponConfig.Models.Vigil,
	dodgeStyle = "Roll",

	lightCombo = {
		{
			clip = "Vigil_Light1",
			windup = 0.14, active = 0.10, recovery = 0.20,
			damage = 1.0, poise = 12, knockback = 6,
			hitbox = { shape = "Arc", range = 9.5, angle = 120, height = 7, offset = Vector3.new(0, 0, -1) },
			motion = { distance = 3.5, duration = 0.16 },
			cancel = { light = 0.40, heavy = 0.40, dodge = 0.20, ability = 0.40 },
			hitStop = 0.045,
			camera = { shake = 0.35, fovKick = 0.8 },
			sfx = "SwingLight", vfxImpact = "Slash",
		},
		{
			clip = "Vigil_Light2",
			windup = 0.13, active = 0.10, recovery = 0.19,
			damage = 1.05, poise = 12, knockback = 6,
			hitbox = { shape = "Arc", range = 9.5, angle = 130, height = 7, offset = Vector3.new(0, 0, -1) },
			motion = { distance = 3.2, duration = 0.15 },
			cancel = { light = 0.38, heavy = 0.38, dodge = 0.20, ability = 0.38 },
			hitStop = 0.045,
			camera = { shake = 0.35, fovKick = 0.8 },
			sfx = "SwingLight", vfxImpact = "Slash",
		},
		{
			clip = "Vigil_Light3",
			windup = 0.20, active = 0.11, recovery = 0.21,
			damage = 1.35, poise = 20, knockback = 11,
			hitbox = { shape = "Arc", range = 10, angle = 95, height = 8, offset = Vector3.new(0, 0, -1.5) },
			motion = { distance = 4.5, duration = 0.2 },
			cancel = { light = 0.50, heavy = 0.50, dodge = 0.30 },
			hitStop = 0.07,
			camera = { shake = 0.6, fovKick = 1.4 },
			sfx = "SwingMedium", vfxImpact = "SlashHeavy",
		},
		{
			clip = "Vigil_Light4",
			windup = 0.18, active = 0.20, recovery = 0.28,
			damage = 1.7, poise = 30, knockback = 16,
			hitbox = { shape = "Sphere", range = 11, height = 8, maxTargets = 8 },
			motion = { distance = 5, duration = 0.28 },
			cancel = { dodge = 0.45 },
			hitStop = 0.09,
			camera = { shake = 0.9, fovKick = 2.2 },
			sfx = "SwingHeavy", vfxImpact = "SlashSpin",
			tags = { "IsSpin", "IsFinal" },
		},
	},

	heavy = {
		clip = "Vigil_Heavy",
		windup = 0.34, active = 0.14, recovery = 0.38,
		damage = 2.4, poise = 45, knockback = 22,
		hitbox = { shape = "Arc", range = 11, angle = 100, height = 9, offset = Vector3.new(0, 0, -2) },
		motion = { distance = 6, duration = 0.3 },
		cancel = { dodge = 0.50 },
		hitStop = 0.11,
		camera = { shake = 1.2, fovKick = 3 },
		sfx = "SwingHeavy", vfxImpact = "SlashHeavy",
		tags = { "IsHeavy" },
	},

	ability = {
		id = "HoldTheLine",
		name = "HOLD THE LINE",
		description = "Plant and thrust. While the thrust is out you take 60% less damage — "
			.. "and anything that hits you during it is opened up.",
		cooldown = 7,
		staminaCost = 15,
		swing = {
			clip = "Vigil_Ability",
			windup = 0.16, active = 0.10, recovery = 0.24,
			damage = 1.9, poise = 34, knockback = 4,
			hitbox = { shape = "Box", range = 13, width = 3, height = 6, offset = Vector3.new(0, 0, -4) },
			motion = { distance = 2, duration = 0.12 },
			hitStop = 0.08,
			camera = { shake = 0.7, fovKick = 2 },
			sfx = "AbilityVigil", vfxImpact = "Pierce",
			tags = { "IsThrust", "IsAbility" },
		},
		-- Applied to the user for the duration of windup + active.
		selfEffect = { damageReduction = 0.6, counterWindow = true },
	},

	ultimate = {
		id = "VigilUnbroken",
		name = "UNBROKEN",
		description = "Three rotations, widening. Every enemy struck returns 4% of your "
			.. "missing health.",
		cost = 100,
		swing = {
			clip = "Vigil_Ultimate",
			windup = 0.30, active = 0.45, recovery = 0.40,
			damage = 3.6, poise = 90, knockback = 26,
			hitbox = { shape = "Sphere", range = 16, height = 10, maxTargets = 12 },
			motion = { distance = 4, duration = 0.5 },
			hitStop = 0.06,
			camera = { shake = 1.6, fovKick = 5 },
			sfx = "UltimateVigil", vfxImpact = "SlashSpin",
			tags = { "IsSpin", "IsUltimate" },
		},
		-- Ticks damage repeatedly across the active window instead of once.
		multiHit = { ticks = 3, interval = 0.15 },
		lifestealMissingHealth = 0.04,
		invulnerable = true,
	},

	finisher = {
		clip = "Vigil_Finisher",
		duration = 0.85,
		damageMultiplier = 6,
		camera = { shake = 1.4, fovKick = -6 },
		description = "A single thrust through the chest, then a shove off the blade.",
	},

	tempers = {
		{
			id = "Vigil_Warden",
			name = "WARDEN'S TEMPER",
			description = "Heavy attacks gain a second, wider shockwave. Light chain loses its "
				.. "fourth swing.",
			cost = 350,
			requiresMastery = 5,
			modifiers = { heavyDamage = 1.15, heavyShockwave = true, comboLength = 3 },
		},
		{
			id = "Vigil_Quick",
			name = "QUICK TEMPER",
			description = "Every cancel window opens 40% earlier. All damage down 12%.",
			cost = 350,
			requiresMastery = 10,
			modifiers = { cancelScale = 0.6, damageScale = 0.88 },
		},
		{
			id = "Vigil_Riposte",
			name = "RIPOSTE TEMPER",
			description = "Perfect parries refund your ability instantly and the follow-up "
				.. "attack crits.",
			cost = 600,
			requiresMastery = 15,
			modifiers = { parryRefundAbility = true, parryFollowupCrit = true },
		},
	},
}

--[[
	GRUDGE — the commitment weapon.

	Three swings, all slow, all with real recovery you cannot cancel out of. The
	payoff is stagger: Grudge builds poise damage roughly 2.5x faster than Vigil,
	so it turns crowds into a sequence of free hits rather than a threat.
]]
WeaponConfig.Weapons.Grudge = {
	id = "Grudge",
	displayName = "GRUDGE",
	subtitle = "the Axe of Slow Answers",
	archetype = "Great Axe",
	description = "Two-handed and unapologetic. Every swing is a decision you have to live "
		.. "inside of for another half second.",
	playstyle = "Slow, enormous, stagger-focused. You do not dodge out of mistakes; you "
		.. "avoid making them.",
	strengths = { "Highest stagger in the game", "Huge arcs hit whole groups", "Uninterruptible heavy" },
	weaknesses = { "Punishing recovery", "Slowest movement", "Hard to reposition mid-combo" },
	unlockedByDefault = false,
	unlockCost = 400,
	tags = { "Axe", "Heavy", "Slow", "Cleave" },
	stats = {
		baseDamage = 26,
		reach = 12,
		moveSpeedMultiplier = 0.88,
		staminaCostMultiplier = 1.25,
		poise = 1.6,
	},
	model = WeaponConfig.Models.Grudge,
	dodgeStyle = "Lunge",

	lightCombo = {
		{
			clip = "Grudge_Light1",
			windup = 0.22, active = 0.12, recovery = 0.28,
			damage = 1.0, poise = 30, knockback = 14,
			hitbox = { shape = "Arc", range = 12, angle = 150, height = 8, offset = Vector3.new(0, 0, -1) },
			motion = { distance = 3, duration = 0.2 },
			cancel = { dodge = 0.50 },
			hitStop = 0.08,
			camera = { shake = 0.7, fovKick = 1.6 },
			sfx = "SwingHeavy", vfxImpact = "Cleave",
		},
		{
			clip = "Grudge_Light2",
			windup = 0.28, active = 0.12, recovery = 0.32,
			damage = 1.2, poise = 36, knockback = 18,
			hitbox = { shape = "Arc", range = 12, angle = 110, height = 10, offset = Vector3.new(0, 0, -1.5) },
			motion = { distance = 4, duration = 0.24 },
			cancel = { dodge = 0.55 },
			hitStop = 0.1,
			camera = { shake = 0.9, fovKick = 2.1 },
			sfx = "SwingHeavy", vfxImpact = "Cleave",
		},
		{
			clip = "Grudge_Light3",
			windup = 0.30, active = 0.14, recovery = 0.34,
			damage = 1.55, poise = 48, knockback = 26,
			hitbox = { shape = "Arc", range = 13, angle = 170, height = 9, offset = Vector3.new(0, 0, -1) },
			motion = { distance = 5, duration = 0.3 },
			cancel = { dodge = 0.60 },
			hitStop = 0.12,
			camera = { shake = 1.2, fovKick = 2.8 },
			sfx = "SwingHeavy", vfxImpact = "CleaveHeavy",
			tags = { "IsFinal" },
		},
	},

	heavy = {
		clip = "Grudge_Heavy",
		windup = 0.48, active = 0.16, recovery = 0.48,
		damage = 3.2, poise = 90, knockback = 34,
		hitbox = { shape = "Sphere", range = 14, height = 9, maxTargets = 10 },
		motion = { distance = 5, duration = 0.4 },
		cancel = { dodge = 0.65 },
		hitStop = 0.16,
		camera = { shake = 2, fovKick = 4 },
		sfx = "GroundSlam", vfxImpact = "Shockwave",
		-- Grudge's heavy cannot be interrupted once the windup is past halfway.
		superArmorFrom = 0.24,
		tags = { "IsHeavy", "IsSlam", "IsGround" },
	},

	ability = {
		id = "Reap",
		name = "REAP",
		description = "One full rotation that drags everything it touches toward you, then "
			.. "leaves them staggered.",
		cooldown = 11,
		staminaCost = 25,
		swing = {
			clip = "Grudge_Ability",
			windup = 0.30, active = 0.30, recovery = 0.35,
			damage = 1.8, poise = 70, knockback = 0, pull = 22,
			hitbox = { shape = "Sphere", range = 18, height = 10, maxTargets = 12 },
			hitStop = 0.05,
			camera = { shake = 1.1, fovKick = 3 },
			sfx = "AbilityGrudge", vfxImpact = "Vortex",
			tags = { "IsSpin", "IsAbility" },
		},
		selfEffect = { superArmor = true },
	},

	ultimate = {
		id = "GrudgeSettled",
		name = "SETTLED",
		description = "One overhead. It leaves a crater that keeps burning, and anything "
			.. "already staggered takes triple.",
		cost = 100,
		swing = {
			clip = "Grudge_Ultimate",
			windup = 0.55, active = 0.20, recovery = 0.65,
			damage = 7.5, poise = 200, knockback = 46,
			hitbox = { shape = "Sphere", range = 20, height = 12, maxTargets = 16 },
			motion = { distance = 6, duration = 0.5 },
			hitStop = 0.24,
			camera = { shake = 3, fovKick = 8 },
			sfx = "UltimateGrudge", vfxImpact = "Crater",
			tags = { "IsSlam", "IsUltimate", "IsGround" },
		},
		staggeredBonusMultiplier = 3,
		lingeringZone = { duration = 6, tickInterval = 0.5, damagePerTick = 0.4, radius = 16 },
		invulnerable = true,
	},

	finisher = {
		clip = "Grudge_Finisher",
		duration = 1.0,
		damageMultiplier = 8,
		camera = { shake = 2.2, fovKick = -8 },
		description = "One overhead, straight down. There is no second part.",
	},

	tempers = {
		{
			id = "Grudge_Momentum",
			name = "MOMENTUM TEMPER",
			description = "Each connected swing in a chain adds 18% damage to the next. "
				.. "Missing resets it to zero.",
			cost = 400,
			requiresMastery = 5,
			modifiers = { chainDamageStack = 0.18, resetOnMiss = true },
		},
		{
			id = "Grudge_Bulwark",
			name = "BULWARK TEMPER",
			description = "Super armour on every swing, not just the heavy. Movement speed "
				.. "down another 10%.",
			cost = 450,
			requiresMastery = 10,
			modifiers = { superArmorAll = true, moveSpeedScale = 0.9 },
		},
		{
			id = "Grudge_Landslide",
			name = "LANDSLIDE TEMPER",
			description = "Slams leave a shockwave that travels. Heavy costs 40% more stamina.",
			cost = 700,
			requiresMastery = 15,
			modifiers = { travellingShockwave = true, heavyStaminaScale = 1.4 },
		},
	},
}

--[[
	QUARREL — the tempo weapon.

	Five swings, each under a third of a second, cancellable into each other almost
	immediately. Individually the hits are nearly worthless; the weapon lives or
	dies on staying attached to a target for the whole chain. Damage is back-loaded
	into swings four and five specifically so that bailing out early is a real loss.
]]
WeaponConfig.Weapons.Quarrel = {
	id = "Quarrel",
	displayName = "QUARREL",
	subtitle = "the Paired Knives",
	archetype = "Twin Blades",
	description = "Two short blades that were forged arguing and have not stopped. "
		.. "Almost no reach, almost no recovery.",
	playstyle = "Extreme speed and mobility. Damage is back-loaded — you have to finish "
		.. "what you start.",
	strengths = { "Fastest chain and cancels", "Highest mobility", "Best air game" },
	weaknesses = { "Terrible reach", "Low per-hit damage", "Punished hard by armoured enemies" },
	unlockedByDefault = false,
	unlockCost = 400,
	tags = { "Dagger", "Fast", "Mobile", "Dual" },
	stats = {
		baseDamage = 7,
		reach = 7,
		moveSpeedMultiplier = 1.12,
		staminaCostMultiplier = 0.8,
		poise = 0.6,
	},
	model = WeaponConfig.Models.Quarrel,
	dodgeStyle = "Dash",

	lightCombo = {
		{
			clip = "Quarrel_Light1",
			windup = 0.07, active = 0.07, recovery = 0.12,
			damage = 0.85, poise = 5, knockback = 2,
			hitbox = { shape = "Arc", range = 7, angle = 100, height = 6 },
			motion = { distance = 2.5, duration = 0.1 },
			cancel = { light = 0.12, heavy = 0.12, dodge = 0.08, ability = 0.12 },
			hitStop = 0.02,
			camera = { shake = 0.18, fovKick = 0.3 },
			sfx = "SwingFast", vfxImpact = "Nick",
		},
		{
			clip = "Quarrel_Light2",
			windup = 0.06, active = 0.07, recovery = 0.11,
			damage = 0.85, poise = 5, knockback = 2,
			hitbox = { shape = "Arc", range = 7, angle = 100, height = 6 },
			motion = { distance = 2.5, duration = 0.1 },
			cancel = { light = 0.12, heavy = 0.12, dodge = 0.08, ability = 0.12 },
			hitStop = 0.02,
			camera = { shake = 0.18, fovKick = 0.3 },
			sfx = "SwingFast", vfxImpact = "Nick",
		},
		{
			clip = "Quarrel_Light3",
			windup = 0.07, active = 0.07, recovery = 0.12,
			damage = 1.0, poise = 6, knockback = 3,
			hitbox = { shape = "Box", range = 8, width = 2, height = 5, offset = Vector3.new(0, 0, -2) },
			motion = { distance = 3.5, duration = 0.1 },
			cancel = { light = 0.12, heavy = 0.12, dodge = 0.08, ability = 0.12 },
			hitStop = 0.025,
			camera = { shake = 0.2, fovKick = 0.4 },
			sfx = "SwingFast", vfxImpact = "Pierce",
			tags = { "IsThrust" },
		},
		{
			clip = "Quarrel_Light4",
			windup = 0.07, active = 0.07, recovery = 0.12,
			damage = 1.3, poise = 7, knockback = 4,
			hitbox = { shape = "Arc", range = 7.5, angle = 120, height = 6 },
			motion = { distance = 3, duration = 0.1 },
			cancel = { light = 0.14, heavy = 0.14, dodge = 0.08 },
			hitStop = 0.03,
			camera = { shake = 0.3, fovKick = 0.6 },
			sfx = "SwingFast", vfxImpact = "Nick",
		},
		{
			clip = "Quarrel_Light5",
			windup = 0.10, active = 0.16, recovery = 0.18,
			damage = 2.2, poise = 18, knockback = 12,
			hitbox = { shape = "Sphere", range = 9, height = 7, maxTargets = 6 },
			motion = { distance = 4, duration = 0.2 },
			cancel = { dodge = 0.30 },
			hitStop = 0.06,
			camera = { shake = 0.7, fovKick = 1.6 },
			sfx = "SwingSpin", vfxImpact = "SlashSpin",
			tags = { "IsSpin", "IsFinal" },
		},
	},

	heavy = {
		clip = "Quarrel_Heavy",
		windup = 0.18, active = 0.12, recovery = 0.26,
		damage = 1.6, poise = 22, knockback = 6, launch = 34,
		hitbox = { shape = "Arc", range = 7.5, angle = 90, height = 8, offset = Vector3.new(0, 1, -1) },
		motion = { distance = 2, duration = 0.14 },
		cancel = { light = 0.25, dodge = 0.15, ability = 0.25 },
		hitStop = 0.07,
		camera = { shake = 0.6, fovKick = 1.5 },
		sfx = "SwingUppercut", vfxImpact = "Launch",
		-- Launchers exist so the air combo is reachable without a jump input.
		tags = { "IsHeavy", "IsLauncher" },
	},

	ability = {
		id = "SplitSecond",
		name = "SPLIT SECOND",
		description = "Vanish forward through everything in a line. The cuts land when you "
			.. "arrive, all at once.",
		cooldown = 6,
		staminaCost = 20,
		swing = {
			clip = "Quarrel_Ability",
			windup = 0.08, active = 0.14, recovery = 0.28,
			damage = 2.4, poise = 30, knockback = 8,
			hitbox = { shape = "Box", range = 26, width = 4, height = 7, offset = Vector3.new(0, 0, -13) },
			motion = { distance = 26, duration = 0.16, direction = "Input" },
			hitStop = 0.09,
			camera = { shake = 0.8, fovKick = -4 },
			sfx = "AbilityQuarrel", vfxImpact = "PhaseCut",
			tags = { "IsAbility", "IsDash" },
		},
		selfEffect = { invulnerable = true, phaseThrough = true },
	},

	ultimate = {
		id = "QuarrelSettled",
		name = "THE ARGUMENT ENDS",
		description = "You stop being in one place. Everything nearby is cut eleven times.",
		cost = 100,
		swing = {
			clip = "Quarrel_Ultimate",
			windup = 0.20, active = 0.55, recovery = 0.25,
			damage = 0.85, poise = 12, knockback = 3,
			hitbox = { shape = "Sphere", range = 14, height = 9, maxTargets = 10 },
			hitStop = 0.015,
			camera = { shake = 0.5, fovKick = 3 },
			sfx = "UltimateQuarrel", vfxImpact = "Nick",
			tags = { "IsSpin", "IsUltimate" },
		},
		multiHit = { ticks = 11, interval = 0.05 },
		invulnerable = true,
	},

	finisher = {
		clip = "Quarrel_Finisher",
		duration = 0.7,
		damageMultiplier = 5,
		hits = 6,
		camera = { shake = 0.9, fovKick = -4 },
		description = "Six cuts in the time it takes to fall over once.",
	},

	tempers = {
		{
			id = "Quarrel_Bleed",
			name = "BLEEDING TEMPER",
			description = "Every fifth hit on the same target bleeds it for 8% of its max "
				.. "health over 4s.",
			cost = 400,
			requiresMastery = 5,
			modifiers = { bleedEveryNHits = 5, bleedPercent = 0.08 },
		},
		{
			id = "Quarrel_Airborne",
			name = "AIRBORNE TEMPER",
			description = "The chain continues in mid-air and does 25% more there. Ground "
				.. "damage down 8%.",
			cost = 450,
			requiresMastery = 10,
			modifiers = { airDamageScale = 1.25, groundDamageScale = 0.92, airCombo = true },
		},
		{
			id = "Quarrel_Twinned",
			name = "TWINNED TEMPER",
			description = "Split Second leaves an afterimage that repeats the attack one "
				.. "second later.",
			cost = 700,
			requiresMastery = 15,
			modifiers = { abilityEcho = 1.0 },
		},
	},
}

--[[
	THRESH — the spacing weapon.

	Reach is the whole design. Thresh out-ranges every basic enemy attack in the
	game by a comfortable margin, so a good Thresh player is never in the danger
	zone at all. Its punishment for being caught close is severe: the shortest
	arc and the lowest poise of any weapon.
]]
WeaponConfig.Weapons.Thresh = {
	id = "Thresh",
	displayName = "THRESH",
	subtitle = "the Reaching Spear",
	archetype = "Spear",
	description = "Built for keeping things at the distance where they cannot argue with "
		.. "you. Useless once they have crossed it.",
	playstyle = "Range control. You win by never being where the enemy attack is.",
	strengths = { "Longest reach by far", "Thrown attacks", "Safe pokes on every boss" },
	weaknesses = { "Very narrow arcs", "Lowest poise", "Helpless in a crowd at close range" },
	unlockedByDefault = false,
	unlockCost = 400,
	tags = { "Spear", "Reach", "Precise" },
	stats = {
		baseDamage = 13,
		reach = 16,
		moveSpeedMultiplier = 1.04,
		staminaCostMultiplier = 0.9,
		poise = 0.75,
	},
	model = WeaponConfig.Models.Thresh,
	dodgeStyle = "Vault",

	lightCombo = {
		{
			clip = "Thresh_Light1",
			windup = 0.12, active = 0.08, recovery = 0.16,
			damage = 1.0, poise = 9, knockback = 5,
			hitbox = { shape = "Box", range = 16, width = 1.8, height = 5, offset = Vector3.new(0, 0, -7) },
			motion = { distance = 3, duration = 0.12 },
			cancel = { light = 0.30, heavy = 0.30, dodge = 0.18, ability = 0.30 },
			hitStop = 0.04,
			camera = { shake = 0.3, fovKick = 0.7 },
			sfx = "SwingPierce", vfxImpact = "Pierce",
			tags = { "IsThrust" },
		},
		{
			clip = "Thresh_Light2",
			windup = 0.11, active = 0.08, recovery = 0.15,
			damage = 1.1, poise = 9, knockback = 5,
			hitbox = { shape = "Box", range = 16.5, width = 1.8, height = 5, offset = Vector3.new(0, 0, -7.5) },
			motion = { distance = 3, duration = 0.12 },
			cancel = { light = 0.30, heavy = 0.30, dodge = 0.18, ability = 0.30 },
			hitStop = 0.04,
			camera = { shake = 0.3, fovKick = 0.7 },
			sfx = "SwingPierce", vfxImpact = "Pierce",
			tags = { "IsThrust" },
		},
		{
			clip = "Thresh_Light3",
			windup = 0.17, active = 0.10, recovery = 0.23,
			damage = 1.5, poise = 24, knockback = 18,
			hitbox = { shape = "Arc", range = 14, angle = 160, height = 6 },
			motion = { distance = 2, duration = 0.16 },
			cancel = { dodge = 0.35 },
			hitStop = 0.07,
			camera = { shake = 0.7, fovKick = 1.5 },
			sfx = "SwingMedium", vfxImpact = "Slash",
			tags = { "IsFinal", "IsSweep" },
		},
	},

	heavy = {
		clip = "Thresh_Heavy",
		windup = 0.30, active = 0.12, recovery = 0.30,
		damage = 2.6, poise = 40, knockback = 24,
		hitbox = { shape = "Box", range = 24, width = 2.4, height = 6, offset = Vector3.new(0, 0, -11) },
		motion = { distance = 11, duration = 0.24 },
		cancel = { dodge = 0.50 },
		hitStop = 0.1,
		camera = { shake = 1, fovKick = -3 },
		sfx = "SwingLunge", vfxImpact = "PierceHeavy",
		-- Pierces: a Box hitbox with pierce hits everything along its length.
		pierce = true,
		tags = { "IsHeavy", "IsThrust" },
	},

	ability = {
		id = "Cast",
		name = "CAST",
		description = "Throw it. It pins the first thing it hits and keeps hurting until you "
			.. "call it back — which yanks you to it.",
		cooldown = 9,
		staminaCost = 18,
		swing = {
			clip = "Thresh_Ability",
			windup = 0.16, active = 0.06, recovery = 0.20,
			damage = 2.2, poise = 40, knockback = 0,
			hitbox = { shape = "Box", range = 4, width = 2, height = 4, offset = Vector3.new(0, 0, -2) },
			hitStop = 0.05,
			camera = { shake = 0.5, fovKick = 1 },
			sfx = "AbilityThresh", vfxImpact = "Pierce",
			tags = { "IsAbility", "IsThrown" },
		},
		projectile = {
			speed = 120,
			maxRange = 90,
			radius = 1.6,
			pinDuration = 4,
			tickDamage = 0.35,
			tickInterval = 0.5,
			-- Second activation recalls: pulls the player to the spear.
			recallPullsUser = true,
			recallDamage = 1.6,
		},
	},

	ultimate = {
		id = "ThreshHarvest",
		name = "HARVEST",
		description = "Every spear you have ever thrown comes back at once, into a circle "
			.. "you choose.",
		cost = 100,
		swing = {
			clip = "Thresh_Ultimate",
			windup = 0.30, active = 0.30, recovery = 0.30,
			damage = 1.4, poise = 40, knockback = 10,
			hitbox = { shape = "Sphere", range = 20, height = 12, maxTargets = 14 },
			hitStop = 0.04,
			camera = { shake = 1.4, fovKick = 4 },
			sfx = "UltimateThresh", vfxImpact = "Rain",
			tags = { "IsUltimate", "IsRanged" },
		},
		multiHit = { ticks = 8, interval = 0.09 },
		invulnerable = true,
	},

	finisher = {
		clip = "Thresh_Finisher",
		duration = 0.9,
		damageMultiplier = 6,
		camera = { shake = 1.2, fovKick = -5 },
		description = "Impale, lift, and throw the body at whatever is behind it.",
		throwsCorpse = true,
	},

	tempers = {
		{
			id = "Thresh_Longreach",
			name = "LONGREACH TEMPER",
			description = "All thrusts gain 25% range. Sweeps lose 30% of their arc.",
			cost = 400,
			requiresMastery = 5,
			modifiers = { thrustRangeScale = 1.25, sweepAngleScale = 0.7 },
		},
		{
			id = "Thresh_Tether",
			name = "TETHER TEMPER",
			description = "Cast can hold two spears at once, and recalling either pulls both.",
			cost = 450,
			requiresMastery = 10,
			modifiers = { maxThrownSpears = 2 },
		},
		{
			id = "Thresh_Volley",
			name = "VOLLEY TEMPER",
			description = "Every third thrust fires a spectral copy of itself, at full range.",
			cost = 700,
			requiresMastery = 15,
			modifiers = { phantomThrustEvery = 3 },
		},
	},
}

--------------------------------------------------------------------------------
-- Accessors
--------------------------------------------------------------------------------

WeaponConfig.Order = { "Vigil", "Grudge", "Quarrel", "Thresh" }

function WeaponConfig.Get(weaponId: string): Weapon?
	return WeaponConfig.Weapons[weaponId]
end

function WeaponConfig.GetOrDefault(weaponId: string?): Weapon
	return WeaponConfig.Weapons[weaponId or ""] or WeaponConfig.Weapons.Vigil
end

--- Total wall-clock length of a swing, used for both server timing and the client's
--- predicted animation.
function WeaponConfig.SwingDuration(swing: Swing): number
	return swing.windup + swing.active + swing.recovery
end

--[[
	Earliest time (measured from the start of the swing) at which `action` may
	interrupt this swing, or nil if it cannot.

	`cancel` values are the fraction of the recovery phase that must elapse first,
	so 0 means "the instant the hitbox closes" and 1 means "not at all". Expressed
	this way the numbers survive retuning a swing's duration, and they read as the
	thing a designer actually cares about: how much of the commitment you get back.
]]
function WeaponConfig.CancelTime(swing: Swing, action: string, scale: number?): number?
	local cancel = swing.cancel
	if not cancel then
		return nil
	end
	local fraction = cancel[action]
	if not fraction then
		return nil
	end
	-- Tempers such as Vigil's QUICK can scale every window at once.
	fraction = math.clamp(fraction * (scale or 1), 0, 1)
	return swing.windup + swing.active + swing.recovery * fraction
end

--[[
	Validates that every swing's phases line up with its animation clip. A mismatch
	is invisible in code review and extremely obvious in play (the blade passes
	through the enemy before or after the damage lands), so it is checked at boot.
	Returns a list of human-readable problems; empty means healthy.
]]
function WeaponConfig.Validate(): { string }
	local problems = {}

	local function checkSwing(weaponId: string, label: string, swing: Swing?)
		if not swing then
			return
		end
		local total = WeaponConfig.SwingDuration(swing)
		local clipLength = PoseLibrary.Duration(swing.clip)
		if not PoseLibrary.Get(swing.clip) then
			table.insert(problems, ("%s/%s references missing clip %q"):format(weaponId, label, swing.clip))
			return
		end
		if math.abs(total - clipLength) > 0.035 then
			table.insert(
				problems,
				("%s/%s timing %.3fs does not match clip %q (%.3fs)")
					:format(weaponId, label, total, swing.clip, clipLength)
			)
		end
		if swing.hitbox.shape == "Arc" and not swing.hitbox.angle then
			table.insert(problems, ("%s/%s Arc hitbox is missing an angle"):format(weaponId, label))
		end
		if swing.hitbox.shape == "Box" and not swing.hitbox.width then
			table.insert(problems, ("%s/%s Box hitbox is missing a width"):format(weaponId, label))
		end
	end

	for weaponId, weapon in WeaponConfig.Weapons do
		for index, swing in weapon.lightCombo do
			checkSwing(weaponId, "light" .. index, swing)
		end
		checkSwing(weaponId, "heavy", weapon.heavy)
		checkSwing(weaponId, "ability", weapon.ability and weapon.ability.swing)
		checkSwing(weaponId, "ultimate", weapon.ultimate and weapon.ultimate.swing)

		if not weapon.model then
			table.insert(problems, weaponId .. " has no model spec")
		end
	end

	return problems
end

return WeaponConfig
