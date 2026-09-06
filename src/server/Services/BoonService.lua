--!strict
--[[
	BoonService — offering Graces, and making them do things.

	Two halves.

	OFFERS
	A shrine rolls three Graces. The roller is weighted toward Faded the player has
	already taken from, because a run should converge into a build rather than
	scatter across seven elements. It respects `requires` and `conflicts`, never
	offers the same Grace twice, and prefers Graces whose trigger the player's
	current build actually pulls -- offering three on-parry Graces to somebody who
	has not parried all run is technically random and practically useless.

	RUNTIME
	Every Grace declares an effect `kind`. This file has one handler per kind,
	grouped by the hook it runs on. CombatService calls the hooks; it knows nothing
	about Graces. Adding a Grace that reuses an existing kind is a config edit with
	no code at all, which is the entire point of the split.

	AGGREGATES
	Passive modifiers (crit chance, dodge distance, +damage to light attacks) are
	folded into one table whenever the held set changes, not recomputed per swing.
	The hot path reads fields; it does not iterate.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local GameConfig = require(Shared.Config.GameConfig)
local BoonConfig = require(Shared.Config.BoonConfig)
local StatusConfig = require(Shared.Config.StatusConfig)
local Lore = require(Shared.Config.Lore)
local Hitbox = require(Shared.Combat.Hitbox)
local Rng = require(Shared.Util.Rng)
local Net = require(Shared.Net.Net)
local Signal = require(Shared.Util.Signal)

local BoonService = {}

BoonService.BoonTaken = Signal.new()
BoonService.SynergyFound = Signal.new()

local registry: any = nil

export type HeldBoon = {
	boonId: string,
	rarity: string,
	values: { number },
	config: any,
}

export type BoonState = {
	player: Player,
	held: { HeldBoon },
	heldSet: { [string]: HeldBoon },
	fadedCounts: { [string]: number },
	synergies: { [string]: boolean },
	rerolls: number,

	-- Precomputed passive aggregate.
	aggregate: any,

	-- Runtime counters used by trigger effects.
	hitStreak: number,
	roomShieldUsed: boolean,
	emergencyHealUsed: boolean,
	chargedReady: boolean,
	lastMovedAt: number,
	lastStillAt: number,
	lastDodgeAt: number,
	perTargetHits: { [any]: number },

	-- The current shrine's offer, if one is open.
	pendingOffer: { any }?,
	pendingResolve: any?,
	-- Next time HOARFROST may spread / FIRESTORM may catch.
	nextSpreadAt: number?,
	nextFirestormAt: number?,
}

local states: { [Player]: BoonState } = {}

local function newAggregate()
	return {
		lightDamage = 0,
		heavyDamage = 0,
		abilityDamage = 0,
		allDamage = 0,
		heavyPoise = 0,
		critChance = 0,
		critMultiplier = 1.75,
		dodgeDistanceBonus = 0,
		dodgeIframeBonus = 0,
		dodgeCostReduction = 0,
		ultimateChargeBonus = 0,
		ultimateCostReduction = 0,
		movingDamage = 0,
		chargedBonus = 0,
		chargedStillTime = math.huge,
		belowHalfDamage = 0,
		aboveHalfPenalty = 0,
		vsStatus = {} :: { [string]: number },
		behindMarkedBonus = 0,
		chainExtraRadius = 0,
		chainAllowRevisit = false,
		perTargetBonus = 0,
		perTargetMax = 0,
		-- statusId -> { tickRateScale, noExpireInCombat }
		statusTuning = {} :: { [string]: any },
	}
end

--------------------------------------------------------------------------------
-- Aggregate
--------------------------------------------------------------------------------

--[[
	Recomputes the passive table. Called on take, never per swing.

	Note the additive stacking: two Graces that each add 20% damage produce +40%,
	not +44%. DamageMath sums these deliberately; see the comment there for why.
]]
local function recomputeAggregate(state: BoonState)
	local aggregate = newAggregate()

	for _, held in state.held do
		local effect = held.config.effect
		local values = held.values

		if effect.kind == "AttackTypeDamage" then
			local bonus = values[effect.bonusIndex] / 100
			if effect.attackType == "Light" then
				aggregate.lightDamage += bonus
			elseif effect.attackType == "Heavy" then
				aggregate.heavyDamage += bonus
				if effect.poiseIndex then
					aggregate.heavyPoise += values[effect.poiseIndex] / 100
				end
			end
		elseif effect.kind == "CritLifesteal" then
			aggregate.critChance += values[effect.critChanceIndex] / 100
		elseif effect.kind == "DodgeModifier" then
			aggregate.dodgeDistanceBonus += values[effect.distanceIndex] / 100
			aggregate.dodgeIframeBonus += values[effect.iframeIndex] / 100
		elseif effect.kind == "UltimateModifier" then
			aggregate.ultimateChargeBonus += values[effect.chargeIndex] / 100
			aggregate.ultimateCostReduction += values[effect.costIndex] / 100
		elseif effect.kind == "MovingDamage" then
			aggregate.movingDamage += values[effect.bonusIndex] / 100
		elseif effect.kind == "ChargedNextHit" then
			aggregate.chargedBonus += values[effect.bonusIndex] / 100
			aggregate.chargedStillTime = math.min(aggregate.chargedStillTime, effect.stillTime)
		elseif effect.kind == "HealthThresholdDamage" then
			aggregate.belowHalfDamage += values[effect.belowIndex] / 100
			aggregate.aboveHalfPenalty += values[effect.aboveIndex] / 100
		elseif effect.kind == "DamageVsStatus" then
			aggregate.vsStatus[effect.status] = (aggregate.vsStatus[effect.status] or 0)
				+ values[effect.bonusIndex] / 100
		elseif effect.kind == "PositionalBonus" then
			aggregate.behindMarkedBonus += values[effect.bonusIndex] / 100
		elseif effect.kind == "ChainModifier" then
			aggregate.chainExtraRadius += values[effect.extraRadiusIndex]
			aggregate.chainAllowRevisit = aggregate.chainAllowRevisit or effect.allowRevisit == true
		elseif effect.kind == "PerTargetBonus" then
			aggregate.perTargetBonus += values[effect.bonusIndex] / 100
			aggregate.perTargetMax = math.max(aggregate.perTargetMax, effect.maxStacks)
		elseif effect.kind == "StatusModifier" then
			local tuning = aggregate.statusTuning[effect.status] or {}
			if effect.tickRateIndex then
				tuning.tickRateScale = 1 + values[effect.tickRateIndex] / 100
			end
			if effect.noExpireInCombat then
				tuning.noExpireInCombat = true
			end
			aggregate.statusTuning[effect.status] = tuning
		end
	end

	state.aggregate = aggregate

	local combatant = registry.CombatService.GetByPlayer(state.player)
	if combatant then
		registry.CombatService.SetModifiers(combatant.character, aggregate)
	end
end

--------------------------------------------------------------------------------
-- Offers
--------------------------------------------------------------------------------

local function rarityFor(rng: any, boonId: string, luck: number): string?
	local available = BoonConfig.AvailableRarities(boonId)
	if #available == 0 then
		return nil
	end

	local entries = {}
	for _, rarity in available do
		local weight = GameConfig.Boons.RarityWeights[rarity] or 1
		-- Luck skews toward the top of whatever the Grace can roll.
		if rarity ~= "Common" then
			weight *= (1 + luck)
		end
		table.insert(entries, { rarity = rarity, weight = weight })
	end

	local chosen = rng:Weighted(entries, function(entry)
		return entry.weight
	end)
	return chosen and chosen.rarity or available[1]
end

--- Whether a Grace is legal to offer given what the player holds.
local function isOfferable(state: BoonState, boon: any, weaponTags: { string }): boolean
	if state.heldSet[boon.id] then
		return false
	end
	for _, conflict in boon.conflicts or {} do
		if state.heldSet[conflict] then
			return false
		end
	end
	local requires = boon.requires
	if requires then
		if requires.boon and not state.heldSet[requires.boon] then
			return false
		end
		if requires.element and (state.fadedCounts[requires.element] or 0) == 0 then
			return false
		end
		if requires.weaponTag and not table.find(weaponTags, requires.weaponTag) then
			return false
		end
	end
	return true
end

--[[
	Rolls a shrine offer.

	Faded the player has already taken from get a weight bonus, which is what turns
	a sequence of random picks into a build. Without it, a run of eight Graces is
	eight unrelated effects; with it, most runs converge on two or three elements
	and start producing synergies.
]]
function BoonService.RollOffer(player: Player, luck: number, rng: any): { any }
	local state = states[player]
	if not state then
		return {}
	end

	local combatant = registry.CombatService.GetByPlayer(player)
	local weaponTags = combatant and combatant.weapon and combatant.weapon.tags or {}

	local pool = {}
	for _, boon in BoonConfig.Boons do
		if isOfferable(state, boon, weaponTags) then
			local weight = 100
			local taken = state.fadedCounts[boon.faded] or 0
			if taken > 0 then
				weight *= GameConfig.Boons.RepeatFadedWeightBonus ^ math.min(taken, 3)
			end
			-- A Grace that completes a synergy is much likelier to appear. Finding
			-- one should feel like luck; it is mostly not.
			for _, synergy in BoonConfig.Synergies do
				if not state.synergies[synergy.id] and table.find(synergy.requires, boon.id) then
					local otherwiseHeld = true
					for _, required in synergy.requires do
						if required ~= boon.id and not state.heldSet[required] then
							otherwiseHeld = false
							break
						end
					end
					if otherwiseHeld then
						weight *= 3.5
					end
				end
			end
			table.insert(pool, { boon = boon, weight = weight })
		end
	end

	table.sort(pool, function(a, b)
		return a.boon.id < b.boon.id
	end)

	local offers = {}
	local chosenIds: { [string]: boolean } = {}

	for _ = 1, GameConfig.Boons.OffersPerShrine do
		local candidates = {}
		for _, entry in pool do
			if not chosenIds[entry.boon.id] then
				table.insert(candidates, entry)
			end
		end
		if #candidates == 0 then
			break
		end

		local chosen = rng:Weighted(candidates, function(entry)
			return entry.weight
		end)
		if not chosen then
			break
		end

		local rarity = rarityFor(rng, chosen.boon.id, luck)
		if rarity then
			chosenIds[chosen.boon.id] = true
			table.insert(offers, {
				boonId = chosen.boon.id,
				rarity = rarity,
				name = chosen.boon.name,
				faded = chosen.boon.faded,
				fadedName = Lore.Faded[chosen.boon.faded] and Lore.Faded[chosen.boon.faded].name or chosen.boon.faded,
				description = BoonConfig.Describe(chosen.boon.id, rarity),
				trigger = chosen.boon.trigger,
				color = BoonConfig.RarityColor(rarity),
				elementColor = Lore.ElementColor(chosen.boon.faded),
			})
		end
	end

	return offers
end

function BoonService.PresentOffer(player: Player, rng: any, luck: number)
	local state = states[player]
	if not state then
		return
	end

	local offers = BoonService.RollOffer(player, luck, rng)
	state.pendingOffer = offers

	local faded = offers[1] and Lore.Faded[offers[1].faded]
	Net.FireClient("BoonOffer", player, {
		offers = offers,
		rerolls = state.rerolls,
		greeting = faded and faded.greeting or nil,
		fadedName = faded and faded.name or nil,
	})
end

--------------------------------------------------------------------------------
-- Taking
--------------------------------------------------------------------------------

local function checkSynergies(state: BoonState)
	for _, synergy in BoonConfig.MatchedSynergies(state.heldSet) do
		if not state.synergies[synergy.id] then
			state.synergies[synergy.id] = true
			Net.FireClient("SynergyFound", state.player, {
				synergyId = synergy.id,
				name = synergy.name,
				description = synergy.description,
				color = synergy.color,
			})
			BoonService.SynergyFound:Fire(state.player, synergy.id)
		end
	end
end

function BoonService.Grant(player: Player, boonId: string, rarity: string): boolean
	local state = states[player]
	local config = BoonConfig.Get(boonId)
	if not state or not config then
		return false
	end
	if state.heldSet[boonId] then
		return false
	end

	local values = BoonConfig.ValuesFor(boonId, rarity :: any)
	if not values then
		return false
	end

	local held: HeldBoon = { boonId = boonId, rarity = rarity, values = values, config = config }
	table.insert(state.held, held)
	state.heldSet[boonId] = held
	state.fadedCounts[config.faded] = (state.fadedCounts[config.faded] or 0) + 1

	recomputeAggregate(state)
	checkSynergies(state)

	BoonService.BoonTaken:Fire(player, boonId, rarity)
	return true
end

function BoonService.HandleChoice(player: Player, payload: any)
	local state = states[player]
	if not state or not state.pendingOffer then
		return
	end

	if payload.reroll then
		if state.rerolls <= 0 then
			return
		end
		state.rerolls -= 1
		if state.pendingResolve then
			state.pendingResolve("reroll")
		end
		return
	end

	local index = tonumber(payload.index)
	local offer = index and state.pendingOffer[index]
	if not offer then
		return
	end

	BoonService.Grant(player, offer.boonId, offer.rarity)
	state.pendingOffer = nil
	if state.pendingResolve then
		state.pendingResolve("taken")
	end
end

--------------------------------------------------------------------------------
-- Effect handlers
--
-- One table per hook. Handlers receive (state, held, values, context).
--------------------------------------------------------------------------------

local Modify = {}
local OnHit = {}
local OnKill = {}
local OnDodgeEffects = {}
local OnParryEffects = {}
local OnDamagedEffects = {}
local OnAbilityEffects = {}

--------------------------------------------------------------------------------
-- Outgoing modification
--------------------------------------------------------------------------------

--- Applied once per hit, before damage is resolved.
function BoonService.ModifyOutgoing(attacker: any, target: any, context: any)
	local player = attacker.player
	local state = player and states[player]
	if not state then
		return
	end

	local aggregate = state.aggregate
	local bonuses = context.additiveBonuses

	if context.attackType == "Light" then
		table.insert(bonuses, aggregate.lightDamage)
	elseif context.attackType == "Heavy" then
		table.insert(bonuses, aggregate.heavyDamage)
		if aggregate.heavyPoise > 0 then
			context.poiseBonuses = context.poiseBonuses or {}
			table.insert(context.poiseBonuses, aggregate.heavyPoise)
		end
	end

	-- Status-conditional damage (BELLOWS and friends).
	for statusId, bonus in aggregate.vsStatus do
		if registry.StatusService.Has(target.character, statusId) then
			table.insert(bonuses, bonus)
		end
	end

	-- Positional.
	if aggregate.behindMarkedBonus > 0 and registry.StatusService.Has(target.character, "Marked") then
		if Hitbox.IsBehind(attacker.root.Position, target.root.CFrame) then
			table.insert(bonuses, aggregate.behindMarkedBonus)
		end
	end

	-- Movement-conditional.
	if aggregate.movingDamage > 0 then
		local speed = attacker.root.AssemblyLinearVelocity
		if Vector3.new(speed.X, 0, speed.Z).Magnitude > 4 then
			table.insert(bonuses, aggregate.movingDamage)
		end
	end

	-- Health-threshold (VESH'S WAGER).
	if aggregate.belowHalfDamage > 0 or aggregate.aboveHalfPenalty > 0 then
		local fraction = attacker.humanoid.Health / math.max(1, attacker.humanoid.MaxHealth)
		if fraction < 0.5 then
			table.insert(bonuses, aggregate.belowHalfDamage)
		else
			table.insert(bonuses, -aggregate.aboveHalfPenalty)
		end
	end

	-- The charged hit (AUDIT). Consumed here so it applies to exactly one hit.
	if state.chargedReady then
		state.chargedReady = false
		table.insert(bonuses, aggregate.chargedBonus)
		registry.StatusService.Apply(target.character, "Chill", {
			sourceDamage = context.baseDamage,
			source = attacker.character,
		})
	end

	-- Multi-target scaling (OVERRUN). Counts targets struck this swing so far.
	if aggregate.perTargetBonus > 0 then
		local struck = 0
		for _ in attacker.hitThisSwing do
			struck += 1
		end
		local stacks = math.clamp(struck - 1, 0, aggregate.perTargetMax)
		if stacks > 0 then
			table.insert(bonuses, aggregate.perTargetBonus * stacks)
		end
	end

	context.critChance = aggregate.critChance
	context.critMultiplier = aggregate.critMultiplier

	-- The Whetstone Keepsake and Deadweight synergy can force a crit.
	if state.synergies.Deadweight and context.attackType == "Heavy" then
		if registry.StatusService.Has(target.character, "Frozen") or os.clock() < target.staggerUntil then
			context.forceCrit = true
		end
	end
end

--------------------------------------------------------------------------------
-- OnHit handlers
--------------------------------------------------------------------------------

function OnHit.ApplyStatus(state: BoonState, held: HeldBoon, values: { number }, ctx: any)
	local effect = held.config.effect
	if effect.chance and effect.chance < 1 and math.random() > effect.chance then
		return
	end

	local stacks = if effect.stacksIndex then values[effect.stacksIndex] else (effect.stacks or 1)
	local potency = if effect.potencyIndex then values[effect.potencyIndex] / 100 else 1

	local durationScale = 1
	if effect.eliteDurationScale and (ctx.target.character:GetAttribute("IsElite") or ctx.target.character:GetAttribute("IsBoss")) then
		durationScale = effect.eliteDurationScale
	end

	local tuning = state.aggregate.statusTuning[effect.status]
	registry.StatusService.Apply(ctx.target.character, effect.status, {
		stacks = stacks,
		sourceDamage = ctx.result.amount * potency,
		source = ctx.attacker.character,
		durationScale = durationScale,
		tickRateScale = tuning and tuning.tickRateScale or nil,
		noExpireInCombat = tuning and tuning.noExpireInCombat or nil,
	})
end

--[[
	BLOOM. Once a target is saturated with a status, it bursts and passes half its
	stacks outward. Checked on hit rather than on a timer so the moment it goes off
	is attributable to something the player just did.
]]
function OnHit.StatusThresholdBurst(state: BoonState, held: HeldBoon, values: { number }, ctx: any)
	local effect = held.config.effect
	local stacks = registry.StatusService.Stacks(ctx.target.character, effect.status)
	if stacks < values[effect.thresholdIndex] then
		return
	end

	registry.StatusService.Remove(ctx.target.character, effect.status)
	local transferred = math.max(1, math.floor(stacks * effect.transferRatio))

	local nearby = Hitbox.Query(CFrame.new(ctx.target.root.Position), {
		shape = "Sphere",
		range = effect.radius,
		height = 14,
		maxTargets = 8,
	}, { ctx.attacker.character, ctx.target.character })

	for _, candidate in nearby do
		local combatant = registry.CombatService.Get(candidate.character)
		if combatant and combatant.team == "Enemy" and combatant.alive then
			registry.StatusService.Apply(candidate.character, effect.status, {
				stacks = transferred,
				sourceDamage = ctx.result.amount,
				source = ctx.attacker.character,
			})
		end
	end

	registry.CombatService.ApplyDamage(ctx.attacker, ctx.target, {
		baseDamage = ctx.result.amount * stacks * 0.25,
		swingMultiplier = 1,
		element = "Blight",
		shake = 0.8,
		suppressHooks = true,
	})
end

function OnHit.Chain(state: BoonState, held: HeldBoon, values: { number }, ctx: any)
	local effect = held.config.effect
	local jumps = values[effect.jumpsIndex]
	local ratio = values[effect.ratioIndex] / 100
	local radius = effect.radius + state.aggregate.chainExtraRadius

	local visited: { [Model]: boolean } = { [ctx.target.character] = true }
	local origin = ctx.target.root.Position
	local damage = ctx.result.amount * ratio

	for _ = 1, jumps do
		local candidates = Hitbox.Query(CFrame.new(origin), {
			shape = "Sphere",
			range = radius,
			height = 14,
			maxTargets = 8,
		}, { ctx.attacker.character })

		local next_ = nil
		for _, candidate in candidates do
			local combatant = registry.CombatService.Get(candidate.character)
			if combatant and combatant.team == "Enemy" and combatant.alive then
				if state.aggregate.chainAllowRevisit or not visited[candidate.character] then
					next_ = combatant
					break
				end
			end
		end
		if not next_ then
			break
		end

		visited[next_.character] = true
		origin = next_.root.Position

		registry.CombatService.ApplyDamage(ctx.attacker, next_, {
			baseDamage = damage,
			swingMultiplier = 1,
			element = "Skein",
			shake = 0.2,
			suppressHooks = true,
		})
		if effect.applies then
			registry.StatusService.Apply(next_.character, effect.applies, {
				sourceDamage = damage,
				source = ctx.attacker.character,
			})
		end

		-- GROUNDSWELL: every jump leaves a scorch mark that burns whatever is
		-- standing in it a moment later.
		if state.synergies.Groundswell then
			BoonService.SpawnGroundZone(ctx.attacker, origin, 8, damage * 0.5, 5, "Burn")
		end

		damage *= 0.85
	end
end

function OnHit.ConsumeStatus(state: BoonState, held: HeldBoon, values: { number }, ctx: any)
	local effect = held.config.effect
	if not registry.StatusService.Consume(ctx.target.character, effect.status) then
		return
	end

	local missing = ctx.target.humanoid.MaxHealth - ctx.target.humanoid.Health
	local damage = math.min(effect.cap or math.huge, missing * values[effect.missingHealthIndex] / 100)

	registry.CombatService.ApplyDamage(ctx.attacker, ctx.target, {
		baseDamage = damage,
		swingMultiplier = 1,
		element = "Rime",
		hitStop = 0.1,
		shake = 1.2,
		suppressHooks = true,
	})

	-- Shatterpoint: the shatter arcs to everything nearby.
	if state.synergies.Shatterpoint then
		local nearby = Hitbox.Query(CFrame.new(ctx.target.root.Position), {
			shape = "Sphere",
			range = 20,
			height = 14,
			maxTargets = 6,
		}, { ctx.attacker.character, ctx.target.character })
		for _, candidate in nearby do
			local combatant = registry.CombatService.Get(candidate.character)
			if combatant and combatant.team == "Enemy" then
				registry.StatusService.Apply(candidate.character, "Shock", {
					sourceDamage = damage * 0.4,
					source = ctx.attacker.character,
				})
			end
		end
	end
end

function OnHit.CritLifesteal(state: BoonState, held: HeldBoon, values: { number }, ctx: any)
	if not ctx.result.critical then
		return
	end
	registry.CombatService.Heal(ctx.attacker, values[held.config.effect.healIndex])
end

function OnHit.SelfStatus(state: BoonState, held: HeldBoon, values: { number }, ctx: any)
	local effect = held.config.effect
	registry.StatusService.Apply(ctx.attacker.character, effect.status, {
		source = ctx.attacker.character,
		durationScale = effect.duration and (effect.duration / 4) or 1,
	})
end

function OnHit.HitStreak(state: BoonState, held: HeldBoon, values: { number }, ctx: any)
	local effect = held.config.effect
	state.hitStreak += 1
	if state.hitStreak < values[effect.countIndex] then
		return
	end
	state.hitStreak = 0

	local targets = Hitbox.Query(CFrame.new(ctx.attacker.root.Position), {
		shape = "Sphere",
		range = 18,
		height = 12,
		maxTargets = 10,
	}, { ctx.attacker.character })

	for _, candidate in targets do
		local combatant = registry.CombatService.Get(candidate.character)
		if combatant and combatant.team == "Enemy" then
			registry.CombatService.ApplyDamage(ctx.attacker, combatant, {
				baseDamage = ctx.result.amount * effect.damageRatio,
				swingMultiplier = 1,
				element = "Gale",
				shake = 0.8,
				suppressHooks = true,
			})
			registry.StatusService.Apply(candidate.character, effect.applies, {
				sourceDamage = ctx.result.amount,
				source = ctx.attacker.character,
			})
		end
	end
end

function OnHit.GroundZone(state: BoonState, held: HeldBoon, values: { number }, ctx: any)
	local effect = held.config.effect
	local swing = ctx.context.swing
	if not swing or not swing.tags or not table.find(swing.tags, effect.onTag) then
		return
	end

	local position = ctx.target.root.Position
	local duration = values[effect.durationIndex]
	local expiresAt = os.clock() + duration

	task.spawn(function()
		while os.clock() < expiresAt do
			task.wait(effect.tickInterval)
			local inZone = Hitbox.Query(CFrame.new(position), {
				shape = "Sphere",
				range = effect.radius,
				height = 10,
				maxTargets = 8,
			}, { ctx.attacker.character })
			for _, candidate in inZone do
				local combatant = registry.CombatService.Get(candidate.character)
				if combatant and combatant.team == "Enemy" and combatant.alive then
					registry.CombatService.ApplyDamage(ctx.attacker, combatant, {
						baseDamage = ctx.result.amount * effect.tickRatio,
						swingMultiplier = 1,
						element = "Cinder",
						suppressHooks = true,
					})
					if effect.status then
						registry.StatusService.Apply(candidate.character, effect.status, {
							sourceDamage = ctx.result.amount * effect.tickRatio,
							source = ctx.attacker.character,
						})
					end
				end
			end
		end
	end)
end

--------------------------------------------------------------------------------
-- OnKill handlers
--------------------------------------------------------------------------------

function OnKill.DeathBurst(state: BoonState, held: HeldBoon, values: { number }, ctx: any)
	local effect = held.config.effect
	if effect.requiresStatus and not registry.StatusService.Has(ctx.target.character, effect.requiresStatus) then
		return
	end

	local damage = values[effect.damageIndex]
	local radius = values[effect.radiusIndex]
	local position = ctx.target.root.Position

	local targets = Hitbox.Query(CFrame.new(position), {
		shape = "Sphere",
		range = radius,
		height = 12,
		maxTargets = 10,
	}, { ctx.target.character })

	for _, candidate in targets do
		local combatant = registry.CombatService.Get(candidate.character)
		if combatant and combatant.team == "Enemy" and combatant.alive then
			registry.CombatService.ApplyDamage(ctx.attacker, combatant, {
				baseDamage = damage,
				swingMultiplier = 1,
				element = "Cinder",
				shake = 0.7,
				suppressHooks = true,
			})
			if effect.spreads then
				registry.StatusService.Apply(candidate.character, effect.spreads, {
					sourceDamage = damage,
					source = ctx.attacker.character,
				})
			end
		end
	end

	Net.FireAllClients("CombatFeedback", {
		kind = "Explosion",
		position = position,
		element = "Cinder",
		radius = radius,
		shake = 0.9,
	})
end

function OnKill.ApplyStatus(state: BoonState, held: HeldBoon, values: { number }, ctx: any)
	-- OPEN-HANDED heals when a bleeding enemy dies.
	local effect = held.config.effect
	if not effect.killHealIndex then
		return
	end
	if registry.StatusService.Has(ctx.target.character, effect.status) then
		registry.CombatService.Heal(ctx.attacker, values[effect.killHealIndex])
	end
end

--------------------------------------------------------------------------------
-- OnDodge handlers
--------------------------------------------------------------------------------

function OnDodgeEffects.DodgeEcho(state: BoonState, held: HeldBoon, values: { number }, ctx: any)
	local effect = held.config.effect
	local position = ctx.attacker.root.Position
	local damage = values[effect.damageIndex]

	local marker = Instance.new("Part")
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanQuery = false
	marker.Size = Vector3.new(effect.radius, 0.4, effect.radius)
	marker.Shape = Enum.PartType.Cylinder
	marker.Color = Lore.ElementColor("Hush")
	marker.Material = Enum.Material.Neon
	marker.Transparency = 0.5
	marker.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	marker.Parent = registry.World.Effects
	game:GetService("Debris"):AddItem(marker, effect.delay + 0.2)

	task.delay(effect.delay, function()
		local targets = Hitbox.Query(CFrame.new(position), {
			shape = "Sphere",
			range = effect.radius,
			height = 12,
			maxTargets = 8,
		}, { ctx.attacker.character })

		local dealt = 0
		for _, candidate in targets do
			local combatant = registry.CombatService.Get(candidate.character)
			if combatant and combatant.team == "Enemy" and combatant.alive then
				local result = registry.CombatService.ApplyDamage(ctx.attacker, combatant, {
					baseDamage = damage,
					swingMultiplier = 1,
					element = "Hush",
					shake = 0.5,
					suppressHooks = true,
				})
				if result then
					dealt += result.amount
				end
				if effect.applies then
					registry.StatusService.Apply(candidate.character, effect.applies, {
						sourceDamage = damage,
						source = ctx.attacker.character,
					})
				end
			end
		end

		-- Soul Drain: the echo feeds you.
		if state.synergies.SoulDrain and dealt > 0 then
			registry.CombatService.Heal(ctx.attacker, dealt * 0.33)
		end
	end)
end

function OnDodgeEffects.DodgeWindow(state: BoonState, held: HeldBoon, values: { number }, ctx: any)
	local effect = held.config.effect
	state.lastDodgeAt = os.clock()
	if effect.refundStamina then
		ctx.attacker.stamina = math.min(
			GameConfig.Player.BaseMaxStamina,
			ctx.attacker.stamina + GameConfig.Combat.DodgeCost
		)
	end
	if effect.superArmor then
		ctx.attacker.superArmorUntil = math.max(ctx.attacker.superArmorUntil, os.clock() + values[effect.windowIndex])
	end
end

--------------------------------------------------------------------------------
-- OnParry / OnDamaged / OnAbility handlers
--------------------------------------------------------------------------------

function OnParryEffects.ParryCounter(state: BoonState, held: HeldBoon, values: { number }, ctx: any)
	local effect = held.config.effect
	local attacker = ctx.other
	if attacker then
		registry.CombatService.ApplyDamage(ctx.attacker, attacker, {
			baseDamage = values[effect.damageIndex],
			swingMultiplier = 1,
			element = "Physical",
			hitStop = 0.1,
			shake = 1.0,
			suppressHooks = true,
		})
		if effect.applies then
			registry.StatusService.Apply(attacker.character, effect.applies, {
				sourceDamage = values[effect.damageIndex],
				source = ctx.attacker.character,
			})
		end
	end

	local refund = values[effect.cooldownRefundIndex] / 100
	if refund > 0 then
		local readyAt = ctx.attacker.cooldowns.ability or 0
		local remaining = math.max(0, readyAt - os.clock())
		ctx.attacker.cooldowns.ability = os.clock() + remaining * (1 - refund)
	end
end

function OnDamagedEffects.RoomShield(state: BoonState, held: HeldBoon, values: { number }, ctx: any)
	if state.roomShieldUsed then
		return
	end
	state.roomShieldUsed = true

	-- Absorbing is retroactive: the damage already landed, so we hand it back and
	-- grant brief invulnerability rather than trying to intercept the hit.
	registry.CombatService.Heal(ctx.attacker, ctx.amount)
	registry.CombatService.GrantInvulnerability(ctx.attacker, 0.6)

	local effect = held.config.effect
	for _ = 1, values[effect.stacksIndex] do
		registry.StatusService.Apply(ctx.attacker.character, effect.grantsStatus, {
			source = ctx.attacker.character,
		})
	end
end

function OnDamagedEffects.EmergencyHeal(state: BoonState, held: HeldBoon, values: { number }, ctx: any)
	if state.emergencyHealUsed then
		return
	end
	local effect = held.config.effect
	local fraction = ctx.attacker.humanoid.Health / math.max(1, ctx.attacker.humanoid.MaxHealth)
	if fraction > effect.threshold then
		return
	end

	state.emergencyHealUsed = true
	registry.CombatService.Heal(ctx.attacker, values[effect.healIndex])
	registry.CombatService.GrantInvulnerability(ctx.attacker, effect.invulnerability)
end

function OnAbilityEffects.AreaStatus(state: BoonState, held: HeldBoon, values: { number }, ctx: any)
	local effect = held.config.effect
	local radius = values[effect.radiusIndex]

	local targets = Hitbox.Query(CFrame.new(ctx.attacker.root.Position), {
		shape = "Sphere",
		range = radius,
		height = 14,
		maxTargets = 10,
	}, { ctx.attacker.character })

	local baseDamage = (ctx.attacker.weapon and ctx.attacker.weapon.stats.baseDamage or 10) * effect.damageRatio

	for _, candidate in targets do
		local combatant = registry.CombatService.Get(candidate.character)
		if combatant and combatant.team == "Enemy" and combatant.alive then
			registry.StatusService.Apply(candidate.character, effect.status, {
				sourceDamage = baseDamage,
				source = ctx.attacker.character,
			})
		end
	end

	-- GROUNDSWELL: the discharge does not disperse, it settles.
	if state.synergies.Groundswell then
		BoonService.SpawnGroundZone(ctx.attacker, ctx.attacker.root.Position, radius, baseDamage * 0.4, 5, "Shock")
	end
end

--------------------------------------------------------------------------------
-- Shared effect primitives
--------------------------------------------------------------------------------

--[[
	A patch of ground that hurts what stands in it. Used by Graces and by two
	synergies; keeping one implementation means they all look and behave the same,
	which matters more than it sounds -- a player should be able to recognise
	"dangerous floor" instantly regardless of what put it there.
]]
function BoonService.SpawnGroundZone(attacker: any, position: Vector3, radius: number, tickDamage: number, duration: number, status: string?)
	local marker = Instance.new("Part")
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanQuery = false
	marker.Shape = Enum.PartType.Cylinder
	marker.Size = Vector3.new(0.4, radius * 2, radius * 2)
	marker.Color = if status then Lore.ElementColor(status == "Burn" and "Cinder" or "Skein") else Lore.ElementColor("Physical")
	marker.Material = Enum.Material.Neon
	marker.Transparency = 0.6
	marker.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	marker.Parent = registry.World.Effects
	game:GetService("Debris"):AddItem(marker, duration)

	task.spawn(function()
		local expiresAt = os.clock() + duration
		while os.clock() < expiresAt do
			task.wait(0.5)
			local inside = Hitbox.Query(CFrame.new(position), {
				shape = "Sphere",
				range = radius,
				height = 10,
				maxTargets = 8,
			}, { attacker.character })
			for _, candidate in inside do
				local combatant = registry.CombatService.Get(candidate.character)
				if combatant and combatant.team == "Enemy" and combatant.alive then
					registry.CombatService.ApplyDamage(attacker, combatant, {
						baseDamage = tickDamage,
						swingMultiplier = 1,
						suppressHooks = true,
					})
					if status then
						registry.StatusService.Apply(candidate.character, status, {
							sourceDamage = tickDamage,
							source = attacker.character,
						})
					end
				end
			end
		end
	end)
end

--------------------------------------------------------------------------------
-- Synergies with no single owning Grace
--------------------------------------------------------------------------------

--- ROTWIND: dashing through something infects it.
local function applyRotwind(state: BoonState, ctx: any)
	if not state.synergies.Rotwind then
		return
	end
	local swept = Hitbox.Query(CFrame.new(ctx.attacker.root.Position), {
		shape = "Sphere",
		range = 10,
		height = 12,
		maxTargets = 8,
	}, { ctx.attacker.character })

	local hasted = registry.StatusService.Has(ctx.attacker.character, "Haste")
	for _, candidate in swept do
		local combatant = registry.CombatService.Get(candidate.character)
		if combatant and combatant.team == "Enemy" and combatant.alive then
			registry.StatusService.Apply(candidate.character, "Blight", {
				stacks = 2,
				sourceDamage = (ctx.attacker.weapon and ctx.attacker.weapon.stats.baseDamage or 10),
				source = ctx.attacker.character,
				tickRateScale = if hasted then 1.5 else nil,
			})
		end
	end
end

--[[
	FIRESTORM: burning things set fire to what they stand next to, and a Winded
	enemy burns twice as fast. Runs on a slow timer because it is meant to be
	something happening in the background of a fight, not a per-hit proc.
]]
local function tickFirestorm(state: BoonState)
	if not state.synergies.Firestorm then
		return
	end
	state.nextFirestormAt = state.nextFirestormAt or 0
	if os.clock() < state.nextFirestormAt then
		return
	end
	state.nextFirestormAt = os.clock() + 0.8

	for _, burning in registry.StatusService.CharactersWith("Burn") do
		local combatant = registry.CombatService.Get(burning)
		if combatant and combatant.team == "Enemy" and combatant.alive then
			local nearby = Hitbox.Query(CFrame.new(combatant.root.Position), {
				shape = "Sphere",
				range = 8,
				height = 12,
				maxTargets = 5,
			}, { burning })
			for _, candidate in nearby do
				local other = registry.CombatService.Get(candidate.character)
				if other and other.team == "Enemy" and other.alive then
					local scale = if registry.StatusService.Has(candidate.character, "Winded") then 2 else 1
					registry.StatusService.Apply(candidate.character, "Burn", {
						sourceDamage = 6,
						source = burning,
						tickRateScale = scale,
					})
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Hook dispatch
--------------------------------------------------------------------------------

local function dispatch(handlers: any, state: BoonState, ctx: any)
	for _, held in state.held do
		local handler = handlers[held.config.effect.kind]
		if handler then
			local ok, err = pcall(handler, state, held, held.values, ctx)
			if not ok then
				warn(("[BoonService] %s handler error: %s"):format(held.boonId, tostring(err)))
			end
		end
	end
end

function BoonService.OnHit(attacker: any, target: any, result: any, context: any)
	if context.suppressHooks then
		return
	end
	local state = attacker.player and states[attacker.player]
	if not state then
		return
	end
	dispatch(OnHit, state, { attacker = attacker, target = target, result = result, context = context })
end

function BoonService.OnKill(attacker: any, target: any)
	local state = attacker.player and states[attacker.player]
	if not state then
		return
	end
	dispatch(OnKill, state, { attacker = attacker, target = target })
end

function BoonService.OnDodge(attacker: any, direction: Vector3)
	local state = attacker.player and states[attacker.player]
	if not state then
		return
	end
	state.lastDodgeAt = os.clock()
	local ctx = { attacker = attacker, direction = direction }
	dispatch(OnDodgeEffects, state, ctx)
	applyRotwind(state, ctx)
end

function BoonService.OnParry(defender: any, other: any)
	local state = defender.player and states[defender.player]
	if not state then
		return
	end
	dispatch(OnParryEffects, state, { attacker = defender, other = other })
end

function BoonService.OnDamaged(target: any, amount: number, attacker: any)
	local state = target.player and states[target.player]
	if not state then
		return
	end
	state.hitStreak = 0
	dispatch(OnDamagedEffects, state, { attacker = target, amount = amount, other = attacker })
end

function BoonService.OnAbility(attacker: any)
	local state = attacker.player and states[attacker.player]
	if not state then
		return
	end
	dispatch(OnAbilityEffects, state, { attacker = attacker })
end

--------------------------------------------------------------------------------
-- Run lifecycle
--------------------------------------------------------------------------------

function BoonService.BeginRun(player: Player, extraRerolls: number)
	states[player] = {
		player = player,
		held = {},
		heldSet = {},
		fadedCounts = {},
		synergies = {},
		rerolls = GameConfig.Boons.BaseRerolls + (extraRerolls or 0),
		aggregate = newAggregate(),
		hitStreak = 0,
		roomShieldUsed = false,
		emergencyHealUsed = false,
		chargedReady = false,
		lastMovedAt = os.clock(),
		lastStillAt = os.clock(),
		lastDodgeAt = 0,
		perTargetHits = {},
		pendingOffer = nil,
		pendingResolve = nil,
		nextSpreadAt = 0,
		nextFirestormAt = 0,
	}
	recomputeAggregate(states[player])
end

function BoonService.EndRun(player: Player)
	states[player] = nil
end

--- Called at the start of each room, so per-room effects reset.
function BoonService.BeginRoom(player: Player)
	local state = states[player]
	if state then
		state.roomShieldUsed = false
		state.emergencyHealUsed = false
		state.hitStreak = 0
	end
end

function BoonService.GetState(player: Player): BoonState?
	return states[player]
end

function BoonService.Snapshot(player: Player): { any }
	local state = states[player]
	if not state then
		return {}
	end
	local list = {}
	for _, held in state.held do
		table.insert(list, {
			boonId = held.boonId,
			name = held.config.name,
			rarity = held.rarity,
			faded = held.config.faded,
			description = BoonConfig.Describe(held.boonId, held.rarity :: any),
			color = BoonConfig.RarityColor(held.rarity :: any),
		})
	end
	return list
end

--------------------------------------------------------------------------------
-- Tick: the standing-still charge (AUDIT)
--------------------------------------------------------------------------------

--[[
	HOARFROST. Chilled enemies standing near each other pass Chill between them.
	Run on its own slow timer rather than per hit, because it is an ambient
	pressure effect -- the point is that a chilled group keeps getting colder while
	you are busy elsewhere.
]]
local function tickStatusSpread(state: BoonState)
	for _, held in state.held do
		local effect = held.config.effect
		if effect.kind == "StatusSpread" then
			local interval = held.values[effect.intervalIndex]
			state.nextSpreadAt = state.nextSpreadAt or 0
			if os.clock() >= state.nextSpreadAt then
				state.nextSpreadAt = os.clock() + interval

				local carriers = registry.StatusService.CharactersWith(effect.status)
				for _, carrier in carriers do
					local combatant = registry.CombatService.Get(carrier)
					if combatant and combatant.team == "Enemy" and combatant.alive then
						local nearby = Hitbox.Query(CFrame.new(combatant.root.Position), {
							shape = "Sphere",
							range = effect.radius,
							height = 14,
							maxTargets = 6,
						}, { carrier })
						for _, candidate in nearby do
							local other = registry.CombatService.Get(candidate.character)
							if other and other.team == "Enemy" and other.alive then
								registry.StatusService.Apply(candidate.character, effect.status, {
									stacks = 1,
									sourceDamage = registry.StatusService.Stacks(carrier, effect.status) * 4,
									source = carrier,
								})
							end
						end
					end
				end
			end
		end
	end
end

function BoonService.Tick(_deltaTime: number)
	for player, state in states do
		tickStatusSpread(state)
		tickFirestorm(state)
		if state.aggregate.chargedStillTime < math.huge and not state.chargedReady then
			local combatant = registry.CombatService.GetByPlayer(player)
			if combatant then
				local velocity = combatant.root.AssemblyLinearVelocity
				if Vector3.new(velocity.X, 0, velocity.Z).Magnitude < 2 then
					if os.clock() - state.lastMovedAt >= state.aggregate.chargedStillTime then
						state.chargedReady = true
						Net.FireClient("Notify", player, {
							kind = "Charged",
							title = "AUDITED",
							body = "Your next attack is charged.",
						})
					end
				else
					state.lastMovedAt = os.clock()
				end
			end
		end
	end
end

--------------------------------------------------------------------------------

function BoonService.Init(services: any)
	registry = services
end

function BoonService.Start()
	Net.OnServerEvent("BoonChoose", function(player, payload)
		if type(payload) == "table" then
			BoonService.HandleChoice(player, payload)
		end
	end)
end

return BoonService
