--!strict
--[[
	StatusService — burns, chills, bleeds, buffs.

	One registry keyed by character. Every status a character carries lives in one
	place so that "what is my current move speed" is a single lookup rather than a
	survey of every system that might have an opinion.

	TICKING
	Damage-over-time is driven from the shared heartbeat, batched per character.
	Each status carries its own next-tick timestamp rather than a countdown, so a
	frame hitch cannot cause a status to skip a tick or fire several at once.

	CHILL BECOMES FROZEN
	The one piece of status-specific logic in this file. It lives here rather than
	in a Grace because two different Graces and an enemy attack can all apply
	Chill, and all of them should be able to freeze.

	REPLICATION
	Clients are told about status changes, not status ticks. A burn ticking eight
	times is one network message when it is applied and one when it ends; the HUD
	interpolates the bar itself.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local StatusConfig = require(Shared.Config.StatusConfig)
local Net = require(Shared.Net.Net)
local Signal = require(Shared.Util.Signal)

local StatusService = {}

StatusService.StatusApplied = Signal.new()
StatusService.StatusExpired = Signal.new()

export type ActiveStatus = {
	id: string,
	stacks: number,
	expiresAt: number,
	nextTickAt: number,
	-- Damage of the hit that applied it, used to scale DoT.
	sourceDamage: number,
	source: Model?,
	-- Set by Graces that alter a status after it lands.
	tickRateScale: number?,
	noExpireInCombat: boolean?,
}

type Record = {
	character: Model,
	humanoid: Humanoid,
	isBoss: boolean,
	statuses: { [string]: ActiveStatus },
	-- Recomputed whenever statuses change rather than every frame.
	cached: {
		moveSpeed: number,
		damageTaken: number,
		damageDealt: number,
		attackSpeed: number,
		incapacitated: boolean,
	},
}

local records: { [Model]: Record } = {}
local registry: any = nil

--------------------------------------------------------------------------------
-- Internals
--------------------------------------------------------------------------------

local function recompute(record: Record)
	local moveSpeed, damageTaken, damageDealt, attackSpeed = 1, 1, 1, 1
	local incapacitated = false

	for _, active in record.statuses do
		local config = StatusConfig.Get(active.id)
		if config then
			-- Stacking statuses apply their modifier once per stack.
			local applications = if config.stacking == "Stack" then active.stacks else 1
			if config.moveSpeedMultiplier then
				moveSpeed *= config.moveSpeedMultiplier ^ applications
			end
			if config.damageTakenMultiplier then
				damageTaken *= config.damageTakenMultiplier ^ applications
			end
			if config.damageDealtMultiplier then
				damageDealt *= config.damageDealtMultiplier ^ applications
			end
			if config.attackSpeedMultiplier then
				attackSpeed *= config.attackSpeedMultiplier ^ applications
			end
			if config.incapacitates then
				incapacitated = true
			end
		end
	end

	record.cached = {
		moveSpeed = moveSpeed,
		damageTaken = damageTaken,
		damageDealt = damageDealt,
		attackSpeed = attackSpeed,
		incapacitated = incapacitated,
	}
end

local function replicate(record: Record)
	local payload = {}
	for id, active in record.statuses do
		payload[id] = { stacks = active.stacks, expiresAt = active.expiresAt }
	end

	-- Player statuses go to that player; enemy statuses go to everyone, because
	-- everyone needs to see that the thing they are hitting is on fire.
	local player = game:GetService("Players"):GetPlayerFromCharacter(record.character)
	if player then
		Net.FireClient("StatusSync", player, { characterId = record.character:GetAttribute("NetId"), statuses = payload })
	else
		Net.FireAllClients("StatusSync", { characterId = record.character:GetAttribute("NetId"), statuses = payload })
	end
end

local function ensureRecord(character: Model): Record?
	local existing = records[character]
	if existing then
		return existing
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end

	local record: Record = {
		character = character,
		humanoid = humanoid,
		isBoss = character:GetAttribute("IsBoss") == true,
		statuses = {},
		cached = { moveSpeed = 1, damageTaken = 1, damageDealt = 1, attackSpeed = 1, incapacitated = false },
	}
	records[character] = record

	-- Statuses die with their host. Nothing here outlives the character.
	character.Destroying:Connect(function()
		records[character] = nil
	end)
	humanoid.Died:Connect(function()
		records[character] = nil
	end)

	return record
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

export type ApplyOptions = {
	stacks: number?,
	sourceDamage: number?,
	source: Model?,
	durationScale: number?,
	tickRateScale: number?,
	noExpireInCombat: boolean?,
}

function StatusService.Apply(character: Model, statusId: string, options: ApplyOptions?)
	local config = StatusConfig.Get(statusId)
	if not config then
		return
	end
	local record = ensureRecord(character)
	if not record then
		return
	end

	local opts = options or {}
	local now = os.clock()
	local duration = StatusConfig.DurationFor(statusId, record.isBoss) * (opts.durationScale or 1)
	local addStacks = opts.stacks or 1

	local active = record.statuses[statusId]
	if active then
		if config.stacking == "Stack" then
			active.stacks = math.min(config.maxStacks, active.stacks + addStacks)
		end
		active.expiresAt = now + duration
		-- Keep the strongest source damage: a big hit's burn should not be
		-- downgraded by a subsequent chip hit refreshing it.
		active.sourceDamage = math.max(active.sourceDamage, opts.sourceDamage or 0)
	else
		active = {
			id = statusId,
			stacks = math.min(config.maxStacks, addStacks),
			expiresAt = now + duration,
			nextTickAt = now + (config.tickInterval or math.huge),
			sourceDamage = opts.sourceDamage or 0,
			source = opts.source,
			tickRateScale = opts.tickRateScale,
			noExpireInCombat = opts.noExpireInCombat,
		}
		record.statuses[statusId] = active
	end

	if opts.tickRateScale then
		active.tickRateScale = opts.tickRateScale
	end
	if opts.noExpireInCombat then
		active.noExpireInCombat = true
	end

	-- Chill saturating into Frozen. Applying Frozen consumes the Chill entirely,
	-- so a frozen enemy does not immediately re-freeze on thaw.
	if statusId == "Chill" and active.stacks >= config.maxStacks then
		record.statuses.Chill = nil
		StatusService.Apply(character, "Frozen", { source = opts.source, sourceDamage = opts.sourceDamage })
		return
	end

	recompute(record)
	replicate(record)
	StatusService.StatusApplied:Fire(character, statusId, active)
end

function StatusService.Remove(character: Model, statusId: string)
	local record = records[character]
	if not record or not record.statuses[statusId] then
		return
	end
	record.statuses[statusId] = nil
	recompute(record)
	replicate(record)
	StatusService.StatusExpired:Fire(character, statusId)
end

function StatusService.Clear(character: Model)
	local record = records[character]
	if not record then
		return
	end
	record.statuses = {}
	recompute(record)
	replicate(record)
end

function StatusService.Has(character: Model, statusId: string): boolean
	local record = records[character]
	return (record and record.statuses[statusId]) ~= nil
end

function StatusService.Stacks(character: Model, statusId: string): number
	local record = records[character]
	local active = record and record.statuses[statusId]
	return active and active.stacks or 0
end

--- True if the character carries any status that counts as a debuff.
function StatusService.HasAnyDebuff(character: Model): boolean
	local record = records[character]
	if not record then
		return false
	end
	for _, id in StatusConfig.Debuffs do
		if record.statuses[id] then
			return true
		end
	end
	return false
end

local NEUTRAL = { moveSpeed = 1, damageTaken = 1, damageDealt = 1, attackSpeed = 1, incapacitated = false }

function StatusService.GetModifiers(character: Model)
	local record = records[character]
	return record and record.cached or NEUTRAL
end

--- Consumes a status and reports whether it was actually there. Used by SHATTER
--- and anything else that spends a debuff for a payoff.
function StatusService.Consume(character: Model, statusId: string): boolean
	local record = records[character]
	if not record or not record.statuses[statusId] then
		return false
	end
	StatusService.Remove(character, statusId)
	return true
end

--- Every character currently carrying `statusId`, for spread effects.
function StatusService.CharactersWith(statusId: string): { Model }
	local result = {}
	for character, record in records do
		if record.statuses[statusId] then
			table.insert(result, character)
		end
	end
	return result
end

--------------------------------------------------------------------------------
-- Tick
--------------------------------------------------------------------------------

function StatusService.Tick(_deltaTime: number)
	local now = os.clock()

	for character, record in records do
		if not character.Parent or record.humanoid.Health <= 0 then
			records[character] = nil
			continue
		end

		local changed = false

		for statusId, active in record.statuses do
			local config = StatusConfig.Get(statusId)
			if not config then
				record.statuses[statusId] = nil
				changed = true
				continue
			end

			-- Damage over time.
			if config.tickInterval and config.tickDamageRatio and now >= active.nextTickAt then
				local interval = config.tickInterval / (active.tickRateScale or 1)
				active.nextTickAt = now + interval

				local perStack = active.sourceDamage * config.tickDamageRatio
				local applications = if config.stacking == "Stack" then active.stacks else 1
				local damage = math.max(1, perStack * applications)

				if registry and registry.CombatService then
					registry.CombatService.ApplyStatusDamage(character, damage, active.source, statusId)
				end
			end

			if now >= active.expiresAt and not active.noExpireInCombat then
				record.statuses[statusId] = nil
				changed = true
				StatusService.StatusExpired:Fire(character, statusId)
			end
		end

		if changed then
			recompute(record)
			replicate(record)
		end
	end
end

function StatusService.Init(services: any)
	registry = services
end

return StatusService
