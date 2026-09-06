--!strict
--[[
	StatusConfig — damage-over-time and debuff definitions.

	Statuses are the connective tissue of the Grace system: most Graces do not add
	damage directly, they apply or exploit a status. Keeping them in one table means
	a Grace, an enemy attack and a boss mechanic can all reference the same Burn
	with the same rules.

	STACKING
	  "Refresh"   — reapplying resets the timer, potency unchanged. (Burn)
	  "Stack"     — potency adds, up to maxStacks, timer resets. (Blight, Bleed)
	  "Independent" — each application ticks on its own timer. (rare, expensive)
]]

local Lore = require(script.Parent.Lore)

export type Status = {
	id: string,
	name: string,
	element: string,
	stacking: "Refresh" | "Stack" | "Independent",
	maxStacks: number,
	duration: number,
	tickInterval: number?,
	-- Damage per tick as a fraction of the applying hit's damage.
	tickDamageRatio: number?,
	-- Multiplicative modifiers applied to the afflicted while active.
	moveSpeedMultiplier: number?,
	damageTakenMultiplier: number?,
	damageDealtMultiplier: number?,
	attackSpeedMultiplier: number?,
	-- Prevents all action for the duration. Used sparingly: it is not fun on bosses.
	incapacitates: boolean?,
	-- Bosses resist crowd control; this scales duration against them.
	bossDurationScale: number?,
	color: Color3,
	icon: string,
	description: string,
}

local StatusConfig = {}

StatusConfig.Statuses = {} :: { [string]: Status }

StatusConfig.Statuses.Burn = {
	id = "Burn",
	name = "Burning",
	element = "Cinder",
	stacking = "Refresh",
	maxStacks = 1,
	duration = 4,
	tickInterval = 0.5,
	tickDamageRatio = 0.16,
	color = Lore.ElementColor("Cinder"),
	icon = "flame",
	description = "Takes fire damage over time. Reapplying refreshes the duration.",
}

StatusConfig.Statuses.Shock = {
	id = "Shock",
	name = "Shocked",
	element = "Skein",
	stacking = "Refresh",
	maxStacks = 1,
	duration = 3,
	damageTakenMultiplier = 1.15,
	color = Lore.ElementColor("Skein"),
	icon = "bolt",
	description = "Takes 15% more damage, and is a valid jump point for chaining Skein.",
}

StatusConfig.Statuses.Chill = {
	id = "Chill",
	name = "Chilled",
	element = "Rime",
	stacking = "Stack",
	maxStacks = 5,
	duration = 5,
	moveSpeedMultiplier = 0.9,
	attackSpeedMultiplier = 0.94,
	color = Lore.ElementColor("Rime"),
	icon = "frost",
	description = "Slows movement and attacks. At five stacks it becomes Frozen.",
}

StatusConfig.Statuses.Frozen = {
	id = "Frozen",
	name = "Frozen",
	element = "Rime",
	stacking = "Refresh",
	maxStacks = 1,
	duration = 1.8,
	incapacitates = true,
	damageTakenMultiplier = 1.35,
	-- A boss frozen for two full seconds would trivialise every phase transition.
	bossDurationScale = 0.35,
	color = Color3.fromRGB(210, 240, 255),
	icon = "ice",
	description = "Cannot act. Takes 35% more damage. Shattering it early spends the status.",
}

StatusConfig.Statuses.Blight = {
	id = "Blight",
	name = "Blighted",
	element = "Blight",
	stacking = "Stack",
	maxStacks = 10,
	duration = 8,
	tickInterval = 0.75,
	tickDamageRatio = 0.05,
	color = Lore.ElementColor("Blight"),
	icon = "spore",
	description = "Stacking poison. Slow to start and difficult to stop.",
}

StatusConfig.Statuses.Bleed = {
	id = "Bleed",
	name = "Bleeding",
	element = "Marrow",
	stacking = "Stack",
	maxStacks = 6,
	duration = 5,
	tickInterval = 0.6,
	tickDamageRatio = 0.09,
	color = Lore.ElementColor("Marrow"),
	icon = "drop",
	description = "Stacking physical damage over time. Heals you when it kills.",
}

StatusConfig.Statuses.Marked = {
	id = "Marked",
	name = "Marked",
	element = "Hush",
	stacking = "Refresh",
	maxStacks = 1,
	duration = 6,
	damageTakenMultiplier = 1.2,
	color = Lore.ElementColor("Hush"),
	icon = "eye",
	description = "Takes 20% more damage from every source, including other enemies.",
}

StatusConfig.Statuses.Sundered = {
	id = "Sundered",
	name = "Sundered",
	element = "Physical",
	stacking = "Stack",
	maxStacks = 4,
	duration = 6,
	damageTakenMultiplier = 1.08,
	color = Color3.fromRGB(230, 200, 160),
	icon = "crack",
	description = "Armour broken. Each stack adds 8% damage taken.",
}

StatusConfig.Statuses.Winded = {
	id = "Winded",
	name = "Winded",
	element = "Gale",
	stacking = "Refresh",
	maxStacks = 1,
	duration = 4,
	damageDealtMultiplier = 0.85,
	attackSpeedMultiplier = 0.88,
	color = Lore.ElementColor("Gale"),
	icon = "wind",
	description = "Attacks land slower and hit softer.",
}

--- Player-side buffs live in the same table so the HUD can render them identically.
StatusConfig.Statuses.Haste = {
	id = "Haste",
	name = "Hastened",
	element = "Gale",
	stacking = "Refresh",
	maxStacks = 1,
	duration = 4,
	moveSpeedMultiplier = 1.25,
	attackSpeedMultiplier = 1.15,
	color = Lore.ElementColor("Gale"),
	icon = "wind",
	description = "Moves and attacks faster.",
}

StatusConfig.Statuses.Emboldened = {
	id = "Emboldened",
	name = "Emboldened",
	element = "Marrow",
	stacking = "Stack",
	maxStacks = 5,
	duration = 6,
	damageDealtMultiplier = 1.06,
	color = Lore.ElementColor("Marrow"),
	icon = "heart",
	description = "Each stack adds 6% damage dealt.",
}

StatusConfig.Statuses.Veiled = {
	id = "Veiled",
	name = "Veiled",
	element = "Hush",
	stacking = "Refresh",
	maxStacks = 1,
	duration = 3,
	color = Lore.ElementColor("Hush"),
	icon = "shroud",
	description = "Enemies lose track of you and will not commit to attacks.",
}

function StatusConfig.Get(statusId: string): Status?
	return StatusConfig.Statuses[statusId]
end

--- Effective duration after boss resistance is applied.
function StatusConfig.DurationFor(statusId: string, isBoss: boolean): number
	local status = StatusConfig.Statuses[statusId]
	if not status then
		return 0
	end
	if isBoss then
		return status.duration * (status.bossDurationScale or 0.6)
	end
	return status.duration
end

--- Statuses that count as "afflicted" for Graces that check for any debuff.
StatusConfig.Debuffs = { "Burn", "Shock", "Chill", "Frozen", "Blight", "Bleed", "Marked", "Sundered", "Winded" }

return StatusConfig
