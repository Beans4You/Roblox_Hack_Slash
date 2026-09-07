--!strict
--[[
	EnemyService — spawning, elites, projectiles, and the room's attack budget.

	Owns the lifetime of every enemy: builds the rig, registers it with combat,
	gives it an agent, applies run scaling and elite modifiers, and cleans it up
	when the room ends. Rooms hand it an encounter description; it turns that into
	a fight.

	ENCOUNTER BUDGETING
	A room does not say "spawn four Marchmen". It says "spend this many points",
	and the service buys enemies from the region's weighted pool until the budget
	runs out. That keeps encounter difficulty roughly constant while the
	composition varies, which is most of what stops a run feeling repetitive.

	CLEANUP
	Every enemy belongs to a room's Maid. When the room ends, the Maid runs, agents
	stop, rigs are destroyed and the token pool is discarded. Nothing survives a
	run except what the player earned.
]]

local Debris = game:GetService("Debris")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local GameConfig = require(Shared.Config.GameConfig)
local EnemyConfig = require(Shared.Config.EnemyConfig)
local StatusConfig = require(Shared.Config.StatusConfig)
local Hitbox = require(Shared.Combat.Hitbox)
local RigBuilder = require(Shared.Util.RigBuilder)
local PartFactory = require(Shared.Util.PartFactory)
local Maid = require(Shared.Util.Maid)
local Rng = require(Shared.Util.Rng)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net.Net)

local EnemyAgent = require(script.Parent.EnemyAgent)

local EnemyService = {}

EnemyService.EnemyKilled = Signal.new()
EnemyService.RoomCleared = Signal.new()

local registry: any = nil

--- Cost in encounter points. Derived from the enemy rather than authored, so a
--- balance change to an enemy's health automatically reprices it.
local function enemyCost(definition: any): number
	local stats = definition.stats
	return math.max(1, math.floor(stats.maxHealth / 22 + stats.damageScale * 4))
end

--------------------------------------------------------------------------------
-- Encounter groups
--------------------------------------------------------------------------------

export type Encounter = {
	id: string,
	container: Folder,
	maid: any,
	agents: { any },
	tokens: { available: number },
	remaining: number,
	cleared: boolean,
	onCleared: any,
}

local encounters: { [string]: Encounter } = {}
local nextEncounterId = 0

local function newEncounter(container: Folder): Encounter
	nextEncounterId += 1
	local id = ("encounter_%d"):format(nextEncounterId)

	local encounter: Encounter = {
		id = id,
		container = container,
		maid = Maid.new(),
		agents = {},
		tokens = { available = GameConfig.Enemies.AttackTokens },
		remaining = 0,
		cleared = false,
		onCleared = Signal.new(),
	}
	encounters[id] = encounter
	return encounter
end

--------------------------------------------------------------------------------
-- Spawning
--------------------------------------------------------------------------------

local function applyEliteModifier(combatant: any, agent: any, modifier: any, definition: any)
	local apply = modifier.apply

	if apply.speedScale then
		combatant.baseWalkSpeed *= apply.speedScale
		combatant.humanoid.WalkSpeed *= apply.speedScale
	end
	if apply.unstaggerable then
		combatant.unstaggerable = true
	end
	if apply.frontalReduction then
		combatant.frontalBlockAngle = 120
	end
	if apply.lifesteal then
		agent.lifesteal = apply.lifesteal
	end
	if apply.deathExplosion then
		agent.deathExplosion = apply.deathExplosion
	end
	if apply.onHitStatus then
		agent.onHitStatus = apply.onHitStatus
	end
	if apply.wardHealth then
		combatant.humanoid.MaxHealth *= (1 + apply.wardHealth)
		combatant.humanoid.Health = combatant.humanoid.MaxHealth
	end

	-- Elites are visibly different at a glance, in the modifier's colour.
	local highlight = PartFactory.Highlight(combatant.character, modifier.color, modifier.color, 0.92)
	highlight.Parent = combatant.character
	combatant.character:SetAttribute("EliteModifier", modifier.id)
end

--[[
	Builds one enemy and puts it in the world.

	`scaling` carries the run's health and damage multipliers. Health is applied to
	MaxHealth so the enemy's bar still reads 100%; damage is passed to the agent,
	which applies it per attack.
]]
function EnemyService.Spawn(enemyId: string, position: Vector3, encounter: Encounter, options: any?): any?
	local definition = EnemyConfig.Get(enemyId)
	if not definition then
		warn(("[EnemyService] unknown enemy %q"):format(enemyId))
		return nil
	end

	local opts = options or {}
	local isElite = opts.elite == true
	local rigSpec = definition.rig

	local rig = RigBuilder.Build({
		name = definition.displayName,
		scale = rigSpec.scale * (if isElite then GameConfig.Enemies.EliteScale else 1),
		palette = rigSpec.palette,
		silhouette = rigSpec.silhouette,
		material = rigSpec.material,
		glow = rigSpec.glow,
		maxHealth = definition.stats.maxHealth * (opts.healthScale or 1)
			* (if isElite then GameConfig.Enemies.EliteHealthMultiplier else 1),
		walkSpeed = definition.stats.chaseSpeed,
	})

	rig:PivotTo(CFrame.new(position + Vector3.new(0, 3, 0)))
	rig.Parent = encounter.container
	PartFactory.SetCollisionGroup(rig, GameConfig.Collision.Enemy)

	registry.WeaponService.EquipEnemyWeapon(rig, enemyId, rigSpec.scale)

	local combatant = registry.CombatService.Register(rig, "Enemy", {
		poiseThreshold = definition.stats.poiseThreshold,
	})
	if not combatant then
		rig:Destroy()
		return nil
	end

	combatant.weight = definition.stats.weight
	combatant.baseWalkSpeed = definition.stats.chaseSpeed
	if definition.behavior.blocksFrontal then
		combatant.frontalBlockAngle = definition.behavior.blocksFrontal
	end

	rig:SetAttribute("EnemyId", enemyId)
	rig:SetAttribute("DisplayName", definition.displayName)
	rig:SetAttribute("IsElite", isElite)

	local damageScale = (opts.damageScale or 1) * (if isElite then GameConfig.Enemies.EliteDamageMultiplier else 1)

	local agent = EnemyAgent.new(combatant, definition, {
		CombatService = registry.CombatService,
		StatusService = registry.StatusService,
		tokens = encounter.tokens,
	}, {
		damageScale = damageScale,
		healthScale = opts.healthScale,
	})

	if isElite and opts.eliteModifier then
		applyEliteModifier(combatant, agent, opts.eliteModifier, definition)
	end

	-- Flyers hover rather than fall.
	if definition.behavior.flying then
		combatant.root.CustomPhysicalProperties = PhysicalProperties.new(0.1, 0, 0, 0, 0)
		local force = Instance.new("VectorForce")
		local attachment = Instance.new("Attachment")
		attachment.Parent = combatant.root
		force.Attachment0 = attachment
		force.Force = Vector3.new(0, workspace.Gravity * rig:GetExtentsSize().Magnitude * 0.6, 0)
		force.RelativeTo = Enum.ActuatorRelativeTo.World
		force.Parent = combatant.root
	end

	table.insert(encounter.agents, agent)
	encounter.remaining += 1
	encounter.maid:Add(function()
		agent:Destroy()
	end)
	encounter.maid:Add(rig)

	combatant.humanoid.Died:Connect(function()
		EnemyService.HandleEnemyDeath(agent, encounter, definition, isElite)
	end)

	return agent
end

--------------------------------------------------------------------------------
-- Death
--------------------------------------------------------------------------------

function EnemyService.HandleEnemyDeath(agent: any, encounter: Encounter, definition: any, isElite: boolean)
	if not agent.alive then
		return
	end
	agent.alive = false
	agent:ReleaseToken()

	local character = agent.character
	local position = agent.root.Position

	-- Death explosions: the Censer's whole purpose, and the Volatile elite's.
	local explosion = agent.deathExplosion or (definition.onDeath and definition.onDeath.kind == "Explode" and definition.onDeath)
	if explosion then
		task.delay(explosion.delay or 0.2, function()
			EnemyService.Detonate(position, explosion, character)
		end)
	end

	encounter.remaining -= 1
	EnemyService.EnemyKilled:Fire(definition.id, isElite, position, character)

	if encounter.remaining <= 0 and not encounter.cleared then
		encounter.cleared = true
		encounter.onCleared:Fire()
		EnemyService.RoomCleared:Fire(encounter.id)
	end

	-- Corpses linger briefly so a kill has weight, then go. Nothing accumulates.
	Debris:AddItem(character, GameConfig.Enemies.CorpseLifetime)
end

--[[
	Area detonation. `damagesEnemies` is on for Censers on purpose: killing one
	next to its friends is the most satisfying thing a player can do with the
	enemy roster, and taking that away to avoid "friendly fire weirdness" would be
	a mistake.
]]
function EnemyService.Detonate(position: Vector3, spec: any, source: Model?)
	local origin = CFrame.new(position)
	local targets = Hitbox.Query(origin, {
		shape = "Sphere",
		range = spec.radius,
		height = spec.radius,
		maxTargets = 16,
	}, { source :: Instance })

	for _, target in targets do
		local combatant = registry.CombatService.Get(target.character)
		if combatant and combatant.alive then
			local isEnemy = combatant.team == "Enemy"
			if not isEnemy or spec.damagesEnemies then
				registry.CombatService.ApplyDamage(nil, combatant, {
					baseDamage = spec.damage,
					swingMultiplier = 1,
					element = spec.applies or "Physical",
					hitStop = 0.06,
					shake = 1.2,
				})
				if spec.applies then
					registry.StatusService.Apply(target.character, spec.applies, {
						sourceDamage = spec.damage,
						source = source,
					})
				end
			end
		end
	end

	Net.FireAllClients("CombatFeedback", {
		kind = "Explosion",
		position = position,
		amount = spec.damage,
		element = spec.applies or "Physical",
		radius = spec.radius,
		shake = 1.6,
	})
end

--------------------------------------------------------------------------------
-- Encounter construction
--------------------------------------------------------------------------------

--[[
	Buys enemies from the region pool until the budget is spent.

	Two guards worth noting. The pool is filtered to enemies whose cost fits the
	remaining budget, so a big-ticket Drudge cannot be bought with three points
	left; and there is a hard cap on concurrent enemies from GameConfig, because
	exceeding it is a content bug and dropping the extra is better than dropping
	frames.
]]
function EnemyService.BuildEncounter(spec: any): Encounter
	local encounter = newEncounter(spec.container)
	local rng: any = spec.rng or Rng.new()

	local region = spec.region
	local pool = {}
	for enemyId, weight in region.enemyWeights do
		local definition = EnemyConfig.Get(enemyId)
		if definition then
			table.insert(pool, { id = enemyId, weight = weight, cost = enemyCost(definition), definition = definition })
		end
	end
	table.sort(pool, function(a, b)
		return a.id < b.id
	end)

	local budget = spec.budget
	local spawnPoints = table.clone(spec.spawnPoints)
	rng:Shuffle(spawnPoints)

	local spawned = 0
	local pointIndex = 1
	local guard = 0

	while budget > 0 and spawned < GameConfig.Performance.MaxActiveEnemies do
		guard += 1
		if guard > 200 then
			break
		end

		local affordable = {}
		for _, entry in pool do
			if entry.cost <= budget then
				table.insert(affordable, entry)
			end
		end
		if #affordable == 0 then
			break
		end

		local chosen = rng:Weighted(affordable, function(entry)
			return entry.weight
		end)
		if not chosen then
			break
		end

		local point = spawnPoints[pointIndex]
		if not point then
			pointIndex = 1
			point = spawnPoints[1]
			if not point then
				break
			end
		end
		pointIndex += 1

		-- Scatter within the spawn point so repeated visits to a layout do not
		-- place enemies identically.
		local position = spec.origin + point + rng:PointInDisc(4)

		local isElite = spec.eliteCount and spawned < spec.eliteCount
		local modifier = nil
		if isElite then
			modifier = rng:Pick(EnemyConfig.EliteModifiers)
		end

		EnemyService.Spawn(chosen.id, position, encounter, {
			healthScale = spec.healthScale,
			damageScale = spec.damageScale,
			elite = isElite,
			eliteModifier = modifier,
		})

		budget -= chosen.cost * (if isElite then 2.5 else 1)
		spawned += 1
	end

	-- An encounter that somehow bought nothing must still complete, or the room
	-- would never open its doors.
	if encounter.remaining == 0 then
		encounter.cleared = true
		task.defer(function()
			encounter.onCleared:Fire()
		end)
	end

	return encounter
end

function EnemyService.DestroyEncounter(encounterId: string)
	local encounter = encounters[encounterId]
	if not encounter then
		return
	end
	encounter.maid:DoCleaning()
	encounter.onCleared:Destroy()
	encounters[encounterId] = nil
end

function EnemyService.GetEncounter(encounterId: string): Encounter?
	return encounters[encounterId]
end

--------------------------------------------------------------------------------
-- Projectiles
--
-- Server-simulated, capped, and cleaned up on expiry. Kept deliberately simple:
-- straight-line travel with a radius check each step. Nothing in this game needs
-- projectile physics, and the simple version cannot leak.
--------------------------------------------------------------------------------

type Projectile = {
	position: Vector3,
	velocity: Vector3,
	radius: number,
	damage: number,
	source: Model?,
	team: string,
	expiresAt: number,
	part: BasePart,
	applies: string?,
	hit: { [Model]: boolean },
}

local projectiles: { Projectile } = {}

function EnemyService.FireProjectile(spec: any)
	if #projectiles >= GameConfig.Performance.MaxActiveProjectiles then
		return
	end

	local part = PartFactory.Decor({
		Name = "Projectile",
		Size = Vector3.new(0.4, 0.4, 2.4) * (spec.radius or 1),
		Color = spec.color or Color3.fromRGB(240, 220, 180),
		Material = Enum.Material.Neon,
		CFrame = CFrame.lookAt(spec.origin, spec.origin + spec.direction),
		Parent = registry.World.Projectiles,
	})

	table.insert(projectiles, {
		position = spec.origin,
		velocity = spec.direction.Unit * spec.speed,
		radius = spec.radius or 1,
		damage = spec.damage,
		source = spec.source,
		team = spec.team or "Enemy",
		expiresAt = os.clock() + (spec.maxRange / spec.speed),
		part = part,
		applies = spec.applies,
		hit = {},
	})
end

local function stepProjectiles(deltaTime: number)
	local currentTime = os.clock()

	for index = #projectiles, 1, -1 do
		local projectile = projectiles[index]
		projectile.position += projectile.velocity * deltaTime
		projectile.part.CFrame = CFrame.lookAt(projectile.position, projectile.position + projectile.velocity)

		local targets = Hitbox.Query(CFrame.new(projectile.position), {
			shape = "Sphere",
			range = projectile.radius + 1.5,
			height = 8,
			maxTargets = 4,
		}, { projectile.source :: Instance })

		local consumed = false
		for _, target in targets do
			local combatant = registry.CombatService.Get(target.character)
			if combatant and combatant.alive and combatant.team ~= projectile.team and not projectile.hit[target.character] then
				projectile.hit[target.character] = true
				registry.CombatService.ApplyDamage(
					projectile.source and registry.CombatService.Get(projectile.source) or nil,
					combatant,
					{
						baseDamage = projectile.damage,
						swingMultiplier = 1,
						hitStop = 0.03,
						shake = 0.4,
					}
				)
				if projectile.applies then
					registry.StatusService.Apply(target.character, projectile.applies, {
						sourceDamage = projectile.damage,
						source = projectile.source,
					})
				end
				consumed = true
				break
			end
		end

		if consumed or currentTime >= projectile.expiresAt then
			projectile.part:Destroy()
			table.remove(projectiles, index)
		end
	end
end

--------------------------------------------------------------------------------
-- Tick
--------------------------------------------------------------------------------

function EnemyService.Tick(deltaTime: number)
	for _, encounter in encounters do
		for index = #encounter.agents, 1, -1 do
			local agent = encounter.agents[index]
			if not agent.alive or not agent.character.Parent then
				table.remove(encounter.agents, index)
			else
				local ok, err = pcall(agent.Update, agent, deltaTime)
				if not ok then
					warn(("[EnemyService] agent error: %s"):format(tostring(err)))
				end
			end
		end
	end

	stepProjectiles(deltaTime)
end

--------------------------------------------------------------------------------

function EnemyService.Init(services: any)
	registry = services
end

function EnemyService.Start()
	-- Enemy attacks that carry a status apply it on their first landed hit.
	registry.CombatService.Damaged:Connect(function(target: any, attacker: any)
		if not attacker or attacker.team ~= "Enemy" then
			return
		end
		local status = attacker.pendingStatus
		if status and StatusConfig.Get(status) then
			registry.StatusService.Apply(target.character, status, {
				sourceDamage = attacker.enemyDamage or 10,
				source = attacker.character,
			})
		end
	end)
end

return EnemyService
