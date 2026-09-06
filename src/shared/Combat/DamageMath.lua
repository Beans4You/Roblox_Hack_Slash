--!strict
--[[
	DamageMath — the damage pipeline, as pure functions.

	Every point of damage in this game goes through Resolve(). Having exactly one
	path means the order of operations is a fact rather than an accident, and it
	means a Grace, a Temper, a Keepsake and an elite modifier can all stack without
	anyone having to reason about which one applies first.

	THE ORDER, AND WHY

	  1. base            weapon baseDamage x swing multiplier
	  2. mastery         weapon-level scaling
	  3. additive        all "+X% damage" sources summed, then applied once
	  4. positional      backstab / weak point / status-conditional bonuses
	  5. critical        rolled here so crit multiplies everything above it
	  6. multiplicative  the few true multipliers: stagger bonus, phase scaling
	  7. defensive       target armour, frontal block, damage-taken statuses
	  8. global          GlobalDamageScale, run scaling, heat

	Step 3 is additive on purpose. If every Grace multiplied, four damage Graces
	would be 4x and eight would be 16x, and the game would fall apart at exactly
	the point it is meant to get interesting. Summing keeps late-run builds strong
	without making them incoherent, and reserves multiplication for the handful of
	moments that should feel enormous.
]]

local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local CombatEnums = require(script.Parent.CombatEnums)

local DamageMath = {}

export type DamageContext = {
	-- Step 1
	baseDamage: number,
	swingMultiplier: number,

	-- Step 2
	masteryScale: number?,

	-- Step 3: summed. 0.15 means +15%.
	additiveBonuses: { number }?,

	-- Step 4
	positionalBonus: number?,

	-- Step 5
	critChance: number?,
	critMultiplier: number?,
	forceCrit: boolean?,

	-- Step 6: multiplied together.
	multipliers: { number }?,

	-- Step 7
	targetDamageTakenMultiplier: number?,
	targetArmor: number?,
	blockedFrontally: boolean?,
	blockReduction: number?,

	-- Step 8
	runScale: number?,
	heatScale: number?,

	-- Reporting only.
	element: string?,
	attackType: string?,
}

export type DamageResult = {
	amount: number,
	critical: boolean,
	element: string,
	result: string,
	-- Set when the number was reduced, so feedback can show it differently.
	mitigated: boolean,
}

local function sum(values: { number }?): number
	local total = 0
	for _, value in values or {} do
		total += value
	end
	return total
end

local function product(values: { number }?): number
	local total = 1
	for _, value in values or {} do
		total *= value
	end
	return total
end

--- The whole pipeline. `rng` is optional; supplying the run's stream keeps crits
--- deterministic for a given seed, which is what makes runs reproducible.
function DamageMath.Resolve(context: DamageContext, rng: any?): DamageResult
	-- 1. Base
	local amount = context.baseDamage * (context.swingMultiplier or 1)

	-- 2. Mastery
	amount *= (context.masteryScale or 1)

	-- 3. Additive bonuses, summed then applied once.
	amount *= (1 + sum(context.additiveBonuses))

	-- 4. Positional / conditional
	amount *= (1 + (context.positionalBonus or 0))

	-- 5. Critical
	local critical = context.forceCrit == true
	if not critical and (context.critChance or 0) > 0 then
		local roll = rng and rng:Float() or math.random()
		critical = roll < (context.critChance or 0)
	end
	if critical then
		amount *= (context.critMultiplier or 1.75)
	end

	-- 6. True multipliers
	amount *= product(context.multipliers)

	-- 7. Defensive
	local mitigated = false
	if context.blockedFrontally then
		amount *= (1 - (context.blockReduction or 0.8))
		mitigated = true
	end
	if context.targetArmor and context.targetArmor > 0 then
		-- Diminishing armour: 100 armour halves damage, 300 quarters it. Never
		-- reaches zero, so nothing in the game can become unkillable.
		amount *= 100 / (100 + context.targetArmor)
		mitigated = true
	end
	amount *= (context.targetDamageTakenMultiplier or 1)

	-- 8. Global
	amount *= GameConfig.Combat.GlobalDamageScale
	amount *= (context.runScale or 1)
	amount *= (context.heatScale or 1)

	amount = math.max(1, amount)

	return {
		-- Whole numbers only: fractional damage is noise on a damage number.
		amount = math.floor(amount + 0.5),
		critical = critical,
		element = context.element or "Physical",
		result = critical and CombatEnums.HitResult.Critical or CombatEnums.HitResult.Hit,
		mitigated = mitigated,
	}
end

--------------------------------------------------------------------------------
-- Poise / stagger
--------------------------------------------------------------------------------

--[[
	Stagger is a separate resource from health so that a weapon can be good at
	breaking things without being good at killing them. Grudge does roughly 2.5x
	Vigil's poise damage at similar DPS, and that difference is the whole reason to
	pick it.
]]
function DamageMath.ResolvePoise(basePoise: number, weaponPoiseScale: number, bonuses: { number }?): number
	return basePoise * (weaponPoiseScale or 1) * (1 + sum(bonuses))
end

--- Enemy poise decays toward zero when it is not being hit, so chip damage from
--- across the room never adds up into a stagger.
function DamageMath.DecayPoise(current: number, deltaTime: number): number
	return math.max(0, current - GameConfig.Combat.StaggerDecayPerSecond * deltaTime)
end

--------------------------------------------------------------------------------
-- Run scaling
--------------------------------------------------------------------------------

--- Enemy health and damage growth across a run. Linear rather than exponential:
--- the difficulty should come from the room and the enemy mix, not from the
--- numbers running away.
function DamageMath.RunScaling(roomIndex: number, regionDifficulty: number): (number, number)
	local health = (1 + roomIndex * GameConfig.Run.HealthScalePerRoom) * regionDifficulty
	local damage = (1 + roomIndex * GameConfig.Run.DamageScalePerRoom) * regionDifficulty
	return health, damage
end

--- Reward multiplier for a chosen heat level.
function DamageMath.HeatReward(heat: number): number
	return 1 + math.clamp(heat, 0, GameConfig.Run.MaxHeat) * GameConfig.Run.RewardPerHeat
end

--------------------------------------------------------------------------------
-- Knockback
--------------------------------------------------------------------------------

--- Heavier things move less. Weight is a per-enemy stat, so Grudge's enormous
--- knockback is genuinely useful against Cutters and nearly wasted on a Drudge.
function DamageMath.ResolveKnockback(baseKnockback: number, targetWeight: number, staggered: boolean): number
	local amount = baseKnockback / math.max(0.25, targetWeight)
	if staggered then
		-- Staggered things have no footing.
		amount *= 1.6
	end
	return amount
end

return DamageMath
