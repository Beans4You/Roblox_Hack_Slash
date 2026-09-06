--!strict
--[[
	RewardService — what a room gives you, and what an event costs.

	Kept separate from RunManager so that "what does clearing this room pay out"
	is one readable file rather than a branch buried inside the run loop.

	Rewards are granted server-side and reported to the client for display. The
	client is never told a number it then sends back.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local GameConfig = require(Shared.Config.GameConfig)
local RoomConfig = require(Shared.Config.RoomConfig)
local RelicConfig = require(Shared.Config.RelicConfig)
local DamageMath = require(Shared.Combat.DamageMath)
local Net = require(Shared.Net.Net)

local RewardService = {}

local registry: any = nil

--------------------------------------------------------------------------------
-- Room payouts
--------------------------------------------------------------------------------

--[[
	Grants everything a cleared room owes.

	`run` is the live run session. Motes are the in-run currency and vanish at the
	end; Sable is the meta currency and is written to the profile immediately, so
	a disconnect mid-run does not cost the player what they had already earned.
]]
function RewardService.GrantRoomRewards(run: any, plan: any)
	local player = run.player
	local typeConfig = RoomConfig.Types[plan.roomType]
	if not typeConfig then
		return
	end

	local heatScale = DamageMath.HeatReward(run.heat)
	local granted = {}

	for _, reward in typeConfig.rewards do
		if reward == "Motes" then
			local amount = math.floor((GameConfig.Run.BaseMotesPerRoom + plan.slot * 2) * heatScale)
			if plan.eliteCount > 0 then
				amount += GameConfig.Run.MotesPerElite
			end
			run.motes += amount
			granted.motes = amount
		elseif reward == "Heal" then
			local combatant = registry.CombatService.GetByPlayer(player)
			if combatant then
				local amount = combatant.humanoid.MaxHealth * 0.35
				registry.CombatService.Heal(combatant, amount)
				granted.heal = math.floor(amount)
			end
		elseif reward == "Relic" then
			-- Keepsakes are rare and mostly earned by achievements; a room can drop
			-- one the player has not yet unlocked any other way.
			local relic = RewardService.RollRelic(player, run)
			if relic then
				registry.ProgressionService.GrantRelic(player, relic)
				granted.relic = relic
			end
		end
	end

	local sable = math.floor(GameConfig.Run.SablePerRoomCleared * heatScale)
	if sable > 0 then
		registry.ProgressionService.AddSable(player, sable)
		granted.sable = sable
	end

	run.stats.roomsCleared += 1
	return granted
end

--- Picks a Keepsake the player does not own, weighted toward the current region.
function RewardService.RollRelic(player: Player, run: any): string?
	local owned = registry.ProgressionService.OwnedRelics(player)
	local candidates = {}
	for id, relic in RelicConfig.Relics do
		-- Boss and challenge Keepsakes are never handed out by a room; they have to
		-- be earned by the thing they commemorate.
		if not owned[id] and not relic.hidden and relic.set == "SmallThings" then
			table.insert(candidates, id)
		end
	end
	if #candidates == 0 then
		return nil
	end
	table.sort(candidates)
	return run.rng:Pick(candidates)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

--- Applies one branch of an event's outcome table.
function RewardService.ApplyEventOutcome(run: any, outcome: any)
	local player = run.player
	local combatant = registry.CombatService.GetByPlayer(player)

	if outcome.motes then
		run.motes += outcome.motes
	end
	if outcome.sable then
		registry.ProgressionService.AddSable(player, outcome.sable)
	end
	if outcome.heal and combatant then
		registry.CombatService.Heal(combatant, outcome.heal)
	end
	if outcome.damagePercent and combatant then
		registry.CombatService.ApplyDamage(nil, combatant, {
			baseDamage = combatant.humanoid.MaxHealth * outcome.damagePercent,
			swingMultiplier = 1,
			element = "Physical",
		})
	end
	if outcome.maxHealthPercent and combatant then
		local delta = combatant.humanoid.MaxHealth * outcome.maxHealthPercent
		combatant.humanoid.MaxHealth = math.max(20, combatant.humanoid.MaxHealth + delta)
		if delta > 0 then
			registry.CombatService.Heal(combatant, delta)
		else
			combatant.humanoid.Health = math.min(combatant.humanoid.Health, combatant.humanoid.MaxHealth)
		end
	end
	if outcome.damageBonus then
		run.eventDamageBonus = (run.eventDamageBonus or 0) + outcome.damageBonus
	end
	if outcome.heatIncrease then
		run.heat = math.min(GameConfig.Run.MaxHeat, run.heat + outcome.heatIncrease)
	end
	if outcome.boonRarityUpgrade then
		run.boonLuck = (run.boonLuck or 0) + outcome.boonRarityUpgrade
	end
	if outcome.forceRoomType then
		run.forcedNextType = outcome.forceRoomType
	end
	if outcome.rewardMultiplier then
		run.rewardMultiplier = (run.rewardMultiplier or 1) * outcome.rewardMultiplier
	end
	if outcome.loreUnlock then
		registry.ProgressionService.UnlockLore(player, outcome.loreUnlock)
	end
end

--------------------------------------------------------------------------------
-- End of run
--------------------------------------------------------------------------------

--[[
	Builds the run summary and commits everything permanent.

	The summary deliberately leads with what the player gained rather than how they
	died: the brief asks for death to read as progression, and the surest way to do
	that is to put the permanent rewards at the top of the screen that appears
	when you lose.
]]
function RewardService.FinishRun(run: any, outcome: string): any
	local player = run.player
	local heatScale = DamageMath.HeatReward(run.heat)

	local sable = 0
	if outcome == "Victory" then
		sable += math.floor(GameConfig.Run.SablePerBossKill * heatScale)
	end
	-- Depth pays out even on a loss, and it is the main reason a bad run is still
	-- worth finishing rather than abandoning at room three.
	sable += math.floor(run.stats.roomsCleared * 4 * heatScale)

	if sable > 0 then
		registry.ProgressionService.AddSable(player, sable)
	end

	local mastery = registry.ProgressionService.AwardMastery(player, run.weaponId, {
		roomsCleared = run.stats.roomsCleared,
		completed = outcome == "Victory",
	})

	local summary = {
		outcome = outcome,
		region = run.regionId,
		roomsCleared = run.stats.roomsCleared,
		enemiesKilled = run.stats.enemiesKilled,
		elitesKilled = run.stats.elitesKilled,
		bossDefeated = outcome == "Victory",
		weaponId = run.weaponId,
		boons = registry.BoonService.Snapshot(player),
		synergies = run.stats.synergies,
		motesEarned = run.stats.motesEarned,
		sableEarned = sable,
		damageDealt = math.floor(run.stats.damageDealt),
		damageTaken = math.floor(run.stats.damageTaken),
		perfectParries = run.stats.perfectParries,
		flawlessRooms = run.stats.flawlessRooms,
		heat = run.heat,
		duration = os.clock() - run.startedAt,
		masteryGained = mastery,
		newUnlocks = run.stats.newUnlocks,
		deepest = run.stats.roomsCleared,
	}

	registry.ProgressionService.RecordRun(player, summary)
	Net.FireClient("RunSummary", player, summary)

	return summary
end

function RewardService.Init(services: any)
	registry = services
end

return RewardService
