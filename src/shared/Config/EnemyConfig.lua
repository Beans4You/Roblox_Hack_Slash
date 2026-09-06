--!strict
--[[
	EnemyConfig — the eight enemies, and the modifiers that make elites.

	The brief asks for eight excellent enemies over fifty mediocre ones, so each
	entry here is built around exactly one question the player has to answer:

	  Marchman   can you keep a combo going while something interrupts you?
	  Cutter     can you punish something faster than you?
	  Bulwark    can you get around a front?
	  Fletcher   are you willing to leave the melee to deal with it?
	  Drudge     can you stay patient through a long telegraph?
	  Vesper     can you fight something you cannot reach on the ground?
	  Censer     can you kill something without being next to it?
	  Tallier    all of the above, at once, on a timer.

	READING AN ATTACK
	`telegraph` is how long before the hitbox opens the warning appears. It is a
	slice of `windup`, not extra time -- an attack with windup 0.46 and telegraph
	0.34 shows its tell 0.12s after the animation starts. Bigger, slower enemies
	get longer telegraphs; that is the entire difficulty curve of this game.
]]

local PoseLibrary = require(script.Parent.PoseLibrary)

export type EnemyAttack = {
	id: string,
	clip: string,
	telegraph: number,
	windup: number,
	active: number,
	recovery: number,
	damage: number,
	poiseDamage: number,
	knockback: number,
	hitbox: any,
	-- Range band in which the AI will consider this attack at all.
	minRange: number,
	maxRange: number,
	cooldown: number,
	-- Relative likelihood when several attacks are legal.
	weight: number,
	-- The enemy cannot be staggered out of the attack past this point in windup.
	superArmorFrom: number?,
	-- Movement baked into the attack, e.g. a lunge.
	motion: { distance: number, duration: number }?,
	projectile: any?,
	applies: string?,
	telegraphShape: ("Cone" | "Line" | "Circle")?,
	sfx: string?,
}

export type Enemy = {
	id: string,
	displayName: string,
	role: string,
	threat: string,
	tier: "Grunt" | "Elite" | "MiniBoss",
	rig: any,
	stats: {
		maxHealth: number,
		damageScale: number,
		walkSpeed: number,
		chaseSpeed: number,
		-- Stagger required to break the enemy out of what it is doing.
		poiseThreshold: number,
		detectionRange: number,
		-- 0 hangs back and waits for an opening, 1 commits constantly.
		aggression: number,
		-- Multiplier on knockback and launch received.
		weight: number,
	},
	behavior: {
		archetype: "Melee" | "Ranged" | "Charger" | "Flyer" | "Exploder" | "Guard",
		preferredRange: number,
		-- Bias toward circling (1) versus closing straight in (0).
		strafeBias: number,
		-- Seconds it will hold position waiting for an attack token.
		patience: number,
		flying: boolean?,
		hoverHeight: number?,
		-- Refuses to be interrupted while walking; used by shielded enemies.
		blocksFrontal: number?,
		primesOnApproach: { startDistance: number, pulseRate: number }?,
	},
	attacks: { EnemyAttack },
	onDeath: any?,
	rewards: { motes: number, ultimateCharge: number? },
	regions: { string },
}

local EnemyConfig = {}

--------------------------------------------------------------------------------
-- Palettes, shared so a region reads as one army.
--------------------------------------------------------------------------------

local DROWNED = {
	primary = Color3.fromRGB(58, 74, 82),
	secondary = Color3.fromRGB(38, 50, 58),
	accent = Color3.fromRGB(120, 220, 210),
	eye = Color3.fromRGB(150, 245, 235),
}

local ASHEN = {
	primary = Color3.fromRGB(74, 52, 46),
	secondary = Color3.fromRGB(46, 32, 30),
	accent = Color3.fromRGB(255, 122, 48),
	eye = Color3.fromRGB(255, 168, 88),
}

local RIMEBOUND = {
	primary = Color3.fromRGB(96, 116, 134),
	secondary = Color3.fromRGB(64, 82, 100),
	accent = Color3.fromRGB(170, 226, 255),
	eye = Color3.fromRGB(214, 244, 255),
}

EnemyConfig.Palettes = { Drowned = DROWNED, Ashen = ASHEN, Rimebound = RIMEBOUND }

--------------------------------------------------------------------------------
-- Enemies
--------------------------------------------------------------------------------

EnemyConfig.Enemies = {} :: { [string]: Enemy }
local E = EnemyConfig.Enemies

E.Marchman = {
	id = "Marchman",
	displayName = "MARCHMAN",
	role = "Line infantry",
	threat = "Interrupts your combo if you ignore it. Individually trivial, in threes it "
		.. "is a real fight.",
	tier = "Grunt",
	rig = { scale = 1.0, palette = DROWNED, silhouette = { "pauldrons", "tatters" }, material = Enum.Material.Slate },
	stats = {
		maxHealth = 70,
		damageScale = 1.0,
		walkSpeed = 11,
		chaseSpeed = 16,
		poiseThreshold = 30,
		detectionRange = 55,
		aggression = 0.55,
		weight = 1.0,
	},
	behavior = { archetype = "Melee", preferredRange = 7, strafeBias = 0.45, patience = 1.6 },
	attacks = {
		{
			id = "Cleave",
			clip = "Enemy_Swing",
			telegraph = 0.34, windup = 0.34, active = 0.12, recovery = 0.26,
			damage = 11, poiseDamage = 18, knockback = 10,
			hitbox = { shape = "Arc", range = 8, angle = 110, height = 6 },
			minRange = 0, maxRange = 8.5, cooldown = 2.1, weight = 3,
			telegraphShape = "Cone", sfx = "EnemySwing",
		},
		{
			id = "StepIn",
			clip = "Enemy_Thrust",
			telegraph = 0.28, windup = 0.28, active = 0.10, recovery = 0.24,
			damage = 9, poiseDamage = 14, knockback = 8,
			hitbox = { shape = "Box", range = 11, width = 2, height = 5, offset = Vector3.new(0, 0, -5) },
			minRange = 5, maxRange = 12, cooldown = 3.0, weight = 2,
			motion = { distance = 6, duration = 0.24 },
			telegraphShape = "Line", sfx = "EnemyThrust",
		},
	},
	rewards = { motes = 4, ultimateCharge = 3 },
	regions = { "SunkenMarch", "CinderReach", "RimefastSanctum" },
}

E.Cutter = {
	id = "Cutter",
	displayName = "CUTTER",
	role = "Assassin",
	threat = "Closes faster than you can turn. The answer is the dodge, not the block.",
	tier = "Grunt",
	rig = { scale = 0.88, palette = DROWNED, silhouette = { "cloak" }, material = Enum.Material.Slate },
	stats = {
		maxHealth = 42,
		damageScale = 0.85,
		walkSpeed = 17,
		chaseSpeed = 26,
		poiseThreshold = 14,
		detectionRange = 70,
		aggression = 0.9,
		weight = 0.7,
	},
	behavior = { archetype = "Charger", preferredRange = 12, strafeBias = 0.75, patience = 0.7 },
	attacks = {
		{
			id = "Lunge",
			clip = "Enemy_Lunge",
			telegraph = 0.24, windup = 0.24, active = 0.10, recovery = 0.20,
			damage = 13, poiseDamage = 10, knockback = 6,
			hitbox = { shape = "Box", range = 16, width = 2.4, height = 5, offset = Vector3.new(0, 0, -7) },
			minRange = 6, maxRange = 20, cooldown = 2.4, weight = 3,
			motion = { distance = 15, duration = 0.22 },
			telegraphShape = "Line", sfx = "EnemyLunge",
		},
		{
			id = "Flurry",
			clip = "Enemy_DoubleSlash",
			telegraph = 0.18, windup = 0.18, active = 0.10, recovery = 0.22,
			damage = 7, poiseDamage = 6, knockback = 3,
			hitbox = { shape = "Arc", range = 7, angle = 90, height = 5 },
			minRange = 0, maxRange = 7.5, cooldown = 1.1, weight = 4,
			telegraphShape = "Cone", sfx = "EnemySwingFast",
		},
	},
	rewards = { motes = 5, ultimateCharge = 3 },
	regions = { "SunkenMarch", "CinderReach", "RimefastSanctum" },
}

E.Bulwark = {
	id = "Bulwark",
	displayName = "BULWARK",
	role = "Shieldbearer",
	threat = "Blocks 80% of frontal damage. Go around it, stagger it, or parry the bash.",
	tier = "Grunt",
	rig = { scale = 1.12, palette = DROWNED, silhouette = { "pauldrons", "crest" }, material = Enum.Material.Metal },
	stats = {
		maxHealth = 130,
		damageScale = 1.0,
		walkSpeed = 8,
		chaseSpeed = 11,
		poiseThreshold = 75,
		detectionRange = 50,
		aggression = 0.35,
		weight = 1.6,
	},
	behavior = {
		archetype = "Guard",
		preferredRange = 6,
		strafeBias = 0.2,
		patience = 3.0,
		-- Damage from within this cone of its facing is heavily reduced.
		blocksFrontal = 110,
	},
	attacks = {
		{
			id = "Bash",
			clip = "Enemy_ShieldBash",
			telegraph = 0.30, windup = 0.30, active = 0.12, recovery = 0.24,
			damage = 14, poiseDamage = 40, knockback = 26,
			hitbox = { shape = "Box", range = 8, width = 3.4, height = 6, offset = Vector3.new(0, 0, -3) },
			minRange = 0, maxRange = 9, cooldown = 3.4, weight = 3,
			superArmorFrom = 0.1,
			motion = { distance = 5, duration = 0.26 },
			telegraphShape = "Line", sfx = "ShieldBash",
		},
		{
			id = "Overhead",
			clip = "Enemy_Overhead",
			telegraph = 0.46, windup = 0.46, active = 0.14, recovery = 0.32,
			damage = 22, poiseDamage = 30, knockback = 16,
			hitbox = { shape = "Arc", range = 9, angle = 80, height = 8 },
			minRange = 0, maxRange = 9, cooldown = 5.5, weight = 2,
			superArmorFrom = 0.2,
			telegraphShape = "Cone", sfx = "EnemyHeavy",
		},
	},
	rewards = { motes = 8, ultimateCharge = 6 },
	regions = { "SunkenMarch", "CinderReach", "RimefastSanctum" },
}

E.Fletcher = {
	id = "Fletcher",
	displayName = "FLETCHER",
	role = "Archer",
	threat = "Punishes you for taking your time. Kills the pace of a fight if left alive.",
	tier = "Grunt",
	rig = { scale = 0.95, palette = DROWNED, silhouette = { "cloak", "tatters" }, material = Enum.Material.Fabric },
	stats = {
		maxHealth = 48,
		damageScale = 0.9,
		walkSpeed = 12,
		chaseSpeed = 15,
		poiseThreshold = 16,
		detectionRange = 90,
		aggression = 0.25,
		weight = 0.8,
	},
	behavior = { archetype = "Ranged", preferredRange = 42, strafeBias = 0.85, patience = 0.4 },
	attacks = {
		{
			id = "Loose",
			clip = "Enemy_Shoot",
			telegraph = 0.42, windup = 0.42, active = 0.06, recovery = 0.42,
			damage = 12, poiseDamage = 8, knockback = 4,
			hitbox = { shape = "Box", range = 2, width = 1, height = 2 },
			minRange = 14, maxRange = 80, cooldown = 2.8, weight = 3,
			projectile = { speed = 95, radius = 0.8, maxRange = 90, gravity = 0, leadsTarget = true },
			telegraphShape = "Line", sfx = "BowRelease",
		},
		{
			id = "Volley",
			clip = "Enemy_Cast",
			telegraph = 0.72, windup = 0.72, active = 0.12, recovery = 0.56,
			damage = 8, poiseDamage = 6, knockback = 2,
			hitbox = { shape = "Box", range = 2, width = 1, height = 2 },
			minRange = 25, maxRange = 80, cooldown = 9, weight = 1,
			projectile = { speed = 70, radius = 0.8, maxRange = 90, count = 3, spreadDegrees = 14 },
			telegraphShape = "Cone", sfx = "BowVolley",
		},
	},
	rewards = { motes = 6, ultimateCharge = 4 },
	regions = { "SunkenMarch", "CinderReach", "RimefastSanctum" },
}

E.Drudge = {
	id = "Drudge",
	displayName = "DRUDGE",
	role = "Brute",
	threat = "Enormous telegraphs, enormous consequences. Its slam is the best parry "
		.. "practice in the game.",
	tier = "Grunt",
	rig = { scale = 1.5, palette = DROWNED, silhouette = { "horns", "pauldrons" }, material = Enum.Material.Slate },
	stats = {
		maxHealth = 210,
		damageScale = 1.4,
		walkSpeed = 7,
		chaseSpeed = 10,
		poiseThreshold = 110,
		detectionRange = 45,
		aggression = 0.5,
		weight = 2.4,
	},
	behavior = { archetype = "Melee", preferredRange = 8, strafeBias = 0.1, patience = 2.4 },
	attacks = {
		{
			id = "Slam",
			clip = "Enemy_Overhead",
			telegraph = 0.46, windup = 0.46, active = 0.14, recovery = 0.32,
			damage = 30, poiseDamage = 60, knockback = 34,
			hitbox = { shape = "Sphere", range = 11, height = 7 },
			minRange = 0, maxRange = 11, cooldown = 4.2, weight = 3,
			superArmorFrom = 0.15,
			telegraphShape = "Circle", sfx = "BruteSlam",
		},
		{
			id = "Sweep",
			clip = "Enemy_Spin",
			telegraph = 0.40, windup = 0.40, active = 0.30, recovery = 0.30,
			damage = 24, poiseDamage = 50, knockback = 40,
			hitbox = { shape = "Sphere", range = 13, height = 7 },
			minRange = 0, maxRange = 13, cooldown = 7, weight = 2,
			superArmorFrom = 0.1,
			telegraphShape = "Circle", sfx = "BruteSweep",
		},
	},
	rewards = { motes = 12, ultimateCharge = 9 },
	regions = { "SunkenMarch", "CinderReach", "RimefastSanctum" },
}

E.Vesper = {
	id = "Vesper",
	displayName = "VESPER",
	role = "Flyer",
	threat = "Hovers out of reach and dives. Answered by launchers, thrown weapons, or "
		.. "patience.",
	tier = "Grunt",
	rig = { scale = 0.9, palette = DROWNED, silhouette = { "horns", "tatters", "halo" }, material = Enum.Material.Neon, glow = true },
	stats = {
		maxHealth = 55,
		damageScale = 0.95,
		walkSpeed = 16,
		chaseSpeed = 22,
		poiseThreshold = 12,
		detectionRange = 75,
		aggression = 0.65,
		weight = 0.5,
	},
	behavior = {
		archetype = "Flyer",
		preferredRange = 18,
		strafeBias = 0.9,
		patience = 1.0,
		flying = true,
		hoverHeight = 9,
	},
	attacks = {
		{
			id = "Dive",
			clip = "Enemy_Lunge",
			telegraph = 0.24, windup = 0.24, active = 0.10, recovery = 0.20,
			damage = 15, poiseDamage = 12, knockback = 12,
			hitbox = { shape = "Sphere", range = 6, height = 6 },
			minRange = 8, maxRange = 30, cooldown = 3.2, weight = 3,
			motion = { distance = 26, duration = 0.24 },
			telegraphShape = "Line", sfx = "VesperDive",
		},
		{
			id = "Shriek",
			clip = "Enemy_Cast",
			telegraph = 0.72, windup = 0.72, active = 0.12, recovery = 0.56,
			damage = 10, poiseDamage = 20, knockback = 18,
			hitbox = { shape = "Sphere", range = 16, height = 12 },
			minRange = 0, maxRange = 18, cooldown = 8, weight = 1,
			applies = "Winded",
			telegraphShape = "Circle", sfx = "VesperShriek",
		},
	},
	rewards = { motes = 7, ultimateCharge = 5 },
	regions = { "SunkenMarch", "CinderReach", "RimefastSanctum" },
}

E.Censer = {
	id = "Censer",
	displayName = "CENSER",
	role = "Exploder",
	threat = "Walks at you and dies loudly. Kill it early or make something else eat it.",
	tier = "Grunt",
	rig = { scale = 1.05, palette = ASHEN, silhouette = { "tatters", "halo" }, material = Enum.Material.Neon, glow = true },
	stats = {
		maxHealth = 36,
		damageScale = 1.6,
		walkSpeed = 13,
		chaseSpeed = 19,
		poiseThreshold = 8,
		detectionRange = 65,
		aggression = 1.0,
		weight = 0.9,
	},
	behavior = {
		archetype = "Exploder",
		preferredRange = 3,
		strafeBias = 0.05,
		patience = 0,
		-- Exploders glow brighter the closer they get, so the warning starts long
		-- before the attack does. Without this the detonation is unfair.
		primesOnApproach = { startDistance = 30, pulseRate = 2.4 },
	},
	attacks = {
		{
			id = "Immolate",
			clip = "Enemy_Cast",
			telegraph = 0.72, windup = 0.72, active = 0.12, recovery = 0.56,
			damage = 42, poiseDamage = 70, knockback = 40,
			hitbox = { shape = "Sphere", range = 16, height = 10 },
			minRange = 0, maxRange = 7, cooldown = 99, weight = 5,
			superArmorFrom = 0.0,
			applies = "Burn",
			telegraphShape = "Circle", sfx = "CenserPrime",
		},
	},
	-- Dying mid-windup still detonates: killing one next to its friends is the play.
	onDeath = {
		kind = "Explode",
		damage = 30,
		radius = 14,
		delay = 0.35,
		applies = "Burn",
		-- Friendly fire is on for this specifically, and it is the best part.
		damagesEnemies = true,
	},
	rewards = { motes = 5, ultimateCharge = 4 },
	regions = { "SunkenMarch", "CinderReach", "RimefastSanctum" },
}

E.Tallier = {
	id = "Tallier",
	displayName = "TALLIER",
	role = "Elite knight",
	threat = "A Warden's officer. Has an answer to every range and no bad options.",
	tier = "Elite",
	rig = {
		scale = 1.25,
		palette = { primary = Color3.fromRGB(46, 44, 62), secondary = Color3.fromRGB(28, 26, 40), accent = Color3.fromRGB(255, 200, 110), eye = Color3.fromRGB(255, 220, 150) },
		silhouette = { "pauldrons", "cloak", "crest" },
		material = Enum.Material.Metal,
		glow = true,
	},
	stats = {
		maxHealth = 330,
		damageScale = 1.3,
		walkSpeed = 12,
		chaseSpeed = 19,
		poiseThreshold = 95,
		detectionRange = 80,
		aggression = 0.75,
		weight = 1.5,
	},
	behavior = { archetype = "Melee", preferredRange = 9, strafeBias = 0.5, patience = 1.0 },
	attacks = {
		{
			id = "Triplet",
			clip = "Enemy_DoubleSlash",
			telegraph = 0.18, windup = 0.18, active = 0.10, recovery = 0.22,
			damage = 14, poiseDamage = 18, knockback = 8,
			hitbox = { shape = "Arc", range = 10, angle = 120, height = 7 },
			minRange = 0, maxRange = 10, cooldown = 1.5, weight = 4,
			telegraphShape = "Cone", sfx = "EnemySwingFast",
		},
		{
			id = "Judgement",
			clip = "Enemy_Overhead",
			telegraph = 0.46, windup = 0.46, active = 0.14, recovery = 0.32,
			damage = 34, poiseDamage = 55, knockback = 30,
			hitbox = { shape = "Arc", range = 12, angle = 90, height = 9 },
			minRange = 0, maxRange = 12, cooldown = 6, weight = 2,
			superArmorFrom = 0.18,
			applies = "Sundered",
			telegraphShape = "Cone", sfx = "EnemyHeavy",
		},
		{
			id = "Closing",
			clip = "Enemy_Lunge",
			telegraph = 0.24, windup = 0.24, active = 0.10, recovery = 0.20,
			damage = 18, poiseDamage = 22, knockback = 14,
			hitbox = { shape = "Box", range = 18, width = 3, height = 6, offset = Vector3.new(0, 0, -8) },
			minRange = 10, maxRange = 26, cooldown = 4.5, weight = 3,
			motion = { distance = 17, duration = 0.22 },
			telegraphShape = "Line", sfx = "EnemyLunge",
		},
		{
			id = "Reckoning",
			clip = "Enemy_Spin",
			telegraph = 0.40, windup = 0.40, active = 0.30, recovery = 0.30,
			damage = 26, poiseDamage = 60, knockback = 36,
			hitbox = { shape = "Sphere", range = 15, height = 8 },
			minRange = 0, maxRange = 15, cooldown = 11, weight = 2,
			superArmorFrom = 0.12,
			telegraphShape = "Circle", sfx = "BruteSweep",
		},
	},
	rewards = { motes = 26, ultimateCharge = 20 },
	regions = { "SunkenMarch", "CinderReach", "RimefastSanctum" },
}

--------------------------------------------------------------------------------
-- Elite modifiers
--
-- Rolled onto a normal enemy to make an elite. Each is meant to change how you
-- fight the thing, not just how long it takes.
--------------------------------------------------------------------------------

export type EliteModifier = {
	id: string,
	name: string,
	description: string,
	color: Color3,
	apply: any,
}

EnemyConfig.EliteModifiers = {
	{
		id = "Burning",
		name = "BURNING",
		description = "Leaves fire where it walks and burns you on contact.",
		color = Color3.fromRGB(255, 122, 48),
		apply = { onHitStatus = "Burn", trail = { radius = 7, tickDamage = 6, duration = 3 } },
	},
	{
		id = "Swift",
		name = "SWIFT",
		description = "Moves and attacks 40% faster, with the same telegraphs.",
		color = Color3.fromRGB(196, 248, 226),
		apply = { speedScale = 1.4, attackSpeedScale = 1.4 },
	},
	{
		id = "Ironbound",
		name = "IRONBOUND",
		description = "Cannot be staggered. Takes 25% less damage from the front.",
		color = Color3.fromRGB(180, 186, 196),
		apply = { unstaggerable = true, frontalReduction = 0.25 },
	},
	{
		id = "Volatile",
		name = "VOLATILE",
		description = "Detonates on death, hard.",
		color = Color3.fromRGB(255, 186, 74),
		apply = { deathExplosion = { damage = 45, radius = 18, damagesEnemies = true } },
	},
	{
		id = "Leeching",
		name = "LEECHING",
		description = "Heals itself for a third of the damage it deals.",
		color = Color3.fromRGB(214, 62, 84),
		apply = { lifesteal = 0.33 },
	},
	{
		id = "Warded",
		name = "WARDED",
		description = "Carries a shield that must be broken before its health can be touched.",
		color = Color3.fromRGB(126, 205, 255),
		apply = { wardHealth = 0.5, wardRegenDelay = 6 },
	},
}

--------------------------------------------------------------------------------
-- Accessors
--------------------------------------------------------------------------------

function EnemyConfig.Get(enemyId: string): Enemy?
	return E[enemyId]
end

function EnemyConfig.GetModifier(modifierId: string): EliteModifier?
	for _, modifier in EnemyConfig.EliteModifiers do
		if modifier.id == modifierId then
			return modifier
		end
	end
	return nil
end

function EnemyConfig.ForRegion(regionId: string): { Enemy }
	local result = {}
	for _, enemy in E do
		if table.find(enemy.regions, regionId) then
			table.insert(result, enemy)
		end
	end
	table.sort(result, function(a, b)
		return a.id < b.id
	end)
	return result
end

function EnemyConfig.AttackDuration(attack: EnemyAttack): number
	return attack.windup + attack.active + attack.recovery
end

--- Boot-time check: attack timing must match its clip, and telegraphs must fit
--- inside the windup they are supposed to warn about.
function EnemyConfig.Validate(): { string }
	local problems = {}

	for id, enemy in E do
		if #enemy.attacks == 0 then
			table.insert(problems, id .. " has no attacks")
		end
		for _, attack in enemy.attacks do
			local total = EnemyConfig.AttackDuration(attack)
			local clip = PoseLibrary.Get(attack.clip)
			if not clip then
				table.insert(problems, ("%s/%s references missing clip %q"):format(id, attack.id, attack.clip))
			elseif math.abs(total - clip.duration) > 0.035 then
				table.insert(
					problems,
					("%s/%s timing %.3fs does not match clip %q (%.3fs)")
						:format(id, attack.id, total, attack.clip, clip.duration)
				)
			end
			if attack.telegraph > attack.windup + 1e-4 then
				-- A telegraph is a slice of the windup, never an extension of it.
				-- Warnings that need to start earlier belong in `primesOnApproach`.
				table.insert(
					problems,
					("%s/%s telegraph %.2fs exceeds its windup %.2fs")
						:format(id, attack.id, attack.telegraph, attack.windup)
				)
			end
			if attack.minRange >= attack.maxRange then
				table.insert(problems, ("%s/%s has an empty range band"):format(id, attack.id))
			end
		end
	end

	return problems
end

return EnemyConfig
