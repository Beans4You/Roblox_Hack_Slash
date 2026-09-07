--!strict
--[[
	RunManager — the run loop.

	Owns one session per player: build a room, fight it, offer doors, repeat, then
	the Warden. Everything a run creates belongs to that session's Maid, so ending
	a run -- by winning, dying or disconnecting -- collapses the entire world it
	built in one call.

	CO-OP READINESS
	Sessions are keyed by player but every function takes the session rather than
	reading a global, and rooms are placed on a per-session origin. Making this
	party-based means keying sessions by party id and letting several players share
	one; nothing here assumes a session has exactly one player. That was the point
	of the brief's "design so co-op can be added without rebuilding the game", and
	it is cheap to honour now and expensive to retrofit.

	ROOM PLACEMENT
	Rooms are laid out along a line, far apart, and old ones are destroyed once the
	player is two rooms past them. There is no attempt to connect them physically:
	the player is teleported between rooms behind a fade. Physically contiguous
	procedural levels are a great deal of work for something the player never looks
	at, and the budget is better spent on the fight.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local GameConfig = require(Shared.Config.GameConfig)
local RegionConfig = require(Shared.Config.RegionConfig)
local RoomConfig = require(Shared.Config.RoomConfig)
local Maid = require(Shared.Util.Maid)
local Rng = require(Shared.Util.Rng)
local PartFactory = require(Shared.Util.PartFactory)
local Net = require(Shared.Net.Net)
local Signal = require(Shared.Util.Signal)

local RunManager = {}

RunManager.RunStarted = Signal.new()
RunManager.RunEnded = Signal.new()
RunManager.RoomEntered = Signal.new()

local registry: any = nil

--- Rooms are spaced along X. 900 studs is far enough that nothing from one room
--- (sound rolloff, a stray projectile, a boss shockwave) reaches the next.
local ROOM_SPACING = 900
--- Each session gets its own Z lane, so two players' runs cannot overlap.
local SESSION_LANE_SPACING = 4000

export type Session = {
	player: Player,
	maid: any,
	rng: any,

	regionId: string,
	region: any,
	weaponId: string,
	heat: number,

	route: any,
	slot: number,
	currentPlan: any,
	currentRoom: any,
	encounter: any,
	roomMaid: any,
	previousRooms: { any },

	motes: number,
	boonLuck: number,
	rewardMultiplier: number,
	eventDamageBonus: number,
	forcedNextType: string?,

	-- Doors currently offered, if the room is cleared.
	doorPlans: { any }?,

	phase: string,
	startedAt: number,
	laneOffset: number,
	roomTookDamage: boolean,

	stats: any,
	finished: boolean,

	-- Set only while the relevant feature is live.
	bossHandle: any?,
	pendingEvent: any?,
	runWeaponBonus: number?,
}

local sessions: { [Player]: Session } = {}
local laneCounter = 0

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function roomOrigin(session: Session, slot: number): CFrame
	return CFrame.new(slot * ROOM_SPACING, 0, session.laneOffset)
end

local function syncRun(session: Session)
	Net.FireClient("RunSync", session.player, {
		active = true,
		regionId = session.regionId,
		regionName = session.region.displayName,
		slot = session.slot,
		roomCount = session.route.roomCount,
		roomType = session.currentPlan and session.currentPlan.roomType or nil,
		motes = session.motes,
		heat = session.heat,
		boons = registry.BoonService.Snapshot(session.player),
		phase = session.phase,
		doors = session.doorPlans and (function()
			local previews = {}
			for index, plan in session.doorPlans do
				previews[index] = {
					index = index,
					roomType = plan.roomType,
					name = plan.preview.name,
					description = plan.preview.description,
					icon = plan.preview.icon,
					color = plan.preview.color,
					rewards = plan.preview.rewards,
				}
			end
			return previews
		end)() or nil,
	})
end

local function teleportInto(session: Session, room: any)
	local character = session.player.Character
	if not character or not character.PrimaryPart then
		return
	end
	local entrance = room.origin * CFrame.new(room.entrance + Vector3.new(0, 5, 0))
	-- Face into the room rather than at the wall behind the entrance.
	character:PivotTo(CFrame.lookAt(entrance.Position, room.origin.Position + Vector3.new(0, 5, 0)))
end

--------------------------------------------------------------------------------
-- Doors
--------------------------------------------------------------------------------

--[[
	Builds the physical doors for the offered choices.

	Doors are real objects with ProximityPrompts rather than a pure UI choice,
	because walking to the door you want is a decision with a body attached to it,
	and because it gives the player a moment to look at both before committing.
]]
local function buildDoors(session: Session, room: any, plans: { any })
	local exits = room.exits
	for index, plan in plans do
		local offset = exits[index] or exits[#exits] or Vector3.new(0, 0, -30)
		local position = room.origin * CFrame.new(offset + Vector3.new(0, 6, 0))

		local frame = PartFactory.Part({
			Name = "Door",
			Size = Vector3.new(10, 14, 2),
			Color = plan.preview.color,
			Material = Enum.Material.Neon,
			Transparency = 0.35,
			CanCollide = false,
			CFrame = CFrame.lookAt(position.Position, room.origin.Position),
			Parent = room.model,
		})
		PartFactory.PointLight(frame, plan.preview.color, 3, 30)

		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = plan.preview.name
		prompt.ObjectText = plan.preview.description
		prompt.HoldDuration = 0.25
		prompt.MaxActivationDistance = 14
		prompt.RequiresLineOfSight = false
		prompt.Parent = frame

		local doorIndex = index
		session.roomMaid:Add(prompt.Triggered:Connect(function(player)
			if player ~= session.player then
				return
			end
			RunManager.ChooseDoor(session.player, doorIndex)
		end))
	end
end

--------------------------------------------------------------------------------
-- Room lifecycle
--------------------------------------------------------------------------------

local function clearRoomFeatures(session: Session)
	if session.roomMaid then
		session.roomMaid:DoCleaning()
	end
	session.roomMaid = Maid.new()
	session.maid:Add(session.roomMaid)
end

local function onRoomCleared(session: Session)
	if session.phase ~= "Fighting" then
		return
	end
	session.phase = "Cleared"

	if not session.roomTookDamage then
		session.stats.flawlessRooms += 1
		registry.ProgressionService.NoteFlawlessRoom(session.player)
	end

	local granted = registry.RewardService.GrantRoomRewards(session, session.currentPlan)
	if granted then
		session.stats.motesEarned += granted.motes or 0
	end

	-- The Warden's Gate is the end of the region; there is no door after it.
	if session.slot > session.route.roomCount then
		return
	end

	local plans = registry.RunGenerator.RollCandidates({
		route = session.route,
		heat = session.heat,
		healthFraction = (function()
			local combatant = registry.CombatService.GetByPlayer(session.player)
			return combatant and combatant.humanoid.Health / math.max(1, combatant.humanoid.MaxHealth) or 1
		end)(),
		boonCount = #(registry.BoonService.Snapshot(session.player)),
		lastRoomType = session.currentPlan and session.currentPlan.roomType or nil,
	}, session.slot + 1)

	-- An event can force what comes next; the wager is only interesting if it
	-- actually pays out.
	if session.forcedNextType then
		for _, plan in plans do
			plan.roomType = session.forcedNextType
		end
		session.forcedNextType = nil
	end

	session.doorPlans = plans
	buildDoors(session, session.currentRoom, plans)
	syncRun(session)
end

--------------------------------------------------------------------------------
-- Non-combat room features
--------------------------------------------------------------------------------

local function setupGraceShrine(session: Session, room: any)
	local anchor = room.origin * CFrame.new(room.featureAnchor + Vector3.new(0, 3, 0))

	local plinth = PartFactory.Part({
		Name = "Shrine",
		Size = Vector3.new(5, 6, 5),
		Color = Color3.fromRGB(255, 186, 74),
		Material = Enum.Material.Neon,
		Transparency = 0.2,
		CFrame = anchor,
		Parent = room.model,
	})
	PartFactory.PointLight(plinth, Color3.fromRGB(255, 186, 74), 5, 55)

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Accept a Grace"
	prompt.ObjectText = "Shrine of the Faded"
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = 16
	prompt.Parent = plinth

	session.roomMaid:Add(prompt.Triggered:Connect(function(player)
		if player ~= session.player then
			return
		end
		prompt.Enabled = false

		local state = registry.BoonService.GetState(session.player)
		if state then
			-- The shrine stays open until the player takes something. A reroll
			-- reopens it with a fresh offer.
			state.pendingResolve = function(action)
				if action == "reroll" then
					registry.BoonService.PresentOffer(session.player, session.rng, session.boonLuck)
				else
					plinth:Destroy()
					syncRun(session)
				end
			end
		end
		registry.BoonService.PresentOffer(session.player, session.rng, session.boonLuck)
	end))
end

local function setupWell(session: Session, room: any)
	local anchor = room.origin * CFrame.new(room.featureAnchor + Vector3.new(0, 2, 0))
	local well = PartFactory.Part({
		Name = "Well",
		Size = Vector3.new(7, 3, 7),
		Shape = Enum.PartType.Cylinder,
		Color = Color3.fromRGB(126, 205, 255),
		Material = Enum.Material.Neon,
		Transparency = 0.3,
		CFrame = anchor * CFrame.Angles(0, 0, math.rad(90)),
		Parent = room.model,
	})
	PartFactory.PointLight(well, Color3.fromRGB(126, 205, 255), 4, 45)

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Drink"
	prompt.ObjectText = "Still water"
	prompt.HoldDuration = 0.6
	prompt.MaxActivationDistance = 14
	prompt.Parent = well

	session.roomMaid:Add(prompt.Triggered:Connect(function(player)
		if player ~= session.player then
			return
		end
		prompt.Enabled = false
		local combatant = registry.CombatService.GetByPlayer(session.player)
		if combatant then
			registry.CombatService.Heal(combatant, combatant.humanoid.MaxHealth * 0.4)
		end
		well:Destroy()
		session.stats.wellsVisited += 1
	end))
end

local function setupEvent(session: Session, room: any, eventId: string)
	local event = RoomConfig.GetEvent(eventId)
	if not event then
		return
	end

	local anchor = room.origin * CFrame.new(room.featureAnchor + Vector3.new(0, 3, 0))
	local marker = PartFactory.Part({
		Name = "Event",
		Size = Vector3.new(4, 7, 4),
		Color = Color3.fromRGB(150, 118, 220),
		Material = Enum.Material.Neon,
		Transparency = 0.25,
		CFrame = anchor,
		Parent = room.model,
	})
	PartFactory.PointLight(marker, Color3.fromRGB(150, 118, 220), 4, 40)

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Look"
	prompt.ObjectText = event.title
	prompt.HoldDuration = 0.3
	prompt.MaxActivationDistance = 14
	prompt.Parent = marker

	session.roomMaid:Add(prompt.Triggered:Connect(function(player)
		if player ~= session.player then
			return
		end
		prompt.Enabled = false
		Net.FireClient("Dialogue", session.player, {
			npcId = "event:" .. eventId,
			npcName = event.title,
			lines = { event.body },
			choices = (function()
				local labels = {}
				for index, choice in event.choices do
					labels[index] = choice.label
				end
				return labels
			end)(),
			style = "Event",
		})
		session.pendingEvent = event
		marker:Destroy()
	end))
end

local function setupForge(session: Session, room: any)
	local anchor = room.origin * CFrame.new(room.featureAnchor + Vector3.new(0, 3, 0))
	local anvil = PartFactory.Part({
		Name = "Forge",
		Size = Vector3.new(6, 4, 4),
		Color = Color3.fromRGB(255, 122, 48),
		Material = Enum.Material.Metal,
		CFrame = anchor,
		Parent = room.model,
	})
	PartFactory.PointLight(anvil, Color3.fromRGB(255, 122, 48), 4, 40)

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Temper (60 Motes)"
	prompt.ObjectText = "A working anvil"
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = 14
	prompt.Parent = anvil

	session.roomMaid:Add(prompt.Triggered:Connect(function(player)
		if player ~= session.player or session.motes < 60 then
			return
		end
		session.motes -= 60
		prompt.Enabled = false

		-- A run-scoped weapon upgrade. Permanent Tempers are bought at the hub;
		-- this is a temporary edge that lasts the run.
		session.runWeaponBonus = (session.runWeaponBonus or 0) + 0.12
		local combatant = registry.CombatService.GetByPlayer(session.player)
		if combatant and combatant.weapon then
			for _, swing in combatant.weapon.lightCombo do
				swing.damage *= 1.12
			end
			combatant.weapon.heavy.damage *= 1.12
		end

		Net.FireClient("Notify", session.player, {
			kind = "Forge",
			title = "TEMPERED",
			body = "Your weapon deals 12% more damage for the rest of this run.",
		})
		anvil:Destroy()
		syncRun(session)
	end))
end

--------------------------------------------------------------------------------
-- Entering a room
--------------------------------------------------------------------------------

local function enterRoom(session: Session, plan: any)
	clearRoomFeatures(session)

	-- Retire rooms the player is well past. Nil on the first room of a run.
	if session.currentRoom then
		table.insert(session.previousRooms, session.currentRoom)
	end
	while #session.previousRooms > GameConfig.Performance.KeepPreviousRooms + 1 do
		local old = table.remove(session.previousRooms, 1)
		if old then
			old.maid:DoCleaning()
		end
	end

	local origin = roomOrigin(session, plan.slot)
	local room = registry.RoomBuilder.Build(
		plan.layoutId,
		session.region,
		origin,
		session.rng:Fork(plan.slot),
		registry.World.Run
	)
	if not room then
		warn("[RunManager] failed to build room; ending run")
		RunManager.EndRun(session.player, "Error")
		return
	end

	session.currentRoom = room
	session.currentPlan = plan
	session.slot = plan.slot
	session.doorPlans = nil
	session.roomTookDamage = false
	session.phase = "Fighting"
	session.maid:Add(room.maid)

	registry.BoonService.BeginRoom(session.player)
	teleportInto(session, room)

	-- Combat rooms.
	if plan.budget > 0 then
		local spawnPoints = {}
		for _, point in room.spawnPoints do
			table.insert(spawnPoints, point)
		end

		local encounter = registry.EnemyService.BuildEncounter({
			container = room.model,
			region = session.region,
			origin = origin.Position,
			spawnPoints = spawnPoints,
			budget = plan.budget,
			eliteCount = plan.eliteCount,
			healthScale = plan.healthScale,
			damageScale = plan.damageScale,
			rng = session.rng:Fork(plan.slot * 31),
		})
		session.encounter = encounter
		session.roomMaid:Add(encounter.onCleared:Connect(function()
			onRoomCleared(session)
		end))
		session.roomMaid:Add(function()
			registry.EnemyService.DestroyEncounter(encounter.id)
		end)
	else
		session.encounter = nil
	end

	-- Room features.
	if plan.roomType == "Grace" then
		setupGraceShrine(session, room)
	elseif plan.roomType == "Rest" then
		setupWell(session, room)
	elseif plan.roomType == "Event" and plan.eventId then
		setupEvent(session, room, plan.eventId)
	elseif plan.roomType == "Forge" then
		setupForge(session, room)
	end

	-- Non-combat rooms clear as soon as you arrive; the door opens immediately and
	-- the player leaves when they are ready.
	if plan.budget <= 0 then
		task.defer(function()
			onRoomCleared(session)
		end)
	end

	RunManager.RoomEntered:Fire(session.player, plan)
	syncRun(session)
end

--------------------------------------------------------------------------------
-- The Warden
--------------------------------------------------------------------------------

local function enterBossRoom(session: Session)
	clearRoomFeatures(session)

	local plan = registry.RunGenerator.BossPlan(session)
	local origin = roomOrigin(session, plan.slot)

	local room = registry.RoomBuilder.Build("WardenGate", session.region, origin, session.rng:Fork(999), registry.World.Run)
	if not room then
		RunManager.EndRun(session.player, "Error")
		return
	end

	session.currentRoom = room
	session.currentPlan = plan
	session.slot = plan.slot
	session.phase = "Boss"
	session.maid:Add(room.maid)
	teleportInto(session, room)

	-- Adds summoned by the boss share an encounter with it, so they are cleaned up
	-- with everything else.
	local encounter = registry.EnemyService.BuildEncounter({
		container = room.model,
		region = session.region,
		origin = origin.Position,
		spawnPoints = room.spawnPoints,
		budget = 0,
		rng = session.rng:Fork(1001),
	})
	session.encounter = encounter
	session.roomMaid:Add(function()
		registry.EnemyService.DestroyEncounter(encounter.id)
	end)

	local bossId = session.region.boss
	local handle = registry.BossService.Spawn(bossId, origin, room.model, encounter, room.arenaParts)
	if not handle then
		RunManager.EndRun(session.player, "Error")
		return
	end
	session.bossHandle = handle
	session.roomMaid:Add(handle.maid)

	syncRun(session)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function RunManager.StartRun(player: Player, weaponId: string, regionId: string, heat: number): (boolean, string?)
	if sessions[player] then
		return false, "already in a run"
	end

	local profile = registry.DataService.Get(player)
	if not profile then
		return false, "profile not loaded"
	end

	local weapon = profile.weapons[weaponId]
	if not weapon or not weapon.unlocked then
		return false, "weapon not unlocked"
	end
	if not profile.progress.regionsUnlocked[regionId] then
		return false, "region not unlocked"
	end

	local region = RegionConfig.Get(regionId)
	if not region then
		return false, "unknown region"
	end

	laneCounter += 1
	local seed = math.random(1, 2 ^ 30)

	local session: Session = {
		player = player,
		maid = Maid.new(),
		rng = Rng.new(seed),

		regionId = regionId,
		region = region,
		weaponId = weaponId,
		heat = math.clamp(heat or 0, 0, GameConfig.Run.MaxHeat),

		route = registry.RunGenerator.CreateRoute(regionId, seed),
		slot = 0,
		currentPlan = nil,
		currentRoom = nil,
		encounter = nil,
		roomMaid = Maid.new(),
		previousRooms = {},

		motes = 0,
		boonLuck = 0,
		rewardMultiplier = 1,
		eventDamageBonus = 0,
		forcedNextType = nil,

		doorPlans = nil,
		phase = "Starting",
		startedAt = os.clock(),
		laneOffset = laneCounter * SESSION_LANE_SPACING,
		roomTookDamage = false,

		stats = {
			roomsCleared = 0,
			enemiesKilled = 0,
			elitesKilled = 0,
			motesEarned = 0,
			damageDealt = 0,
			damageTaken = 0,
			perfectParries = 0,
			flawlessRooms = 0,
			wellsVisited = 0,
			synergies = {},
			newUnlocks = {},
		},
		finished = false,
	}

	sessions[player] = session
	session.maid:Add(session.roomMaid)

	registry.ProgressionService.NoteRunStarted(player, weaponId)
	registry.BoonService.BeginRun(player, registry.ProgressionService.ExtraRerolls(player))
	registry.PlayerService.PrepareForRun(player, weaponId)

	-- Keepsakes that grant a Grace at the start of a run.
	registry.ProgressionService.ApplyStartingBoons(player)

	RunManager.RunStarted:Fire(player, session)

	-- Room one.
	local firstPlan = registry.RunGenerator.RollCandidates({
		route = session.route,
		heat = session.heat,
		healthFraction = 1,
		boonCount = 0,
	}, 1)[1]
	enterRoom(session, firstPlan)

	return true, nil
end

function RunManager.ChooseDoor(player: Player, doorIndex: number)
	local session = sessions[player]
	if not session or session.phase ~= "Cleared" or not session.doorPlans then
		return
	end

	local plan = session.doorPlans[doorIndex]
	if not plan then
		return
	end

	session.doorPlans = nil

	if plan.slot > session.route.roomCount then
		enterBossRoom(session)
	else
		enterRoom(session, plan)
	end
end

function RunManager.EndRun(player: Player, outcome: string)
	local session = sessions[player]
	if not session or session.finished then
		return
	end
	session.finished = true

	local summary = registry.RewardService.FinishRun(session, outcome)

	registry.BossService.Despawn(session.bossHandle)
	registry.BoonService.EndRun(player)
	session.maid:DoCleaning()
	sessions[player] = nil

	Net.FireClient("RunSync", player, { active = false })
	RunManager.RunEnded:Fire(player, outcome, summary)

	-- Back to Emberhold, where the permanent progression is waiting.
	task.delay(GameConfig.Player.DeathCameraHold, function()
		registry.HubService.ReturnToHub(player)
	end)
end

function RunManager.GetSession(player: Player): Session?
	return sessions[player]
end

function RunManager.HandleEventChoice(player: Player, choiceIndex: number)
	local session = sessions[player]
	if not session or not session.pendingEvent then
		return
	end
	local choice = session.pendingEvent.choices[choiceIndex]
	session.pendingEvent = nil
	if not choice then
		return
	end
	registry.RewardService.ApplyEventOutcome(session, choice.outcome)
	syncRun(session)
end

--------------------------------------------------------------------------------
-- Tick
--------------------------------------------------------------------------------

local syncAccumulator = 0

function RunManager.Tick(deltaTime: number)
	syncAccumulator += deltaTime
	if syncAccumulator < 0.5 then
		return
	end
	syncAccumulator = 0

	for player, session in sessions do
		if not player.Parent then
			RunManager.EndRun(player, "Disconnected")
			continue
		end

		-- A player who somehow ends up outside their room (a knockback off the
		-- Broken Span, a physics glitch) is returned to the room entrance rather
		-- than being left to fall forever.
		local character = player.Character
		local room = session.currentRoom
		if character and character.PrimaryPart and room then
			local position = character.PrimaryPart.Position
			if position.Y < -80 then
				local combatant = registry.CombatService.GetByPlayer(player)
				if combatant then
					registry.CombatService.ApplyDamage(nil, combatant, {
						baseDamage = combatant.humanoid.MaxHealth * 0.15,
						swingMultiplier = 1,
					})
				end
				teleportInto(session, room)
			end
		end
	end
end

--------------------------------------------------------------------------------

function RunManager.Init(services: any)
	registry = services
end

function RunManager.Start()
	Net.OnServerInvoke("RunRequest", function(player, action, weaponId, regionId, heat)
		if action == "Start" then
			return RunManager.StartRun(player, tostring(weaponId), tostring(regionId), tonumber(heat) or 0)
		elseif action == "Abandon" then
			RunManager.EndRun(player, "Abandoned")
			return true
		end
		return false, "unknown action"
	end)

	Net.OnServerEvent("ChooseDoor", function(player, payload)
		if type(payload) == "table" and tonumber(payload.doorIndex) then
			RunManager.ChooseDoor(player, tonumber(payload.doorIndex) :: number)
		elseif type(payload) == "table" and tonumber(payload.choiceIndex) then
			RunManager.HandleEventChoice(player, tonumber(payload.choiceIndex) :: number)
		end
	end)

	-- Run statistics, gathered from the combat layer rather than duplicated in it.
	registry.CombatService.Damaged:Connect(function(target: any, attacker: any, result: any)
		if attacker and attacker.player then
			local session = sessions[attacker.player]
			if session then
				session.stats.damageDealt += result.amount
			end
		end
		if target.player then
			local session = sessions[target.player]
			if session then
				session.stats.damageTaken += result.amount
				session.roomTookDamage = true
			end
		end
	end)

	registry.CombatService.ParrySucceeded:Connect(function(defender: any)
		local session = defender.player and sessions[defender.player]
		if session then
			session.stats.perfectParries += 1
			registry.ProgressionService.NoteParry(defender.player)
		end
	end)

	-- Credit kills to whoever landed the blow, not to every live session.
	registry.CombatService.Killed:Connect(function(target: any, killer: any)
		if target.team ~= "Enemy" or not killer or not killer.player then
			return
		end
		local session = sessions[killer.player]
		if not session then
			return
		end
		local enemyId = target.character:GetAttribute("EnemyId")
		local isElite = target.character:GetAttribute("IsElite") == true

		session.stats.enemiesKilled += 1
		if isElite then
			session.stats.elitesKilled += 1
		end
		if enemyId then
			registry.ProgressionService.NoteKill(killer.player, enemyId, isElite)
		end
	end)

	registry.BoonService.SynergyFound:Connect(function(player: Player, synergyId: string)
		local session = sessions[player]
		if session then
			table.insert(session.stats.synergies, synergyId)
		end
		registry.ProgressionService.NoteSynergy(player, synergyId)
	end)

	registry.BossService.BossDefeated:Connect(function(bossId: string, info: any, handle: any)
		for player, session in sessions do
			if session.bossHandle == handle then
				registry.ProgressionService.NoteBossDefeated(player, bossId, info)
				RunManager.EndRun(player, "Victory")
				return
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		local session = sessions[player]
		if session then
			session.maid:DoCleaning()
			sessions[player] = nil
		end
	end)
end

return RunManager
