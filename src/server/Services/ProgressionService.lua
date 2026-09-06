--!strict
--[[
	ProgressionService — everything that survives a death.

	All permanent state changes funnel through here so there is exactly one place
	that can grant a weapon, a Keepsake, a cosmetic or a mastery level -- and
	therefore exactly one place to audit when a player says something did not
	unlock.

	UNLOCK CHECKING
	Cosmetics declare the act that earns them (see CosmeticConfig). Rather than
	scattering the checks across the systems that produce those acts, every
	relevant event calls EvaluateUnlocks, which walks the cosmetic table and grants
	anything now satisfied. It is a small loop over a small table; running it on
	kill events is cheaper than the bookkeeping needed to avoid running it.

	MASTERY
	Experience is awarded from things you can only do with the weapon in your hand,
	weighted toward the hard ones. A perfect parry is worth thirty light hits. That
	is deliberate: mastery should pull the player up the weapon's skill curve, not
	reward them for swinging at nothing for an hour.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local MasteryConfig = require(Shared.Config.MasteryConfig)
local CosmeticConfig = require(Shared.Config.CosmeticConfig)
local RelicConfig = require(Shared.Config.RelicConfig)
local WeaponConfig = require(Shared.Config.WeaponConfig)
local BoonConfig = require(Shared.Config.BoonConfig)
local RegionConfig = require(Shared.Config.RegionConfig)
local ProfileTemplate = require(script.Parent.ProfileTemplate)
local Net = require(Shared.Net.Net)
local Signal = require(Shared.Util.Signal)

local ProgressionService = {}

ProgressionService.Unlocked = Signal.new()

local registry: any = nil

--- Mastery experience that has not yet been folded into the profile. Batched so a
--- fight does not write to the profile once per swing.
local pendingMastery: { [Player]: { [string]: number } } = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function profileOf(player: Player)
	return registry.DataService.Get(player)
end

local function sync(player: Player)
	local profile = profileOf(player)
	if profile then
		Net.FireClient("ProfileSync", player, profile)
	end
end

local function notify(player: Player, kind: string, title: string, body: string, color: Color3?)
	Net.FireClient("Notify", player, {
		kind = kind,
		title = title,
		body = body,
		color = color,
	})
end

--------------------------------------------------------------------------------
-- Currency
--------------------------------------------------------------------------------

function ProgressionService.AddSable(player: Player, amount: number)
	if amount <= 0 then
		return
	end
	registry.DataService.Update(player, function(profile)
		-- The Trade set bonus increases everything Sable-shaped.
		local bonus = 0
		for _, setId in RelicConfig.CompletedSets(profile.relics.owned) do
			local set = RelicConfig.Sets[setId]
			if set and set.reward.passive and set.reward.passive.kind == "SableGain" then
				bonus += set.reward.passive.bonus
			end
		end
		local granted = math.floor(amount * (1 + bonus))
		profile.currency.sable += granted
		profile.currency.sableEarned += granted
	end)
end

function ProgressionService.SpendSable(player: Player, amount: number): boolean
	local profile = profileOf(player)
	if not profile or profile.currency.sable < amount then
		return false
	end
	registry.DataService.Update(player, function(data)
		data.currency.sable -= amount
	end)
	return true
end

--------------------------------------------------------------------------------
-- Keepsakes
--------------------------------------------------------------------------------

function ProgressionService.OwnedRelics(player: Player): { [string]: boolean }
	local profile = profileOf(player)
	return profile and profile.relics.owned or {}
end

function ProgressionService.GrantRelic(player: Player, relicId: string): boolean
	local relic = RelicConfig.Get(relicId)
	local profile = profileOf(player)
	if not relic or not profile or profile.relics.owned[relicId] then
		return false
	end

	registry.DataService.Update(player, function(data)
		data.relics.owned[relicId] = true
	end)

	notify(player, "Relic", relic.name, relic.description)
	ProgressionService.Unlocked:Fire(player, "Relic", relicId)

	-- A completed set may hand out its own cosmetic.
	for _, setId in RelicConfig.CompletedSets(profile.relics.owned) do
		local set = RelicConfig.Sets[setId]
		if set and set.reward.cosmetic then
			ProgressionService.GrantCosmetic(player, set.reward.cosmetic)
		end
	end

	sync(player)
	return true
end

--- How many Keepsakes may be equipped, including the Small Things set bonus.
function ProgressionService.RelicSlots(player: Player): number
	local profile = profileOf(player)
	if not profile then
		return RelicConfig.BaseEquipSlots
	end
	local slots = RelicConfig.BaseEquipSlots
	for _, setId in RelicConfig.CompletedSets(profile.relics.owned) do
		local set = RelicConfig.Sets[setId]
		if set and set.reward.passive and set.reward.passive.kind == "ExtraRelicSlot" then
			slots += 1
		end
	end
	return slots
end

function ProgressionService.EquipRelic(player: Player, relicId: string, equip: boolean): (boolean, string?)
	local profile = profileOf(player)
	local relic = RelicConfig.Get(relicId)
	if not profile or not relic then
		return false, "unknown Keepsake"
	end
	if not profile.relics.owned[relicId] then
		return false, "not owned"
	end

	if not equip then
		registry.DataService.Update(player, function(data)
			data.relics.equipped[relicId] = nil
		end)
		sync(player)
		return true, nil
	end

	local equippedCount = 0
	for _ in profile.relics.equipped do
		equippedCount += 1
	end
	if equippedCount >= ProgressionService.RelicSlots(player) then
		return false, "no free slots"
	end

	registry.DataService.Update(player, function(data)
		data.relics.equipped[relicId] = true
	end)
	sync(player)
	return true, nil
end

--- Effects of all equipped Keepsakes, folded into one table.
function ProgressionService.RelicEffects(player: Player): { any }
	local profile = profileOf(player)
	if not profile then
		return {}
	end
	local effects = {}
	for relicId in profile.relics.equipped do
		local relic = RelicConfig.Get(relicId)
		if relic then
			table.insert(effects, relic.effect)
		end
	end
	return effects
end

function ProgressionService.ExtraRerolls(player: Player): number
	local extra = 0
	for _, effect in ProgressionService.RelicEffects(player) do
		if effect.kind == "ExtraReroll" then
			extra += effect.count
		end
	end
	return extra
end

--- Keepsakes that hand you a Grace before the run begins.
function ProgressionService.ApplyStartingBoons(player: Player)
	for _, effect in ProgressionService.RelicEffects(player) do
		if effect.kind == "StartingBoon" then
			local candidates = BoonConfig.ByFaded(effect.element)
			if #candidates > 0 then
				local chosen = candidates[math.random(1, #candidates)]
				registry.BoonService.Grant(player, chosen.id, effect.rarity)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Cosmetics
--------------------------------------------------------------------------------

function ProgressionService.GrantCosmetic(player: Player, cosmeticId: string): boolean
	local cosmetic = CosmeticConfig.Get(cosmeticId)
	local profile = profileOf(player)
	if not cosmetic or not profile or profile.cosmetics.owned[cosmeticId] then
		return false
	end

	registry.DataService.Update(player, function(data)
		data.cosmetics.owned[cosmeticId] = true
	end)

	notify(player, "Cosmetic", cosmetic.name, cosmetic.source)
	ProgressionService.Unlocked:Fire(player, "Cosmetic", cosmeticId)
	sync(player)
	return true
end

--[[
	Walks the cosmetic table and grants anything whose unlock condition now holds.

	Cheap enough to call on any progression event; the alternative -- wiring each
	unlock kind into the system that produces it -- spreads the same logic across
	six files and guarantees one of them gets missed.
]]
function ProgressionService.EvaluateUnlocks(player: Player)
	local profile = profileOf(player)
	if not profile then
		return
	end

	for id, cosmetic in CosmeticConfig.Cosmetics do
		if not profile.cosmetics.owned[id] then
			local unlock = cosmetic.unlock
			local earned = false

			if unlock.kind == "Default" then
				earned = true
			elseif unlock.kind == "Mastery" then
				local weapon = profile.weapons[unlock.weapon]
				earned = weapon ~= nil and weapon.level >= unlock.level
			elseif unlock.kind == "RelicSet" then
				local have, total = RelicConfig.SetProgress(unlock.set, profile.relics.owned)
				earned = total > 0 and have == total
			elseif unlock.kind == "BossFlawless" then
				local record = profile.progress.bosses[unlock.boss]
				earned = record ~= nil and record.flawless == true
			elseif unlock.kind == "BossChallenge" then
				local record = profile.progress.bosses[unlock.boss]
				earned = record ~= nil and record.challenges[unlock.challenge] == true
			elseif unlock.kind == "Deaths" then
				earned = profile.stats.deaths >= unlock.count
			elseif unlock.kind == "EnemyKills" then
				earned = (profile.stats.killsByEnemy[unlock.enemy] or 0) >= unlock.count
			elseif unlock.kind == "RegionClear" then
				local region = RegionConfig.Get(unlock.region)
				local bossId = region and region.boss
				local record = bossId and profile.progress.bosses[bossId]
				earned = record ~= nil and record.kills > 0
			elseif unlock.kind == "Story" then
				earned = profile.progress.storyFlags[unlock.chapter] == true
			elseif unlock.kind == "RunChallenge" then
				earned = profile.progress.storyFlags["challenge:" .. unlock.challenge] == true
			end

			if earned then
				ProgressionService.GrantCosmetic(player, id)
			end
		end
	end
end

function ProgressionService.EquipCosmetic(player: Player, slot: string, cosmeticId: string): (boolean, string?)
	local profile = profileOf(player)
	if not profile then
		return false, "no profile"
	end
	if not CosmeticConfig.Slots[slot] then
		return false, "unknown slot"
	end
	if cosmeticId ~= "" then
		local cosmetic = CosmeticConfig.Get(cosmeticId)
		if not cosmetic or cosmetic.slot ~= slot then
			return false, "wrong slot"
		end
		if not profile.cosmetics.owned[cosmeticId] then
			return false, "not owned"
		end
	end

	registry.DataService.Update(player, function(data)
		data.cosmetics.equipped[slot] = cosmeticId
	end)
	sync(player)
	registry.PlayerService.RefreshAppearance(player)
	return true, nil
end

--------------------------------------------------------------------------------
-- Weapons and Tempers
--------------------------------------------------------------------------------

function ProgressionService.UnlockWeapon(player: Player, weaponId: string): (boolean, string?)
	local definition = WeaponConfig.Get(weaponId)
	local profile = profileOf(player)
	if not definition or not profile then
		return false, "unknown weapon"
	end
	if profile.weapons[weaponId].unlocked then
		return false, "already unlocked"
	end
	if not ProgressionService.SpendSable(player, definition.unlockCost) then
		return false, "not enough Sable"
	end

	registry.DataService.Update(player, function(data)
		data.weapons[weaponId].unlocked = true
	end)

	notify(player, "Weapon", definition.displayName, definition.subtitle)
	ProgressionService.Unlocked:Fire(player, "Weapon", weaponId)
	sync(player)
	return true, nil
end

function ProgressionService.BuyTemper(player: Player, weaponId: string, temperId: string): (boolean, string?)
	local definition = WeaponConfig.Get(weaponId)
	local profile = profileOf(player)
	if not definition or not profile then
		return false, "unknown weapon"
	end

	local temper
	for _, candidate in definition.tempers do
		if candidate.id == temperId then
			temper = candidate
			break
		end
	end
	if not temper then
		return false, "unknown Temper"
	end

	local weaponData = profile.weapons[weaponId]
	if weaponData.tempers[temperId] then
		return false, "already owned"
	end
	if weaponData.level < temper.requiresMastery then
		return false, ("requires mastery %d"):format(temper.requiresMastery)
	end
	if not ProgressionService.SpendSable(player, temper.cost) then
		return false, "not enough Sable"
	end

	registry.DataService.Update(player, function(data)
		data.weapons[weaponId].tempers[temperId] = true
	end)

	notify(player, "Temper", temper.name, temper.description)
	sync(player)
	return true, nil
end

function ProgressionService.EquipTemper(player: Player, weaponId: string, temperId: string): (boolean, string?)
	local profile = profileOf(player)
	if not profile or not profile.weapons[weaponId] then
		return false, "unknown weapon"
	end
	if temperId ~= "" and not profile.weapons[weaponId].tempers[temperId] then
		return false, "not owned"
	end

	registry.DataService.Update(player, function(data)
		data.weapons[weaponId].equippedTemper = temperId
	end)
	sync(player)
	return true, nil
end

--------------------------------------------------------------------------------
-- Mastery
--------------------------------------------------------------------------------

--- Queues experience. Flushed at the end of a run, or when a level would be crossed.
function ProgressionService.AddMastery(player: Player, weaponId: string, amount: number)
	if amount <= 0 then
		return
	end
	local pending = pendingMastery[player]
	if not pending then
		pending = {}
		pendingMastery[player] = pending
	end
	pending[weaponId] = (pending[weaponId] or 0) + amount
end

--[[
	Commits queued experience and reports any levels crossed.

	Levels are announced individually because each one unlocks something specific,
	and "you gained three levels" tells the player nothing about what changed.
]]
function ProgressionService.AwardMastery(player: Player, weaponId: string, runInfo: any): any
	local pending = pendingMastery[player]
	local queued = pending and pending[weaponId] or 0
	if pending then
		pending[weaponId] = nil
	end

	queued += (runInfo.roomsCleared or 0) * MasteryConfig.Experience.RunCompletionPerRoom
	if runInfo.completed then
		queued += MasteryConfig.Experience.BossKill
	end

	local profile = profileOf(player)
	if not profile or queued <= 0 then
		return { gained = 0, levels = {} }
	end

	local weaponData = profile.weapons[weaponId]
	local before = weaponData.level

	registry.DataService.Update(player, function(data)
		local weapon = data.weapons[weaponId]
		weapon.experience += math.floor(queued)
		local level = MasteryConfig.LevelForExperience(weapon.experience)
		weapon.level = level
		weapon.runsUsed += 1
	end)

	local after = profile.weapons[weaponId].level
	local rewards = MasteryConfig.RewardsBetween(weaponId, before, after)

	for _, reward in rewards do
		notify(player, "Mastery", reward.name, reward.description)
		if reward.kind == "Cosmetic" and reward.payload and reward.payload.cosmetic then
			ProgressionService.GrantCosmetic(player, reward.payload.cosmetic)
		end
	end

	ProgressionService.EvaluateUnlocks(player)
	sync(player)

	return {
		gained = math.floor(queued),
		levelBefore = before,
		levelAfter = after,
		rewards = rewards,
	}
end

--------------------------------------------------------------------------------
-- Event notes
--------------------------------------------------------------------------------

function ProgressionService.NoteRunStarted(player: Player, weaponId: string)
	registry.DataService.Update(player, function(profile)
		profile.stats.runs += 1
	end)
end

function ProgressionService.NoteKill(player: Player, enemyId: string, isElite: boolean)
	local session = registry.RunManager.GetSession(player)
	local weaponId = session and session.weaponId
	if weaponId then
		ProgressionService.AddMastery(
			player,
			weaponId,
			if isElite then MasteryConfig.Experience.EliteKill else MasteryConfig.Experience.EnemyKill
		)
	end

	registry.DataService.Update(player, function(profile)
		profile.stats.enemiesKilled += 1
		if isElite then
			profile.stats.elitesKilled += 1
		end
		profile.stats.killsByEnemy[enemyId] = (profile.stats.killsByEnemy[enemyId] or 0) + 1
	end)

	-- Cheap enough to run here, and it makes "defeat 25 Talliers" land the moment
	-- the 25th dies rather than at the end of the run.
	ProgressionService.EvaluateUnlocks(player)
end

function ProgressionService.NoteParry(player: Player)
	local session = registry.RunManager.GetSession(player)
	if session then
		ProgressionService.AddMastery(player, session.weaponId, MasteryConfig.Experience.PerfectParry)
	end
	registry.DataService.Update(player, function(profile)
		profile.stats.perfectParries += 1
	end)
end

function ProgressionService.NoteFlawlessRoom(player: Player)
	local session = registry.RunManager.GetSession(player)
	if session then
		ProgressionService.AddMastery(player, session.weaponId, MasteryConfig.Experience.FlawlessRoom)
	end
	registry.DataService.Update(player, function(profile)
		profile.stats.flawlessRooms += 1
	end)
end

function ProgressionService.NoteSynergy(player: Player, synergyId: string)
	registry.DataService.Update(player, function(profile)
		profile.progress.synergiesFound[synergyId] = true
	end)
end

function ProgressionService.NoteBoonTaken(player: Player, boonId: string)
	registry.DataService.Update(player, function(profile)
		profile.progress.boonsDiscovered[boonId] = true
	end)
end

function ProgressionService.NoteBossDefeated(player: Player, bossId: string, info: any)
	local BossConfig = require(Shared.Config.BossConfig)
	local definition = BossConfig.Get(bossId)

	registry.DataService.Update(player, function(profile)
		local record = ProfileTemplate.BossRecord(profile, bossId)
		local firstClear = record.kills == 0
		record.kills += 1
		if firstClear then
			record.firstClearAt = os.time()
		end
		if info.flawless then
			record.flawless = true
		end
		profile.stats.bossesKilled += 1

		if definition and definition.rewards then
			local rewards = definition.rewards
			if rewards.unlocksRegion then
				profile.progress.regionsUnlocked[rewards.unlocksRegion] = true
			end
			if firstClear then
				profile.currency.sable += rewards.firstClearSable or 0
				profile.currency.sableEarned += rewards.firstClearSable or 0
			end
		end
	end)

	if definition and definition.rewards then
		if definition.rewards.relic then
			ProgressionService.GrantRelic(player, definition.rewards.relic)
		end
		if definition.rewards.unlocksWeapon then
			local weaponId = definition.rewards.unlocksWeapon
			local profile = profileOf(player)
			if profile and not profile.weapons[weaponId].unlocked then
				registry.DataService.Update(player, function(data)
					data.weapons[weaponId].unlocked = true
				end)
				local weapon = WeaponConfig.Get(weaponId)
				if weapon then
					notify(player, "Weapon", weapon.displayName, "Unlocked by defeating " .. bossId)
				end
			end
		end
	end

	ProgressionService.EvaluateUnlocks(player)
	sync(player)
end

function ProgressionService.NoteDeath(player: Player, killerEnemyId: string?, bossId: string?)
	registry.DataService.Update(player, function(profile)
		profile.stats.deaths += 1
		if killerEnemyId then
			profile.stats.deathsByEnemy[killerEnemyId] = (profile.stats.deathsByEnemy[killerEnemyId] or 0) + 1
		end
		if bossId then
			local record = ProfileTemplate.BossRecord(profile, bossId)
			record.deaths += 1
		end
	end)

	-- A SECOND KNIFE is earned by dying to the same thing five times, which is the
	-- game noticing you are stuck and helping.
	local profile = profileOf(player)
	if profile and killerEnemyId and (profile.stats.deathsByEnemy[killerEnemyId] or 0) >= 5 then
		ProgressionService.GrantRelic(player, "SecondKnife")
	end

	ProgressionService.EvaluateUnlocks(player)
	sync(player)
end

function ProgressionService.UnlockLore(player: Player, loreId: string)
	registry.DataService.Update(player, function(profile)
		profile.progress.loreUnlocked[loreId] = true
	end)
	sync(player)
end

function ProgressionService.SetStoryFlag(player: Player, flag: string)
	registry.DataService.Update(player, function(profile)
		profile.progress.storyFlags[flag] = true
	end)
	ProgressionService.EvaluateUnlocks(player)
	sync(player)
end

function ProgressionService.MarkLineSeen(player: Player, lineId: string)
	registry.DataService.Update(player, function(profile)
		profile.progress.seenLines[lineId] = true
	end)
end

function ProgressionService.RecordRun(player: Player, summary: any)
	registry.DataService.Update(player, function(profile)
		if summary.outcome == "Victory" then
			profile.stats.runsCompleted += 1
		end
		profile.stats.roomsCleared += summary.roomsCleared
		profile.stats.motesEarned += summary.motesEarned
		profile.stats.damageDealt += summary.damageDealt
		profile.stats.damageTaken += summary.damageTaken
		profile.stats.deepestRoom = math.max(profile.stats.deepestRoom, summary.roomsCleared)

		ProfileTemplate.PushRun(profile, {
			at = os.time(),
			outcome = summary.outcome,
			region = summary.region,
			weapon = summary.weaponId,
			rooms = summary.roomsCleared,
			heat = summary.heat,
			duration = math.floor(summary.duration),
		})
	end)

	-- Run-scoped challenge flags, checked here because this is the only place that
	-- sees the whole run at once.
	if summary.outcome == "Victory" and summary.damageTaken <= 0 then
		ProgressionService.SetStoryFlag(player, "challenge:FlawlessRegion")
	end
	if summary.outcome == "Victory" and summary.heat >= 5 then
		local session = registry.RunManager.GetSession(player)
		if not session or session.stats.deaths == nil then
			ProgressionService.SetStoryFlag(player, "challenge:NoDeath")
		end
	end

	registry.DataService.Save(player)
	sync(player)
end

--------------------------------------------------------------------------------
-- Queries used by other services
--------------------------------------------------------------------------------

function ProgressionService.DeathsToBoss(bossId: string): number
	-- Single-player sessions: the first live profile with a record for this boss.
	-- Party support would pass the player through; the signature is ready for it.
	for _, player in game:GetService("Players"):GetPlayers() do
		local profile = profileOf(player)
		local record = profile and profile.progress.bosses[bossId]
		if record then
			return record.deaths
		end
	end
	return 0
end

function ProgressionService.BossRecordSnapshot(bossId: string): any
	for _, player in game:GetService("Players"):GetPlayers() do
		local profile = profileOf(player)
		local record = profile and profile.progress.bosses[bossId]
		if record then
			return record
		end
	end
	return nil
end

--- The flat state DialogueConfig's resolver expects.
function ProgressionService.DialogueState(player: Player): any
	local profile = profileOf(player)
	if not profile then
		return nil
	end

	local bossesDefeated = {}
	for bossId, record in profile.progress.bosses do
		if record.kills > 0 then
			bossesDefeated[bossId] = true
		end
	end

	local weaponsUnlocked, masteryLevels = {}, {}
	for weaponId, weapon in profile.weapons do
		if weapon.unlocked then
			weaponsUnlocked[weaponId] = true
		end
		masteryLevels[weaponId] = weapon.level
	end

	local relicCount = 0
	for _ in profile.relics.owned do
		relicCount += 1
	end

	return {
		runs = profile.stats.runs,
		deaths = profile.stats.deaths,
		bossesDefeated = bossesDefeated,
		weaponsUnlocked = weaponsUnlocked,
		masteryLevels = masteryLevels,
		relicCount = relicCount,
		storyFlags = profile.progress.storyFlags,
		seenLines = profile.progress.seenLines,
		lastRunReached = profile.history[1] and profile.history[1].rooms or 0,
	}
end

--------------------------------------------------------------------------------

function ProgressionService.Init(services: any)
	registry = services
end

function ProgressionService.Start()
	registry.DataService.ProfileLoaded:Connect(function(player: Player, profile: any)
		local GameConfig = require(Shared.Config.GameConfig)
		if GameConfig.Debug.UnlockEverything then
			registry.DataService.Update(player, function(data)
				for weaponId in data.weapons do
					data.weapons[weaponId].unlocked = true
				end
				for regionId in RegionConfig.Regions do
					data.progress.regionsUnlocked[regionId] = true
				end
			end)
		end

		ProgressionService.EvaluateUnlocks(player)
		sync(player)

		if not profile.canSave then
			notify(
				player,
				"Warning",
				"PROGRESS WILL NOT SAVE",
				"Your profile could not be loaded. Play on, but nothing from this session "
					.. "will be kept. Rejoining usually fixes it."
			)
		end
	end)

	-- Mastery from landed hits, batched.
	registry.CombatService.Damaged:Connect(function(target: any, attacker: any)
		if not attacker or not attacker.player or target.team ~= "Enemy" then
			return
		end
		local session = registry.RunManager.GetSession(attacker.player)
		if not session then
			return
		end

		local amount = MasteryConfig.Experience.LightHit
		if attacker.action == "Heavy" then
			amount = MasteryConfig.Experience.HeavyHit
		elseif attacker.action == "Ability" then
			amount = MasteryConfig.Experience.AbilityHit
		elseif attacker.action == "Ultimate" then
			amount = MasteryConfig.Experience.UltimateHit
		end
		ProgressionService.AddMastery(attacker.player, session.weaponId, amount)
	end)

	registry.BoonService.BoonTaken:Connect(function(player: Player, boonId: string)
		ProgressionService.NoteBoonTaken(player, boonId)
	end)
end

return ProgressionService
