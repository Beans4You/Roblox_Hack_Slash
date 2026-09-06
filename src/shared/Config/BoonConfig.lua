--!strict
--[[
	BoonConfig — the Graces, and the rules for combining them.

	A Grace is a temporary power offered by one of the Faded at a shrine during a
	run. The design constraint from the brief is that rare Graces must be
	*different*, not merely larger, so almost nothing here is a flat damage number:
	Graces attach behaviour to a trigger (on hit, on dodge, on parry, on kill) and
	the interesting part of a build is which triggers you end up stacked on.

	EFFECTS ARE DATA
	Each Grace declares an `effect` table with a `kind`. The server's BoonRuntime
	owns one handler per kind, so this file never contains logic and adding a Grace
	that reuses an existing kind requires no code at all.

	SCALING
	`values` holds one row per rarity. A Grace that does not offer a rarity simply
	omits the row and will never roll at it -- this is how we keep, say, a
	Legendary-only capstone from showing up as a grey.
]]

local GameConfig = require(script.Parent.GameConfig)
local Lore = require(script.Parent.Lore)

export type Rarity = "Common" | "Rare" | "Epic" | "Legendary"

export type Boon = {
	id: string,
	faded: string,
	name: string,
	-- `{}` placeholders are filled from the rolled rarity's values, in order.
	description: string,
	-- What has to happen for this Grace to do anything. Drives the UI grouping and
	-- lets the offer generator avoid handing you five triggers you never pull.
	trigger: "OnHit" | "OnKill" | "OnDodge" | "OnParry" | "OnAbility" | "OnUltimate" | "Passive" | "OnDamaged",
	values: { [Rarity]: { number } },
	effect: any,
	-- Only offered when this returns true (checked against the live run state).
	requires: { boon: string?, element: string?, weaponTag: string?, minRoom: number? }?,
	-- Never offered alongside these; used to stop two Graces owning the same slot.
	conflicts: { string }?,
	tags: { string }?,
}

local BoonConfig = {}

BoonConfig.Boons = {} :: { [string]: Boon }
local B = BoonConfig.Boons

--------------------------------------------------------------------------------
-- CINDER — Orrin. Damage over time, and payoffs for keeping things alight.
--------------------------------------------------------------------------------

B.Cinder_Kindling = {
	id = "Cinder_Kindling",
	faded = "Cinder",
	name = "KINDLING",
	description = "Your attacks set things burning for {}% of the damage they did.",
	trigger = "OnHit",
	values = { Common = { 60 }, Rare = { 90 }, Epic = { 130 }, Legendary = { 190 } },
	effect = { kind = "ApplyStatus", status = "Burn", potencyIndex = 1, chance = 1 },
	tags = { "Cinder", "DoT" },
}

B.Cinder_Bellows = {
	id = "Cinder_Bellows",
	faded = "Cinder",
	name = "BELLOWS",
	description = "Burning enemies take {}% more damage from everything else you do.",
	trigger = "Passive",
	values = { Common = { 15 }, Rare = { 24 }, Epic = { 35 } },
	effect = { kind = "DamageVsStatus", status = "Burn", bonusIndex = 1 },
	requires = { element = "Cinder" },
	tags = { "Cinder", "Amplifier" },
}

B.Cinder_Backdraft = {
	id = "Cinder_Backdraft",
	faded = "Cinder",
	name = "BACKDRAFT",
	description = "When something burning dies, it bursts for {} damage in {} studs — and "
		.. "the burst spreads the fire.",
	trigger = "OnKill",
	values = { Common = { 40, 12 }, Rare = { 70, 14 }, Epic = { 120, 17 }, Legendary = { 200, 22 } },
	effect = { kind = "DeathBurst", requiresStatus = "Burn", damageIndex = 1, radiusIndex = 2, spreads = "Burn" },
	requires = { boon = "Cinder_Kindling" },
	tags = { "Cinder", "Chain" },
}

B.Cinder_Forgehand = {
	id = "Cinder_Forgehand",
	faded = "Cinder",
	name = "FORGEHAND",
	description = "Your heavy attack leaves a pool of fire for {} seconds.",
	trigger = "OnHit",
	values = { Common = { 3 }, Rare = { 4.5 }, Epic = { 6.5 } },
	effect = {
		kind = "GroundZone",
		onTag = "IsHeavy",
		durationIndex = 1,
		radius = 12,
		tickInterval = 0.4,
		tickRatio = 0.22,
		status = "Burn",
	},
	tags = { "Cinder", "Zone" },
}

--------------------------------------------------------------------------------
-- SKEIN — Talys. Chaining, and rewards for fighting groups.
--------------------------------------------------------------------------------

B.Skein_Throughline = {
	id = "Skein_Throughline",
	faded = "Skein",
	name = "THROUGHLINE",
	description = "Attacks arc to {} nearby enemies for {}% damage.",
	trigger = "OnHit",
	values = { Common = { 1, 40 }, Rare = { 2, 50 }, Epic = { 3, 65 }, Legendary = { 5, 80 } },
	effect = { kind = "Chain", jumpsIndex = 1, ratioIndex = 2, radius = 18, applies = "Shock" },
	tags = { "Skein", "Chain" },
}

B.Skein_Conductor = {
	id = "Skein_Conductor",
	faded = "Skein",
	name = "CONDUCTOR",
	description = "Chains jump {} studs further and can return to a target they already hit.",
	trigger = "Passive",
	values = { Common = { 8 }, Rare = { 14 }, Epic = { 22 } },
	effect = { kind = "ChainModifier", extraRadiusIndex = 1, allowRevisit = true },
	requires = { element = "Skein" },
	tags = { "Skein", "Amplifier" },
}

B.Skein_Overrun = {
	id = "Skein_Overrun",
	faded = "Skein",
	name = "OVERRUN",
	description = "Every enemy beyond the first that you hit with one swing adds {}% damage "
		.. "to that swing.",
	trigger = "OnHit",
	values = { Common = { 12 }, Rare = { 18 }, Epic = { 26 } },
	effect = { kind = "PerTargetBonus", bonusIndex = 1, maxStacks = 8 },
	tags = { "Skein", "Crowd" },
}

B.Skein_Discharge = {
	id = "Skein_Discharge",
	faded = "Skein",
	name = "DISCHARGE",
	description = "Your ability shocks everything within {} studs, whether it hit or not.",
	trigger = "OnAbility",
	values = { Common = { 14 }, Rare = { 20 }, Epic = { 28 } },
	effect = { kind = "AreaStatus", status = "Shock", radiusIndex = 1, damageRatio = 0.5 },
	tags = { "Skein", "Ability" },
}

--------------------------------------------------------------------------------
-- RIME — the Pale Auditor. Control, and payoffs for standing still.
--------------------------------------------------------------------------------

B.Rime_Tally = {
	id = "Rime_Tally",
	faded = "Rime",
	name = "TALLY",
	description = "Attacks apply {} stacks of Chill. Five stacks freezes.",
	trigger = "OnHit",
	values = { Common = { 1 }, Rare = { 2 }, Epic = { 3 } },
	effect = { kind = "ApplyStatus", status = "Chill", stacksIndex = 1, chance = 1 },
	tags = { "Rime", "Control" },
}

B.Rime_Shatter = {
	id = "Rime_Shatter",
	faded = "Rime",
	name = "SHATTER",
	description = "Hitting a Frozen enemy ends the freeze early and deals {}% of its "
		.. "missing health as damage.",
	trigger = "OnHit",
	values = { Rare = { 12 }, Epic = { 18 }, Legendary = { 28 } },
	effect = { kind = "ConsumeStatus", status = "Frozen", missingHealthIndex = 1, cap = 900 },
	requires = { element = "Rime" },
	tags = { "Rime", "Execute" },
}

B.Rime_Audit = {
	id = "Rime_Audit",
	faded = "Rime",
	name = "AUDIT",
	description = "Standing still for a moment coats your next attack: it deals {}% more "
		.. "damage and always Chills.",
	trigger = "Passive",
	values = { Common = { 45 }, Rare = { 70 }, Epic = { 110 } },
	effect = { kind = "ChargedNextHit", stillTime = 1.1, bonusIndex = 1, applies = "Chill" },
	tags = { "Rime", "Tempo" },
}

B.Rime_Hoarfrost = {
	id = "Rime_Hoarfrost",
	faded = "Rime",
	name = "HOARFROST",
	description = "Chilled enemies near each other spread Chill between them every {} seconds.",
	trigger = "Passive",
	values = { Rare = { 1.5 }, Epic = { 1.0 } },
	effect = { kind = "StatusSpread", status = "Chill", intervalIndex = 1, radius = 14 },
	requires = { boon = "Rime_Tally" },
	tags = { "Rime", "Crowd" },
}

--------------------------------------------------------------------------------
-- HUSH — Nuil. Everything keys off dodging.
--------------------------------------------------------------------------------

B.Hush_Afterimage = {
	id = "Hush_Afterimage",
	faded = "Hush",
	name = "AFTERIMAGE",
	description = "Dodging leaves something behind. It detonates for {} damage after a "
		.. "moment.",
	trigger = "OnDodge",
	values = { Common = { 45 }, Rare = { 80 }, Epic = { 130 }, Legendary = { 210 } },
	effect = { kind = "DodgeEcho", damageIndex = 1, radius = 13, delay = 0.55, applies = "Marked" },
	tags = { "Hush", "Dodge" },
}

B.Hush_Longshadow = {
	id = "Hush_Longshadow",
	faded = "Hush",
	name = "LONG SHADOW",
	description = "Your dodge travels {}% further and your invulnerability lasts {}% longer.",
	trigger = "Passive",
	values = { Common = { 25, 20 }, Rare = { 40, 35 }, Epic = { 60, 50 } },
	effect = { kind = "DodgeModifier", distanceIndex = 1, iframeIndex = 2 },
	tags = { "Hush", "Dodge", "Defensive" },
}

B.Hush_Attention = {
	id = "Hush_Attention",
	faded = "Hush",
	name = "NOBODY'S ATTENTION",
	description = "Attacking a Marked enemy from behind deals {}% more damage.",
	trigger = "OnHit",
	values = { Common = { 40 }, Rare = { 65 }, Epic = { 100 }, Legendary = { 160 } },
	effect = { kind = "PositionalBonus", requiresStatus = "Marked", fromBehind = true, bonusIndex = 1 },
	tags = { "Hush", "Positional" },
}

B.Hush_Cadence = {
	id = "Hush_Cadence",
	faded = "Hush",
	name = "CADENCE",
	description = "Attacking within {} seconds of a dodge refunds the dodge's stamina and "
		.. "the attack cannot be interrupted.",
	trigger = "OnDodge",
	values = { Rare = { 0.7 }, Epic = { 1.1 } },
	effect = { kind = "DodgeWindow", windowIndex = 1, refundStamina = true, superArmor = true },
	requires = { element = "Hush" },
	tags = { "Hush", "Tempo" },
}

--------------------------------------------------------------------------------
-- MARROW — Vesh. Sustain, bought with risk.
--------------------------------------------------------------------------------

B.Marrow_Toll = {
	id = "Marrow_Toll",
	faded = "Marrow",
	name = "THE TOLL",
	description = "Critical hits heal you for {}. Your crit chance is {}%.",
	trigger = "OnHit",
	values = { Common = { 4, 12 }, Rare = { 7, 18 }, Epic = { 11, 25 }, Legendary = { 16, 35 } },
	effect = { kind = "CritLifesteal", healIndex = 1, critChanceIndex = 2 },
	tags = { "Marrow", "Sustain", "Crit" },
}

B.Marrow_Openhanded = {
	id = "Marrow_Openhanded",
	faded = "Marrow",
	name = "OPEN-HANDED",
	description = "Attacks make things Bleed. Killing a bleeding enemy heals you {}.",
	trigger = "OnHit",
	values = { Common = { 6 }, Rare = { 10 }, Epic = { 16 } },
	effect = { kind = "ApplyStatus", status = "Bleed", stacks = 1, chance = 0.5, killHealIndex = 1 },
	tags = { "Marrow", "DoT", "Sustain" },
}

B.Marrow_Wager = {
	id = "Marrow_Wager",
	faded = "Marrow",
	name = "VESH'S WAGER",
	description = "Below half health you deal {}% more damage. Above it you deal {}% less.",
	trigger = "Passive",
	values = { Rare = { 30, 8 }, Epic = { 50, 10 }, Legendary = { 85, 12 } },
	effect = { kind = "HealthThresholdDamage", belowIndex = 1, aboveIndex = 2, threshold = 0.5 },
	conflicts = { "Marrow_Ward" },
	tags = { "Marrow", "Risk" },
}

B.Marrow_Ward = {
	id = "Marrow_Ward",
	faded = "Marrow",
	name = "MARROW WARD",
	description = "The first hit you take in each room is absorbed, and you gain {} stacks "
		.. "of Emboldened.",
	trigger = "OnDamaged",
	values = { Common = { 2 }, Rare = { 3 }, Epic = { 5 } },
	effect = { kind = "RoomShield", stacksIndex = 1, grantsStatus = "Emboldened" },
	conflicts = { "Marrow_Wager" },
	tags = { "Marrow", "Defensive" },
}

--------------------------------------------------------------------------------
-- BLIGHT — Ghal. Slow, inevitable, scales with time in the room.
--------------------------------------------------------------------------------

B.Blight_Patience = {
	id = "Blight_Patience",
	faded = "Blight",
	name = "PATIENCE",
	description = "Attacks apply {} stacks of Blight. Blight lasts twice as long on elites "
		.. "and Wardens.",
	trigger = "OnHit",
	values = { Common = { 1 }, Rare = { 2 }, Epic = { 3 }, Legendary = { 4 } },
	effect = { kind = "ApplyStatus", status = "Blight", stacksIndex = 1, chance = 1, eliteDurationScale = 2 },
	tags = { "Blight", "DoT" },
}

B.Blight_Sump = {
	id = "Blight_Sump",
	faded = "Blight",
	name = "THE SUMP",
	description = "Blight stacks no longer expire while the enemy is in combat with you, "
		.. "and tick {}% faster.",
	trigger = "Passive",
	values = { Rare = { 25 }, Epic = { 45 }, Legendary = { 70 } },
	effect = { kind = "StatusModifier", status = "Blight", noExpireInCombat = true, tickRateIndex = 1 },
	requires = { boon = "Blight_Patience" },
	tags = { "Blight", "Amplifier" },
}

B.Blight_Bloom = {
	id = "Blight_Bloom",
	faded = "Blight",
	name = "BLOOM",
	description = "At {} stacks of Blight, the enemy bursts and passes half its stacks to "
		.. "everything nearby.",
	trigger = "Passive",
	values = { Common = { 8 }, Rare = { 6 }, Epic = { 4 } },
	effect = { kind = "StatusThresholdBurst", status = "Blight", thresholdIndex = 1, radius = 16, transferRatio = 0.5 },
	requires = { boon = "Blight_Patience" },
	tags = { "Blight", "Chain" },
}

--------------------------------------------------------------------------------
-- GALE — Ysolde. Speed, and payoffs for never stopping.
--------------------------------------------------------------------------------

B.Gale_Momentum = {
	id = "Gale_Momentum",
	faded = "Gale",
	name = "MOMENTUM",
	description = "Each hit you land grants Haste. Attacking grants {}% more move speed "
		.. "for a few seconds.",
	trigger = "OnHit",
	values = { Common = { 8 }, Rare = { 14 }, Epic = { 22 } },
	effect = { kind = "SelfStatus", status = "Haste", magnitudeIndex = 1, duration = 3 },
	tags = { "Gale", "Tempo" },
}

B.Gale_Ninth = {
	id = "Gale_Ninth",
	faded = "Gale",
	name = "THE NINTH WIND",
	description = "Every {} hits without being hit, your next attack knocks everything back "
		.. "and Winds it.",
	trigger = "OnHit",
	values = { Common = { 12 }, Rare = { 9 }, Epic = { 6 } },
	effect = { kind = "HitStreak", countIndex = 1, burstKnockback = 40, applies = "Winded", damageRatio = 1.2 },
	tags = { "Gale", "Streak" },
}

B.Gale_Unstill = {
	id = "Gale_Unstill",
	faded = "Gale",
	name = "UNSTILL",
	description = "Your attacks deal {}% more damage while you are moving. Standing still "
		.. "drops it immediately.",
	trigger = "Passive",
	values = { Common = { 18 }, Rare = { 28 }, Epic = { 42 }, Legendary = { 60 } },
	effect = { kind = "MovingDamage", bonusIndex = 1 },
	conflicts = { "Rime_Audit" },
	tags = { "Gale", "Tempo" },
}

--------------------------------------------------------------------------------
-- Non-elemental utility. Offered by whichever Faded you have seen most.
--------------------------------------------------------------------------------

B.Common_Whetstone = {
	id = "Common_Whetstone",
	faded = "Cinder",
	name = "WHETSTONE",
	description = "Light attacks deal {}% more damage.",
	trigger = "Passive",
	values = { Common = { 15 }, Rare = { 25 }, Epic = { 38 } },
	effect = { kind = "AttackTypeDamage", attackType = "Light", bonusIndex = 1 },
	tags = { "Utility" },
}

B.Common_Counterweight = {
	id = "Common_Counterweight",
	faded = "Marrow",
	name = "COUNTERWEIGHT",
	description = "Heavy attacks deal {}% more damage and build {}% more stagger.",
	trigger = "Passive",
	values = { Common = { 20, 25 }, Rare = { 34, 40 }, Epic = { 52, 60 } },
	effect = { kind = "AttackTypeDamage", attackType = "Heavy", bonusIndex = 1, poiseIndex = 2 },
	tags = { "Utility" },
}

B.Common_Riposte = {
	id = "Common_Riposte",
	faded = "Hush",
	name = "RIPOSTE",
	description = "A perfect parry deals {} damage back and refunds {}% of your ability "
		.. "cooldown.",
	trigger = "OnParry",
	values = { Common = { 60, 20 }, Rare = { 110, 35 }, Epic = { 190, 55 }, Legendary = { 320, 100 } },
	effect = { kind = "ParryCounter", damageIndex = 1, cooldownRefundIndex = 2, applies = "Sundered" },
	tags = { "Utility", "Parry" },
}

B.Common_Reservoir = {
	id = "Common_Reservoir",
	faded = "Skein",
	name = "RESERVOIR",
	description = "Your ultimate charges {}% faster and costs {}% less to fire.",
	trigger = "Passive",
	values = { Common = { 20, 5 }, Rare = { 35, 10 }, Epic = { 55, 25 } },
	effect = { kind = "UltimateModifier", chargeIndex = 1, costIndex = 2 },
	tags = { "Utility", "Ultimate" },
}

B.Common_SecondWind = {
	id = "Common_SecondWind",
	faded = "Gale",
	name = "SECOND WIND",
	description = "Once per room, dropping below 25% health heals you {} and grants "
		.. "invulnerability.",
	trigger = "OnDamaged",
	values = { Rare = { 30 }, Epic = { 50 }, Legendary = { 80 } },
	effect = { kind = "EmergencyHeal", healIndex = 1, threshold = 0.25, invulnerability = 1.5 },
	tags = { "Utility", "Defensive" },
}

--------------------------------------------------------------------------------
-- SYNERGIES
--
-- Held pairs that fuse into something neither Grace does alone. These are not
-- offered; they are granted the moment their requirements are met, with a
-- deliberately loud announcement, because discovering one is the best moment a
-- run has.
--------------------------------------------------------------------------------

export type Synergy = {
	id: string,
	name: string,
	description: string,
	requires: { string },
	effect: any,
	color: Color3,
}

BoonConfig.Synergies = {
	{
		id = "Firestorm",
		name = "FIRESTORM",
		description = "Burning enemies trail fire as they move, and Winded enemies burn twice "
			.. "as fast.",
		requires = { "Cinder_Kindling", "Gale_Momentum" },
		effect = { kind = "Synergy_Firestorm", trailRadius = 8, windedBurnScale = 2 },
		color = Lore.ElementColor("Cinder"),
	},
	{
		id = "Shatterpoint",
		name = "SHATTERPOINT",
		description = "Freezing an enemy also Shocks everything within 20 studs. Shattering "
			.. "chains to them.",
		requires = { "Rime_Tally", "Skein_Throughline" },
		effect = { kind = "Synergy_Shatterpoint", radius = 20 },
		color = Lore.ElementColor("Rime"),
	},
	{
		id = "SoulDrain",
		name = "SOUL DRAIN",
		description = "Your afterimages heal you for a third of what they deal, and Marked "
			.. "enemies bleed.",
		requires = { "Hush_Afterimage", "Marrow_Toll" },
		effect = { kind = "Synergy_SoulDrain", lifestealRatio = 0.33 },
		color = Lore.ElementColor("Hush"),
	},
	{
		id = "Rotwind",
		name = "ROTWIND",
		description = "Blight spreads to everything you dash through, and Haste makes it tick "
			.. "faster.",
		requires = { "Blight_Patience", "Gale_Unstill" },
		effect = { kind = "Synergy_Rotwind", dashRadius = 10, hasteTickScale = 1.5 },
		color = Lore.ElementColor("Blight"),
	},
	{
		id = "Deadweight",
		name = "DEADWEIGHT",
		description = "Heavy attacks against Frozen or staggered enemies always critically "
			.. "strike, and refund half your ability.",
		requires = { "Common_Counterweight", "Rime_Shatter" },
		effect = { kind = "Synergy_Deadweight", cooldownRefund = 0.5 },
		color = Color3.fromRGB(230, 200, 160),
	},
	{
		id = "Groundswell",
		name = "GROUNDSWELL",
		description = "Chains detonate the ground where they land, and your ability's shock "
			.. "leaves a lingering field.",
		requires = { "Skein_Discharge", "Cinder_Forgehand" },
		effect = { kind = "Synergy_Groundswell", zoneDuration = 5 },
		color = Lore.ElementColor("Skein"),
	},
}

--------------------------------------------------------------------------------
-- Accessors
--------------------------------------------------------------------------------

function BoonConfig.Get(boonId: string): Boon?
	return B[boonId]
end

--- Resolved numbers for a Grace at a given rarity, or nil if it cannot roll there.
function BoonConfig.ValuesFor(boonId: string, rarity: Rarity): { number }?
	local boon = B[boonId]
	return boon and boon.values[rarity]
end

--- Rarities a Grace is allowed to roll at.
function BoonConfig.AvailableRarities(boonId: string): { Rarity }
	local boon = B[boonId]
	if not boon then
		return {}
	end
	local result = {}
	for _, rarity in { "Common", "Rare", "Epic", "Legendary" } do
		if boon.values[rarity :: Rarity] then
			table.insert(result, rarity)
		end
	end
	return result
end

--- Renders a Grace's description with its rolled numbers substituted in.
function BoonConfig.Describe(boonId: string, rarity: Rarity): string
	local boon = B[boonId]
	if not boon then
		return ""
	end
	local values = boon.values[rarity]
	if not values then
		return boon.description
	end

	local index = 0
	local text = boon.description:gsub("{}", function()
		index += 1
		local value = values[index]
		if value == nil then
			return "?"
		end
		-- Trim trailing zeros so 4.5 stays 4.5 but 60.0 reads as 60.
		return (("%.2f"):format(value):gsub("%.?0+$", ""))
	end)
	return text
end

function BoonConfig.RarityColor(rarity: Rarity): Color3
	return GameConfig.Boons.RarityColors[rarity] or GameConfig.Boons.RarityColors.Common
end

--- All Graces belonging to one of the Faded.
function BoonConfig.ByFaded(fadedId: string): { Boon }
	local result = {}
	for _, boon in B do
		if boon.faded == fadedId then
			table.insert(result, boon)
		end
	end
	table.sort(result, function(a, b)
		return a.id < b.id
	end)
	return result
end

--- Synergies whose requirements are all satisfied by `heldBoonIds` (a set).
function BoonConfig.MatchedSynergies(heldBoonIds: { [string]: any }): { Synergy }
	local matched = {}
	for _, synergy in BoonConfig.Synergies do
		local satisfied = true
		for _, required in synergy.requires do
			if not heldBoonIds[required] then
				satisfied = false
				break
			end
		end
		if satisfied then
			table.insert(matched, synergy)
		end
	end
	return matched
end

--[[
	Boot-time sanity pass. Catches the two mistakes that are easy to make in a
	file this size: a `requires`/`conflicts`/synergy entry naming a Grace that does
	not exist, and a description whose placeholder count does not match the numbers
	supplied for some rarity (which would render as "?" in game).
]]
function BoonConfig.Validate(): { string }
	local problems = {}

	for id, boon in B do
		if boon.id ~= id then
			table.insert(problems, ("%s has mismatched id field %q"):format(id, boon.id))
		end
		if not Lore.Faded[boon.faded] then
			table.insert(problems, ("%s belongs to unknown Faded %q"):format(id, boon.faded))
		end

		local _, placeholders = boon.description:gsub("{}", "")
		for rarity, values in boon.values do
			if #values ~= placeholders then
				table.insert(
					problems,
					("%s/%s supplies %d values for %d placeholders")
						:format(id, rarity, #values, placeholders)
				)
			end
		end

		if boon.requires and boon.requires.boon and not B[boon.requires.boon] then
			table.insert(problems, ("%s requires unknown Grace %q"):format(id, boon.requires.boon))
		end
		for _, conflict in boon.conflicts or {} do
			if not B[conflict] then
				table.insert(problems, ("%s conflicts with unknown Grace %q"):format(id, conflict))
			end
		end
		if next(boon.values) == nil then
			table.insert(problems, id .. " has no rarity rows and can never roll")
		end
	end

	for _, synergy in BoonConfig.Synergies do
		for _, required in synergy.requires do
			if not B[required] then
				table.insert(problems, ("synergy %s requires unknown Grace %q"):format(synergy.id, required))
			end
		end
	end

	return problems
end

return BoonConfig
