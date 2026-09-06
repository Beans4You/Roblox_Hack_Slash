--!strict
--[[
	MasteryConfig — per-weapon progression earned by using the weapon.

	The brief is specific: mastery must reward *using* a weapon, not spending
	currency on it. So mastery experience comes only from things you can do with
	the weapon in hand, and the rewards are moveset changes rather than numbers --
	a new cancel, an extra combo step, a finisher variant.

	The intent is that hitting Vigil 10 changes what you do with Vigil, so that a
	player who has mastered one weapon has a concrete reason to start over with
	another rather than an abstract one.
]]

export type MasteryReward = {
	level: number,
	kind: string,
	name: string,
	description: string,
	payload: any?,
}

local MasteryConfig = {}

MasteryConfig.MaxLevel = 30

--[[
	Experience sources. Deliberately weighted toward *hard* uses of the weapon:
	a perfect parry is worth thirty light hits, because the point is to pull the
	player toward the top of the weapon's skill range, not the bottom.
]]
MasteryConfig.Experience = {
	LightHit = 1,
	HeavyHit = 3,
	AbilityHit = 5,
	UltimateHit = 4,
	EnemyKill = 12,
	EliteKill = 60,
	MiniBossKill = 140,
	BossKill = 500,
	PerfectParry = 30,
	Finisher = 25,
	-- Paid once per room, for clearing it without being hit.
	FlawlessRoom = 80,
	-- Paid at the end of a run, scaled by rooms cleared.
	RunCompletionPerRoom = 20,
}

--[[
	Level curve. Quadratic-ish: level 5 arrives inside the first couple of runs
	with a weapon, level 15 takes real commitment, level 30 is a statement.
]]
function MasteryConfig.ExperienceForLevel(level: number): number
	if level <= 1 then
		return 0
	end
	local n = level - 1
	return math.floor(220 * n + 46 * n * n)
end

function MasteryConfig.LevelForExperience(experience: number): (number, number, number)
	local level = 1
	while level < MasteryConfig.MaxLevel and experience >= MasteryConfig.ExperienceForLevel(level + 1) do
		level += 1
	end
	local currentFloor = MasteryConfig.ExperienceForLevel(level)
	local nextFloor = MasteryConfig.ExperienceForLevel(math.min(level + 1, MasteryConfig.MaxLevel))
	local into = experience - currentFloor
	local span = math.max(nextFloor - currentFloor, 1)
	return level, into, span
end

--[[
	Reward tracks. Every weapon uses the same level gates so the UI is predictable,
	but the payload at each gate is weapon-specific.
]]
MasteryConfig.Gates = { 3, 5, 8, 10, 12, 15, 20, 25, 30 }

MasteryConfig.Tracks = {
	Vigil = {
		{ level = 3, kind = "Stat", name = "TEMPERED", description = "Vigil deals 6% more damage.", payload = { damageScale = 1.06 } },
		{ level = 5, kind = "Temper", name = "WARDEN'S TEMPER", description = "Unlocks the Warden's Temper at Halvic's.", payload = { temper = "Vigil_Warden" } },
		{ level = 8, kind = "Combo", name = "THE FIFTH", description = "Adds a fifth swing to the light chain: a rising cut that launches.", payload = { extraSwing = "launcher" } },
		{ level = 10, kind = "Temper", name = "QUICK TEMPER", description = "Unlocks the Quick Temper at Halvic's.", payload = { temper = "Vigil_Quick" } },
		{ level = 12, kind = "Ability", name = "SECOND LINE", description = "HOLD THE LINE may be held to extend its guard by one second.", payload = { abilityHold = 1.0 } },
		{ level = 15, kind = "Temper", name = "RIPOSTE TEMPER", description = "Unlocks the Riposte Temper at Halvic's.", payload = { temper = "Vigil_Riposte" } },
		{ level = 20, kind = "Finisher", name = "THE GATE CLOSES", description = "A new finisher: a two-part execution that resets your ability.", payload = { finisher = "GateCloses" } },
		{ level = 25, kind = "Ultimate", name = "UNBROKEN, TWICE", description = "UNBROKEN gains a fourth rotation and heals for double.", payload = { ultimateVariant = "Twice" } },
		{ level = 30, kind = "Cosmetic", name = "VIGIL'S AURA", description = "A standing aura, visible in the hub, that only Vigil 30 grants.", payload = { cosmetic = "Aura_Vigil" } },
	},
	Grudge = {
		{ level = 3, kind = "Stat", name = "SEATED", description = "Grudge builds 10% more stagger.", payload = { poiseScale = 1.10 } },
		{ level = 5, kind = "Temper", name = "MOMENTUM TEMPER", description = "Unlocks the Momentum Temper at Halvic's.", payload = { temper = "Grudge_Momentum" } },
		{ level = 8, kind = "Combo", name = "THE RETURN", description = "The third swing may be held to wind up a second rotation.", payload = { holdSwing = 3 } },
		{ level = 10, kind = "Temper", name = "BULWARK TEMPER", description = "Unlocks the Bulwark Temper at Halvic's.", payload = { temper = "Grudge_Bulwark" } },
		{ level = 12, kind = "Ability", name = "DEEPER REAP", description = "REAP's pull reaches 40% further and holds enemies for a moment.", payload = { pullScale = 1.4, holdTime = 0.4 } },
		{ level = 15, kind = "Temper", name = "LANDSLIDE TEMPER", description = "Unlocks the Landslide Temper at Halvic's.", payload = { temper = "Grudge_Landslide" } },
		{ level = 20, kind = "Finisher", name = "THE LAST WORD", description = "A new finisher that also staggers everything within 20 studs.", payload = { finisher = "LastWord" } },
		{ level = 25, kind = "Ultimate", name = "SETTLED, DEEPER", description = "SETTLED's crater lasts twice as long and pulls.", payload = { ultimateVariant = "Deeper" } },
		{ level = 30, kind = "Cosmetic", name = "GRUDGE'S AURA", description = "A standing aura that only Grudge 30 grants.", payload = { cosmetic = "Aura_Grudge" } },
	},
	Quarrel = {
		{ level = 3, kind = "Stat", name = "HONED", description = "Quarrel's cancel windows open 10% earlier.", payload = { cancelScale = 0.9 } },
		{ level = 5, kind = "Temper", name = "BLEEDING TEMPER", description = "Unlocks the Bleeding Temper at Halvic's.", payload = { temper = "Quarrel_Bleed" } },
		{ level = 8, kind = "Combo", name = "THE SIXTH AND SEVENTH", description = "Two more swings after the spin, both airborne.", payload = { extraSwing = "airPair" } },
		{ level = 10, kind = "Temper", name = "AIRBORNE TEMPER", description = "Unlocks the Airborne Temper at Halvic's.", payload = { temper = "Quarrel_Airborne" } },
		{ level = 12, kind = "Ability", name = "TWICE OVER", description = "SPLIT SECOND may be used again within two seconds at half cooldown.", payload = { abilityCharges = 2, secondChargeWindow = 2 } },
		{ level = 15, kind = "Temper", name = "TWINNED TEMPER", description = "Unlocks the Twinned Temper at Halvic's.", payload = { temper = "Quarrel_Twinned" } },
		{ level = 20, kind = "Finisher", name = "NINE CUTS", description = "A new finisher: nine hits, and the last one is a throw.", payload = { finisher = "NineCuts" } },
		{ level = 25, kind = "Ultimate", name = "THE ARGUMENT, EXTENDED", description = "Your ultimate lasts 50% longer and follows targets.", payload = { ultimateVariant = "Extended" } },
		{ level = 30, kind = "Cosmetic", name = "QUARREL'S AURA", description = "A standing aura that only Quarrel 30 grants.", payload = { cosmetic = "Aura_Quarrel" } },
	},
	Thresh = {
		{ level = 3, kind = "Stat", name = "MEASURED", description = "Thresh's thrusts reach 8% further.", payload = { rangeScale = 1.08 } },
		{ level = 5, kind = "Temper", name = "LONGREACH TEMPER", description = "Unlocks the Longreach Temper at Halvic's.", payload = { temper = "Thresh_Longreach" } },
		{ level = 8, kind = "Combo", name = "THE STEP BACK", description = "The sweep may be cancelled into a backstep that keeps the hitbox.", payload = { extraSwing = "backstep" } },
		{ level = 10, kind = "Temper", name = "TETHER TEMPER", description = "Unlocks the Tether Temper at Halvic's.", payload = { temper = "Thresh_Tether" } },
		{ level = 12, kind = "Ability", name = "CALLED SHOT", description = "CAST may be aimed, and a pinned enemy takes 30% more from everything.", payload = { aimable = true, pinnedVulnerability = 0.3 } },
		{ level = 15, kind = "Temper", name = "VOLLEY TEMPER", description = "Unlocks the Volley Temper at Halvic's.", payload = { temper = "Thresh_Volley" } },
		{ level = 20, kind = "Finisher", name = "THE LONG ANSWER", description = "A new finisher that impales and throws the body twice as far.", payload = { finisher = "LongAnswer" } },
		{ level = 25, kind = "Ultimate", name = "HARVEST, WIDER", description = "HARVEST covers a second, outer ring.", payload = { ultimateVariant = "Wider" } },
		{ level = 30, kind = "Cosmetic", name = "THRESH'S AURA", description = "A standing aura that only Thresh 30 grants.", payload = { cosmetic = "Aura_Thresh" } },
	},
}

function MasteryConfig.RewardsFor(weaponId: string): { MasteryReward }
	return MasteryConfig.Tracks[weaponId] or {}
end

--- Rewards unlocked by crossing from `oldLevel` to `newLevel`.
function MasteryConfig.RewardsBetween(weaponId: string, oldLevel: number, newLevel: number): { MasteryReward }
	local unlocked = {}
	for _, reward in MasteryConfig.RewardsFor(weaponId) do
		if reward.level > oldLevel and reward.level <= newLevel then
			table.insert(unlocked, reward)
		end
	end
	return unlocked
end

--- Everything a weapon has earned at its current level, folded into one table the
--- combat system can read without walking the track every swing.
function MasteryConfig.ResolveModifiers(weaponId: string, level: number): { [string]: any }
	local modifiers = {}
	for _, reward in MasteryConfig.RewardsFor(weaponId) do
		if reward.level <= level and reward.payload then
			for key, value in reward.payload do
				modifiers[key] = value
			end
		end
	end
	return modifiers
end

function MasteryConfig.Validate(): { string }
	local problems = {}
	for weaponId, track in MasteryConfig.Tracks do
		local previous = 0
		for _, reward in track do
			if reward.level <= previous then
				table.insert(problems, ("%s mastery track is out of order at level %d"):format(weaponId, reward.level))
			end
			previous = reward.level
			if not table.find(MasteryConfig.Gates, reward.level) then
				table.insert(problems, ("%s has a reward at level %d, which is not a gate"):format(weaponId, reward.level))
			end
		end
	end
	return problems
end

return MasteryConfig
