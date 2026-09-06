--!strict
--[[
	BossService — the Wardens.

	A boss is not an enemy with more health. It is a phase machine that owns the
	arena, so this service is separate from EnemyService and shares only the
	combat state machine underneath.

	WHAT MAKES A PHASE
	Each phase has its own attack list, movement, aggression and tempo. Crossing a
	threshold triggers a transition: the boss becomes invulnerable, plays a clip,
	changes the arena, possibly summons, and says something. The player gets a
	guaranteed breath, and the fight they were learning becomes a different one.

	THE BREAK METER
	Bosses are never staggered by ordinary hits -- being able to chain-stagger a
	Warden would end every fight the same way. Poise damage instead fills a break
	meter. Filling it opens the boss for a fixed window at increased damage. It is
	the same reward as a stagger, but it has to be earned in one sustained push
	rather than accumulated from chip damage.

	ARENA EFFECTS
	Every attack that reaches beyond the boss's own reach goes through an arena
	effect: a telegraphed shape that resolves after a delay. They are listed in one
	table below. A new boss attack that needs a new shape adds a handler there and
	nothing else changes.
]]

local Debris = game:GetService("Debris")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local GameConfig = require(Shared.Config.GameConfig)
local BossConfig = require(Shared.Config.BossConfig)
local Hitbox = require(Shared.Combat.Hitbox)
local RigBuilder = require(Shared.Util.RigBuilder)
local PartFactory = require(Shared.Util.PartFactory)
local Maid = require(Shared.Util.Maid)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net.Net)

local BossService = {}

BossService.BossDefeated = Signal.new()
BossService.PhaseChanged = Signal.new()

local registry: any = nil

export type BossHandle = {
	-- Unique per spawned instance.
	handleId: string,
	id: string,
	definition: any,
	combatant: any,
	character: Model,
	maid: any,
	arenaOrigin: CFrame,
	arenaParts: { BasePart },

	phaseIndex: number,
	phase: any,
	transitioning: boolean,

	breakMeter: number,
	brokenUntil: number,

	attackCooldowns: { [string]: number },
	nextDecisionAt: number,
	target: any,

	encounter: any,
	alive: boolean,
	-- Set when the player takes damage during the fight, for flawless tracking.
	playerTookDamage: boolean,
	startedAt: number,
}

--- Keyed by a unique handle id, not by boss id: two sessions can legitimately be
--- fighting the same Warden at the same time in different lanes.
local active: { [string]: BossHandle } = {}
local nextHandleId = 0

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

--------------------------------------------------------------------------------
-- Arena effects
--
-- Each handler telegraphs, waits, then resolves. They all take (handle, spec) and
-- are responsible for their own cleanup via the boss's Maid.
--------------------------------------------------------------------------------

local ArenaEffects = {}

--- Damages everything in a radius around a point, after a warning.
local function delayedArea(handle: BossHandle, position: Vector3, radius: number, damage: number, warnTime: number, applies: string?)
	local marker = PartFactory.Decor({
		Name = "AreaWarning",
		Size = Vector3.new(radius * 2, 0.2, radius * 2),
		Shape = Enum.PartType.Cylinder,
		Color = Color3.fromRGB(255, 90, 70),
		Material = Enum.Material.Neon,
		Transparency = 0.6,
		CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90)),
		Parent = registry.World.Effects,
	})
	Debris:AddItem(marker, warnTime + 0.3)

	task.delay(warnTime, function()
		if not handle.alive then
			return
		end
		local targets = Hitbox.Query(CFrame.new(position), {
			shape = "Sphere",
			range = radius,
			height = 20,
			maxTargets = 8,
		}, { handle.character })

		for _, target in targets do
			local combatant = registry.CombatService.Get(target.character)
			if combatant and combatant.team == "Player" then
				registry.CombatService.ApplyDamage(handle.combatant, combatant, {
					baseDamage = damage,
					swingMultiplier = 1,
					hitStop = 0.05,
					shake = 1.1,
				})
				if applies then
					registry.StatusService.Apply(target.character, applies, {
						sourceDamage = damage,
						source = handle.character,
					})
				end
			end
		end
	end)
end

--- An instant ring pushing out from the boss.
function ArenaEffects.Shockwave(handle: BossHandle, spec: any)
	task.delay(spec.delay or 0, function()
		if not handle.alive then
			return
		end
		delayedArea(handle, handle.combatant.root.Position, spec.radius, spec.damage, 0.05)
	end)
end

--- A ring that travels outward, so the safe move is to be close or to outrun it.
function ArenaEffects.RingWave(handle: BossHandle, spec: any)
	local origin = handle.combatant.root.Position
	local radius = spec.innerRadius

	local ring = PartFactory.Decor({
		Name = "RingWave",
		Size = Vector3.new(radius * 2, 1, radius * 2),
		Shape = Enum.PartType.Cylinder,
		Color = Color3.fromRGB(255, 150, 90),
		Material = Enum.Material.Neon,
		Transparency = 0.45,
		CFrame = CFrame.new(origin) * CFrame.Angles(0, 0, math.rad(90)),
		Parent = registry.World.Effects,
	})

	local hit: { [Model]: boolean } = {}
	task.spawn(function()
		while handle.alive and radius < spec.outerRadius do
			task.wait(0.05)
			radius += spec.speed * 0.05
			ring.Size = Vector3.new(1, radius * 2, radius * 2)

			local targets = Hitbox.Query(CFrame.new(origin), {
				shape = "Sphere",
				range = radius,
				height = 16,
				maxTargets = 8,
			}, { handle.character })

			for _, target in targets do
				local distance = (flat(target.character:GetPivot().Position - origin)).Magnitude
				-- Only the leading edge hurts, which is what makes the ring dodgeable.
				if not hit[target.character] and distance >= radius - 6 and distance <= radius + 2 then
					local combatant = registry.CombatService.Get(target.character)
					if combatant and combatant.team == "Player" then
						hit[target.character] = true
						registry.CombatService.ApplyDamage(handle.combatant, combatant, {
							baseDamage = spec.damage,
							swingMultiplier = 1,
							shake = 1.0,
						})
					end
				end
			end
		end
		ring:Destroy()
	end)
end

--- Falling impacts at scattered points. The classic "keep moving" pressure.
function ArenaEffects.Meteors(handle: BossHandle, spec: any)
	local origin = handle.arenaOrigin.Position
	local arenaRadius = handle.definition.arena.radius

	for index = 1, spec.count do
		task.delay(index * 0.12, function()
			if not handle.alive then
				return
			end
			-- Half the meteors aim at where a player currently is, half are random.
			-- Purely random is ignorable; purely targeted is unfair.
			local position
			if index % 2 == 0 and handle.target then
				position = handle.target.root.Position + Vector3.new(math.random(-8, 8), 0, math.random(-8, 8))
			else
				local angle = math.random() * math.pi * 2
				local distance = math.sqrt(math.random()) * arenaRadius * 0.85
				position = origin + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
			end
			delayedArea(handle, position, spec.radius, spec.damage, spec.warnTime, spec.applies)
		end)
	end
end

--- Straight lines radiating from the boss.
function ArenaEffects.IceLances(handle: BossHandle, spec: any)
	local origin = handle.combatant.root.Position
	local baseAngle = math.random() * math.pi * 2

	for index = 1, spec.count do
		local angle = baseAngle + (index / spec.count) * math.pi * 2
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local centre = origin + direction * (spec.length * 0.5)
		local cframe = CFrame.lookAt(centre, centre + direction)

		local marker = PartFactory.Decor({
			Name = "LanceWarning",
			Size = Vector3.new(spec.width, 0.2, spec.length),
			Color = Color3.fromRGB(150, 220, 255),
			Material = Enum.Material.Neon,
			Transparency = 0.55,
			CFrame = cframe,
			Parent = registry.World.Effects,
		})
		Debris:AddItem(marker, spec.warnTime + 0.25)

		task.delay(spec.warnTime, function()
			if not handle.alive then
				return
			end
			local targets = Hitbox.Query(cframe, {
				shape = "Box",
				range = spec.length,
				width = spec.width * 0.5,
				height = 14,
				maxTargets = 6,
			}, { handle.character })

			for _, target in targets do
				local combatant = registry.CombatService.Get(target.character)
				if combatant and combatant.team == "Player" then
					registry.CombatService.ApplyDamage(handle.combatant, combatant, {
						baseDamage = spec.damage,
						swingMultiplier = 1,
						shake = 0.9,
					})
					registry.StatusService.Apply(target.character, "Chill", {
						sourceDamage = spec.damage,
						source = handle.character,
						stacks = 2,
					})
				end
			end
		end)
	end
end

--[[
	The undodgeable one. Everything except an annulus takes the hit, so the answer
	is to be standing in the right place -- not to press dodge. Exactly one of
	these exists per boss, and the telegraph is correspondingly enormous.
]]
function ArenaEffects.SafeRing(handle: BossHandle, spec: any)
	local origin = handle.combatant.root.Position
	local arenaRadius = handle.definition.arena.radius

	local danger = PartFactory.Decor({
		Name = "SafeRingDanger",
		Size = Vector3.new(arenaRadius * 2, 0.2, arenaRadius * 2),
		Shape = Enum.PartType.Cylinder,
		Color = Color3.fromRGB(255, 60, 60),
		Material = Enum.Material.Neon,
		Transparency = 0.75,
		CFrame = CFrame.new(origin) * CFrame.Angles(0, 0, math.rad(90)),
		Parent = registry.World.Effects,
	})
	local safe = PartFactory.Decor({
		Name = "SafeRingSafe",
		Size = Vector3.new(spec.safeOuter * 2, 0.3, spec.safeOuter * 2),
		Shape = Enum.PartType.Cylinder,
		Color = Color3.fromRGB(120, 255, 170),
		Material = Enum.Material.Neon,
		Transparency = 0.6,
		CFrame = CFrame.new(origin + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Parent = registry.World.Effects,
	})
	Debris:AddItem(danger, spec.telegraphTime + 0.4)
	Debris:AddItem(safe, spec.telegraphTime + 0.4)

	task.delay(spec.telegraphTime, function()
		if not handle.alive then
			return
		end
		for _, combatant in registry.CombatService.AllCombatants() do
			if combatant.team == "Player" and combatant.alive then
				local distance = (flat(combatant.root.Position - origin)).Magnitude
				local inSafeBand = distance >= spec.safeInner and distance <= spec.safeOuter
				if not inSafeBand then
					registry.CombatService.ApplyDamage(handle.combatant, combatant, {
						baseDamage = spec.damage,
						swingMultiplier = 1,
						hitStop = 0.12,
						shake = 2.2,
					})
				end
			end
		end
	end)
end

--- Chunks of the arena thrown at the player.
function ArenaEffects.ThrownDebris(handle: BossHandle, spec: any)
	for index = 1, spec.count do
		task.delay(index * 0.25, function()
			if not handle.alive or not handle.target then
				return
			end
			local landing = handle.target.root.Position + Vector3.new(math.random(-10, 10), 0, math.random(-10, 10))

			local rock = PartFactory.Decor({
				Name = "Debris",
				Size = Vector3.new(5, 5, 5),
				Color = Color3.fromRGB(70, 78, 84),
				Material = Enum.Material.Slate,
				CFrame = CFrame.new(handle.combatant.root.Position + Vector3.new(0, 12, 0)),
				Parent = registry.World.Effects,
			})
			Debris:AddItem(rock, spec.travelTime + 0.6)

			local startPosition = rock.Position
			local elapsed = 0
			local connection
			connection = game:GetService("RunService").Heartbeat:Connect(function(dt)
				elapsed += dt
				local alpha = math.clamp(elapsed / spec.travelTime, 0, 1)
				-- Arc, so the shadow on the ground reads before the rock arrives.
				local height = math.sin(alpha * math.pi) * 22
				rock.CFrame = CFrame.new(startPosition:Lerp(landing, alpha) + Vector3.new(0, height, 0))
					* CFrame.Angles(elapsed * 4, elapsed * 3, 0)
				if alpha >= 1 then
					connection:Disconnect()
				end
			end)
			handle.maid:Add(connection)

			delayedArea(handle, landing, spec.radius, spec.damage, spec.travelTime)
		end)
	end
end

--- Fire left on the floor. Denies ground rather than dealing burst damage.
function ArenaEffects.GroundFire(handle: BossHandle, spec: any)
	local origin = handle.combatant.root.Position

	local zone = PartFactory.Decor({
		Name = "GroundFire",
		Size = Vector3.new(spec.radius * 2, 0.4, spec.radius * 2),
		Shape = Enum.PartType.Cylinder,
		Color = Color3.fromRGB(255, 110, 40),
		Material = Enum.Material.Neon,
		Transparency = 0.4,
		CFrame = CFrame.new(origin) * CFrame.Angles(0, 0, math.rad(90)),
		Parent = registry.World.Effects,
	})
	Debris:AddItem(zone, spec.duration)

	local elapsed = 0
	task.spawn(function()
		while handle.alive and elapsed < spec.duration do
			task.wait(0.5)
			elapsed += 0.5
			local targets = Hitbox.Query(CFrame.new(origin), {
				shape = "Sphere",
				range = spec.radius,
				height = 10,
				maxTargets = 8,
			}, { handle.character })
			for _, target in targets do
				local combatant = registry.CombatService.Get(target.character)
				if combatant and combatant.team == "Player" then
					registry.CombatService.ApplyDamage(handle.combatant, combatant, {
						baseDamage = spec.tickDamage,
						swingMultiplier = 1,
						element = "Cinder",
					})
					registry.StatusService.Apply(target.character, "Burn", {
						sourceDamage = spec.tickDamage,
						source = handle.character,
					})
				end
			end
		end
	end)
end

--------------------------------------------------------------------------------
-- Structural arena changes, used by phase transitions.
--------------------------------------------------------------------------------

function ArenaEffects.ShatterPillars(handle: BossHandle, spec: any)
	local broken = 0
	for _, part in handle.arenaParts do
		if part.Name == "ArenaPillar" and broken < spec.count and part.Parent then
			broken += 1
			-- The pillar becomes rubble: cover for the player, and one less thing
			-- to circle behind.
			local rubble = PartFactory.Part({
				Name = "Rubble",
				Size = Vector3.new(part.Size.X * 1.4, 5, part.Size.Z * 1.4),
				Color = part.Color,
				Material = part.Material,
				CFrame = CFrame.new(part.Position.X, handle.arenaOrigin.Position.Y + 2.5, part.Position.Z)
					* CFrame.Angles(0, math.random() * 6, math.rad(math.random(-8, 8))),
				Parent = registry.World.Run,
			})
			handle.maid:Add(rubble)
			delayedArea(handle, part.Position, 12, spec.debrisDamage, 0.8)
			part:Destroy()
		end
	end
end

function ArenaEffects.ExposeCore(handle: BossHandle, spec: any)
	local torso = handle.character:FindFirstChild("Torso")
	if torso and torso:IsA("BasePart") then
		torso.Material = Enum.Material.Neon
		torso.Color = spec.glowColor or Color3.fromRGB(255, 200, 110)
		PartFactory.PointLight(torso, spec.glowColor or Color3.fromRGB(255, 200, 110), 4, 30)
	end
	handle.combatant.weakPointsActive = true
end

function ArenaEffects.BurnPlatforms(handle: BossHandle, spec: any)
	local removed = 0
	for _, part in handle.arenaParts do
		if part.Name == "ArenaPlatform" and removed < spec.count and part.Parent then
			removed += 1
			part.Color = Color3.fromRGB(255, 120, 50)
			part.Material = Enum.Material.Neon
			local doomed = part
			task.delay(spec.warnTime, function()
				if doomed.Parent then
					doomed:Destroy()
				end
			end)
		end
	end
	if spec.exposeCore then
		ArenaEffects.ExposeCore(handle, {})
	end
end

function ArenaEffects.RaiseIceWalls(handle: BossHandle, spec: any)
	local origin = handle.arenaOrigin.Position
	local radius = handle.definition.arena.radius * 0.55
	for index = 1, spec.count do
		local angle = (index / spec.count) * math.pi * 2
		local position = origin + Vector3.new(math.cos(angle) * radius, spec.height * 0.5, math.sin(angle) * radius)
		local wall = PartFactory.Part({
			Name = "IceWall",
			Size = Vector3.new(3, spec.height, 26),
			Color = Color3.fromRGB(190, 230, 255),
			Material = Enum.Material.Ice,
			Transparency = 0.25,
			CFrame = CFrame.new(position) * CFrame.Angles(0, angle, 0),
			Parent = registry.World.Run,
		})
		table.insert(handle.arenaParts, wall)
		handle.maid:Add(wall)
	end
end

function ArenaEffects.ShatterIceWalls(handle: BossHandle, spec: any)
	for _, part in handle.arenaParts do
		if part.Name == "IceWall" and part.Parent then
			delayedArea(handle, part.Position, 14, spec.debrisDamage, 0.6)
			part:Destroy()
		end
	end
	if spec.exposeCore then
		ArenaEffects.ExposeCore(handle, {})
	end
end

function ArenaEffects.SlipPatches() end -- placed at arena build time, nothing to do here

--------------------------------------------------------------------------------
-- Phases
--------------------------------------------------------------------------------

local function speak(handle: BossHandle, line: string)
	Net.FireAllClients("Dialogue", {
		npcId = handle.id,
		npcName = handle.definition.displayName,
		lines = { line },
		style = "Boss",
	})
end

local function runArenaEffect(handle: BossHandle, spec: any)
	if not spec then
		return
	end
	local handler = ArenaEffects[spec.kind]
	if not handler then
		warn(("[BossService] unknown arena effect %q"):format(tostring(spec.kind)))
		return
	end
	local ok, err = pcall(handler, handle, spec)
	if not ok then
		warn(("[BossService] arena effect %s failed: %s"):format(spec.kind, tostring(err)))
	end
end

local function enterPhase(handle: BossHandle, phaseIndex: number)
	local phase = handle.definition.phases[phaseIndex]
	if not phase then
		return
	end

	handle.phaseIndex = phaseIndex
	handle.phase = phase
	handle.combatant.baseWalkSpeed = phase.moveSpeed
	handle.combatant.weakPointsActive = phase.weakPointsActive == true

	local transition = phase.transition
	if not transition then
		return
	end

	handle.transitioning = true
	handle.combatant.invulnerableUntil = os.clock() + transition.duration
	handle.combatant.superArmorUntil = os.clock() + transition.duration
	handle.combatant.action = "Locked"
	handle.combatant.actionEndsAt = os.clock() + transition.duration
	handle.combatant.phaseEndsAt = handle.combatant.actionEndsAt

	Net.FireAllClients("PlayClip", {
		characterId = handle.character:GetAttribute("NetId"),
		clip = transition.clip,
		speed = 1,
	})

	if transition.line then
		local line = handle.definition.dialogue[transition.line]
		if line then
			speak(handle, line)
		end
	end

	runArenaEffect(handle, transition.arenaEffect)

	if transition.spawns and handle.encounter then
		for _, group in transition.spawns do
			for _ = 1, group.count do
				local angle = math.random() * math.pi * 2
				local distance = handle.definition.arena.radius * 0.6
				local position = handle.arenaOrigin.Position
					+ Vector3.new(math.cos(angle) * distance, 2, math.sin(angle) * distance)
				registry.EnemyService.Spawn(group.enemy, position, handle.encounter, {
					healthScale = 1,
					damageScale = 1,
				})
			end
		end
	end

	task.delay(transition.duration, function()
		handle.transitioning = false
		if handle.combatant.action == "Locked" then
			handle.combatant.action = "Idle"
			handle.combatant.phase = "Done"
		end
	end)

	BossService.PhaseChanged:Fire(handle.id, phaseIndex)
end

--------------------------------------------------------------------------------
-- Spawning
--------------------------------------------------------------------------------

function BossService.Spawn(bossId: string, arenaOrigin: CFrame, container: Folder, encounter: any, arenaParts: { BasePart }): BossHandle?
	local definition = BossConfig.Get(bossId)
	if not definition then
		return nil
	end

	local rig = RigBuilder.Build({
		name = definition.displayName,
		scale = definition.rig.scale,
		palette = definition.rig.palette,
		silhouette = definition.rig.silhouette,
		material = definition.rig.material,
		glow = definition.rig.glow,
		maxHealth = definition.stats.maxHealth,
		walkSpeed = definition.phases[1].moveSpeed,
	})

	rig:PivotTo(arenaOrigin * CFrame.new(0, 6, -30))
	rig.Parent = container
	PartFactory.SetCollisionGroup(rig, GameConfig.Collision.Enemy)
	rig:SetAttribute("IsBoss", true)
	rig:SetAttribute("DisplayName", definition.displayName)

	local combatant = registry.CombatService.Register(rig, "Enemy", {
		poiseThreshold = math.huge, -- bosses use the break meter instead
	})
	if not combatant then
		rig:Destroy()
		return nil
	end

	combatant.weight = definition.stats.weight
	combatant.unstaggerable = true
	combatant.baseWalkSpeed = definition.phases[1].moveSpeed

	local weakPoints: { [string]: number } = {}
	for _, entry in definition.weakPoints do
		weakPoints[entry.part] = entry.multiplier
	end
	combatant.weakPoints = weakPoints
	combatant.weakPointsActive = false

	nextHandleId += 1

	local handle: BossHandle = {
		handleId = ("boss_%d"):format(nextHandleId),
		id = bossId,
		definition = definition,
		combatant = combatant,
		character = rig,
		maid = Maid.new(),
		arenaOrigin = arenaOrigin,
		arenaParts = arenaParts or {},

		phaseIndex = 0,
		phase = definition.phases[1],
		transitioning = false,

		breakMeter = 0,
		brokenUntil = 0,

		attackCooldowns = {},
		nextDecisionAt = os.clock() + 1.5,
		target = nil,

		encounter = encounter,
		alive = true,
		playerTookDamage = false,
		startedAt = os.clock(),
	}

	handle.maid:Add(rig)
	active[handle.handleId] = handle

	-- The greeting is chosen by how many times this boss has killed this player.
	task.delay(0.6, function()
		if not handle.alive then
			return
		end
		local deaths = registry.ProgressionService.DeathsToBoss(bossId)
		local line = BossConfig.MeetLine(bossId, deaths)
		if line then
			speak(handle, line)
		end
	end)

	-- Phase one has no transition, so entering it is silent and immediate.
	handle.phaseIndex = 1
	handle.phase = definition.phases[1]

	combatant.humanoid.Died:Connect(function()
		BossService.HandleDefeat(handle)
	end)

	return handle
end

--------------------------------------------------------------------------------
-- Break meter
--------------------------------------------------------------------------------

function BossService.AddBreak(handle: BossHandle, amount: number)
	if os.clock() < handle.brokenUntil then
		return
	end

	handle.breakMeter += amount
	if handle.breakMeter >= handle.definition.stats.breakThreshold then
		handle.breakMeter = 0
		handle.brokenUntil = os.clock() + handle.definition.stats.breakDuration

		handle.combatant.action = "Staggered"
		handle.combatant.actionEndsAt = handle.brokenUntil
		handle.combatant.phaseEndsAt = handle.brokenUntil
		handle.combatant.staggerUntil = handle.brokenUntil
		handle.combatant.weakPointsActive = true

		Net.FireAllClients("PlayClip", {
			characterId = handle.character:GetAttribute("NetId"),
			clip = "Boss_Exposed",
			speed = 1,
		})
		Net.FireAllClients("CombatFeedback", {
			kind = "BossBreak",
			position = handle.combatant.root.Position,
			amount = 0,
			shake = 2.0,
		})

		task.delay(handle.definition.stats.breakDuration, function()
			if handle.alive then
				handle.combatant.weakPointsActive = handle.phase.weakPointsActive == true
			end
		end)
	end
end

--------------------------------------------------------------------------------
-- Defeat
--------------------------------------------------------------------------------

function BossService.HandleDefeat(handle: BossHandle)
	if not handle.alive then
		return
	end
	handle.alive = false

	local record = registry.ProgressionService.BossRecordSnapshot(handle.id)
	local firstTime = not record or record.kills == 0
	local line = if firstTime then handle.definition.dialogue.onFirstDefeat else handle.definition.dialogue.onDefeat
	if line then
		speak(handle, line)
	end

	Net.FireAllClients("BossSync", { active = false })
	-- The handle travels with the signal so the listener can tell which session's
	-- Warden this was.
	BossService.BossDefeated:Fire(handle.id, {
		flawless = not handle.playerTookDamage,
		duration = os.clock() - handle.startedAt,
	}, handle)

	Debris:AddItem(handle.character, 6)
	active[handle.handleId] = nil
end

--- Removes one boss. Used when its session ends.
function BossService.Despawn(handle: BossHandle?)
	if not handle then
		return
	end
	handle.alive = false
	handle.maid:DoCleaning()
	active[handle.handleId] = nil
	Net.FireAllClients("BossSync", { active = false })
end

function BossService.DespawnAll()
	for id, handle in active do
		handle.alive = false
		handle.maid:DoCleaning()
		active[id] = nil
	end
	Net.FireAllClients("BossSync", { active = false })
end

--------------------------------------------------------------------------------
-- Tick
--------------------------------------------------------------------------------

local function pickAttack(handle: BossHandle, distance: number)
	local currentTime = os.clock()
	local usable = {}
	for _, attack in handle.phase.attacks do
		if distance >= attack.minRange and distance <= attack.maxRange then
			if (handle.attackCooldowns[attack.id] or 0) <= currentTime then
				table.insert(usable, attack)
			end
		end
	end
	if #usable == 0 then
		return nil
	end

	local total = 0
	for _, attack in usable do
		total += attack.weight
	end
	local roll = math.random() * total
	for _, attack in usable do
		roll -= attack.weight
		if roll <= 0 then
			return attack
		end
	end
	return usable[#usable]
end

local function startBossAttack(handle: BossHandle, attack: any)
	handle.attackCooldowns[attack.id] = os.clock() + attack.cooldown * handle.phase.tempo

	Net.FireAllClients("Telegraph", {
		id = handle.character:GetAttribute("NetId"),
		shape = attack.telegraphShape or "Cone",
		cframe = CFrame.lookAt(handle.combatant.root.Position, handle.combatant.root.Position + handle.combatant.facing)
			* CFrame.new(attack.hitbox.offset or Vector3.zero),
		range = attack.hitbox.range,
		angle = attack.hitbox.angle,
		width = attack.hitbox.width,
		duration = attack.telegraph,
		undodgeable = attack.undodgeable == true,
		boss = true,
	})

	registry.CombatService.StartEnemyAttack(handle.combatant, attack, 1)

	if attack.arenaEffect then
		-- Arena effects fire at the moment the hitbox would open, so the two read
		-- as one attack rather than two events.
		task.delay(attack.windup, function()
			if handle.alive then
				runArenaEffect(handle, attack.arenaEffect)
			end
		end)
	end

	if attack.spawns and handle.encounter then
		task.delay(attack.windup, function()
			if not handle.alive then
				return
			end
			for _, group in attack.spawns do
				for _ = 1, group.count do
					local angle = math.random() * math.pi * 2
					local distance = handle.definition.arena.radius * 0.7
					registry.EnemyService.Spawn(
						group.enemy,
						handle.arenaOrigin.Position + Vector3.new(math.cos(angle) * distance, 2, math.sin(angle) * distance),
						handle.encounter,
						{}
					)
				end
			end
		end)
	end

	if attack.repeats and attack.repeats > 1 then
		for index = 2, attack.repeats do
			task.delay((attack.windup + attack.active) * (index - 1) + (attack.repeatInterval or 0.3) * (index - 1), function()
				if handle.alive and not handle.transitioning then
					registry.CombatService.StartEnemyAttack(handle.combatant, attack, 1)
				end
			end)
		end
	end

	if attack.exposesFor then
		task.delay(attack.windup + attack.active + attack.recovery, function()
			if not handle.alive then
				return
			end
			handle.combatant.weakPointsActive = true
			task.delay(attack.exposesFor, function()
				if handle.alive and os.clock() >= handle.brokenUntil then
					handle.combatant.weakPointsActive = handle.phase.weakPointsActive == true
				end
			end)
		end)
	end
end

local syncAccumulator = 0

function BossService.Tick(deltaTime: number)
	syncAccumulator += deltaTime

	for _, handle in active do
		if not handle.alive then
			continue
		end
		local combatant = handle.combatant
		if combatant.humanoid.Health <= 0 then
			continue
		end

		-- Phase crossing.
		local fraction = combatant.humanoid.Health / combatant.humanoid.MaxHealth
		local targetPhase = BossConfig.PhaseFor(handle.id, fraction)
		if targetPhase > handle.phaseIndex and not handle.transitioning then
			enterPhase(handle, targetPhase)
		end

		if handle.transitioning or os.clock() < handle.brokenUntil then
			continue
		end

		-- Target: nearest living player.
		local best, bestDistance = nil, math.huge
		for _, other in registry.CombatService.AllCombatants() do
			if other.team == "Player" and other.alive and other.humanoid.Health > 0 then
				local distance = (other.root.Position - combatant.root.Position).Magnitude
				if distance < bestDistance then
					best, bestDistance = other, distance
				end
			end
		end
		handle.target = best

		if not best then
			continue
		end

		-- Face and close.
		local direction = flat(best.root.Position - combatant.root.Position)
		if direction.Magnitude > 0.5 then
			direction = direction.Unit
			local currentLook = flat(combatant.root.CFrame.LookVector)
			if currentLook.Magnitude > 0.01 then
				local blended = currentLook.Unit:Lerp(direction, math.clamp(3 * deltaTime, 0, 1))
				if blended.Magnitude > 0.01 then
					direction = blended.Unit
				end
			end
			combatant.root.CFrame = CFrame.lookAt(combatant.root.Position, combatant.root.Position + direction)
			registry.CombatService.SetFacing(combatant, direction)
		end

		if combatant.action == "Idle" then
			if os.clock() >= handle.nextDecisionAt then
				handle.nextDecisionAt = os.clock() + 0.4 * handle.phase.tempo

				local attack = pickAttack(handle, bestDistance)
				if attack and math.random() < handle.phase.aggression then
					startBossAttack(handle, attack)
				elseif handle.phase.moveSpeed > 0 and bestDistance > 14 then
					combatant.humanoid:MoveTo(best.root.Position)
				end
			end
		end
	end

	if syncAccumulator >= 0.1 then
		syncAccumulator = 0
		for _, handle in active do
			if handle.alive then
				Net.FireAllClients("BossSync", {
					active = true,
					bossId = handle.id,
					name = handle.definition.displayName,
					subtitle = handle.definition.subtitle,
					health = handle.combatant.humanoid.Health,
					maxHealth = handle.combatant.humanoid.MaxHealth,
					phase = handle.phaseIndex,
					phaseName = handle.phase.name,
					phaseCount = #handle.definition.phases,
					breakMeter = handle.breakMeter,
					breakThreshold = handle.definition.stats.breakThreshold,
					broken = os.clock() < handle.brokenUntil,
				})
			end
		end
	end
end

--------------------------------------------------------------------------------

function BossService.Init(services: any)
	registry = services
end

function BossService.Start()
	-- Poise that would stagger an ordinary enemy fills a Warden's break meter.
	registry.CombatService.PoiseApplied:Connect(function(target: any, amount: number)
		for _, handle in active do
			if handle.combatant == target then
				BossService.AddBreak(handle, amount)
				break
			end
		end
	end)

	-- Flawless tracking for the boss trophies.
	registry.CombatService.Damaged:Connect(function(target: any)
		if target.team ~= "Player" then
			return
		end
		for _, handle in active do
			if handle.alive then
				handle.playerTookDamage = true
			end
		end
	end)
end

BossService.ArenaEffects = ArenaEffects

return BossService
