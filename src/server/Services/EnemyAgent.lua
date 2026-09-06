--!strict
--[[
	EnemyAgent — one enemy's brain.

	A small state machine per enemy: Idle, Approach, Circle, Attack, Recover,
	Reposition. What makes the fight readable is not the states, though, it is the
	two rules layered on top of them.

	ATTACK TOKENS
	A room hands out a fixed number of attack tokens (GameConfig.Enemies.AttackTokens,
	currently two). An enemy cannot enter Attack without holding one. Everything
	else circles at its preferred range, visibly waiting. This single rule is the
	difference between "a fight" and "twelve things running at your face", and it
	is why the game can put nine enemies in a room without becoming unreadable.

	TELEGRAPH FIRST, COMMIT SECOND
	An enemy picks its attack, broadcasts the telegraph, and only then starts the
	windup. Enemies never choose an attack whose telegraph the player cannot
	possibly see -- an attack is only legal inside its own range band, so a Drudge
	will not start a slam from thirty studs away and then walk into you with the
	hitbox already open.

	AGGRESSION
	`aggression` is the probability of taking an available attack rather than
	continuing to circle. A Cutter at 0.9 is relentless; a Bulwark at 0.35 spends
	most of its time being an obstacle, which is exactly what it is for.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local GameConfig = require(Shared.Config.GameConfig)
local EnemyConfig = require(Shared.Config.EnemyConfig)
local Net = require(Shared.Net.Net)

local EnemyAgent = {}
EnemyAgent.__index = EnemyAgent

export type Deps = {
	CombatService: any,
	StatusService: any,
	-- Room-scoped token pool this agent belongs to.
	tokens: { available: number },
}

local State = {
	Idle = "Idle",
	Approach = "Approach",
	Circle = "Circle",
	Attack = "Attack",
	Recover = "Recover",
	Reposition = "Reposition",
}

export type Class = typeof(setmetatable({}, EnemyAgent))

function EnemyAgent.new(combatant: any, definition: any, deps: Deps, options: any?): Class
	local opts = options or {}

	local self = setmetatable({
		combatant = combatant,
		character = combatant.character,
		humanoid = combatant.humanoid,
		root = combatant.root,
		definition = definition,
		behavior = definition.behavior,
		deps = deps,

		state = State.Idle,
		stateEnteredAt = os.clock(),
		target = nil :: any,

		-- Cooldowns are per attack id, so an enemy with a long and a short attack
		-- can keep using the short one while the long one recharges.
		attackCooldowns = {} :: { [string]: number },
		nextDecisionAt = 0,
		nextRepathAt = 0,

		holdingToken = false,
		-- Circling direction; flipped occasionally so enemies do not orbit in
		-- lockstep, which looks mechanical.
		strafeSign = if math.random() < 0.5 then -1 else 1,
		nextStrafeFlipAt = os.clock() + math.random() * 3 + 2,

		damageScale = opts.damageScale or 1,
		healthScale = opts.healthScale or 1,
		eliteModifier = opts.eliteModifier,

		-- Exploders glow as they close. Tracked here so the pulse can be sent
		-- once per change rather than every frame.
		primeLevel = 0,

		alive = true,
	}, EnemyAgent)

	return self
end

--------------------------------------------------------------------------------
-- Perception
--------------------------------------------------------------------------------

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

--- Nearest living player-team combatant inside detection range.
function EnemyAgent:AcquireTarget()
	local best, bestDistance = nil, math.huge
	local detection = self.definition.stats.detectionRange

	for _, other in self.deps.CombatService.AllCombatants() do
		if other.alive and other.team == "Player" and other.humanoid.Health > 0 then
			local distance = (other.root.Position - self.root.Position).Magnitude
			if distance < bestDistance and distance <= detection then
				best, bestDistance = other, distance
			end
		end
	end

	self.target = best
	return best
end

function EnemyAgent:DistanceToTarget(): number
	if not self.target then
		return math.huge
	end
	return (flat(self.target.root.Position - self.root.Position)).Magnitude
end

--------------------------------------------------------------------------------
-- Movement
--------------------------------------------------------------------------------

function EnemyAgent:FaceTarget(deltaTime: number)
	if not self.target then
		return
	end
	local direction = flat(self.target.root.Position - self.root.Position)
	if direction.Magnitude < 0.1 then
		return
	end
	direction = direction.Unit

	-- Turn rate is finite. An enemy that snaps to face you can invalidate a dodge
	-- you already committed to, which reads as the game cheating.
	local currentLook = flat(self.root.CFrame.LookVector)
	if currentLook.Magnitude > 0.01 then
		currentLook = currentLook.Unit
		local turnSpeed = if self.combatant.action == "Idle" then 8 else 2.5
		local blended = currentLook:Lerp(direction, math.clamp(turnSpeed * deltaTime, 0, 1))
		if blended.Magnitude > 0.01 then
			direction = blended.Unit
		end
	end

	self.root.CFrame = CFrame.lookAt(self.root.Position, self.root.Position + direction)
	self.deps.CombatService.SetFacing(self.combatant, direction)
end

function EnemyAgent:MoveTo(position: Vector3)
	if self.behavior.flying then
		-- Flyers ignore the ground entirely; they are moved by velocity toward a
		-- hover point above the target.
		local desired = position + Vector3.new(0, self.behavior.hoverHeight or 8, 0)
		local delta = desired - self.root.Position
		self.root.AssemblyLinearVelocity = delta.Unit * math.min(delta.Magnitude * 2, self.humanoid.WalkSpeed * 1.4)
		return
	end
	self.humanoid:MoveTo(position)
end

function EnemyAgent:Stop()
	if self.behavior.flying then
		self.root.AssemblyLinearVelocity = Vector3.new(0, self.root.AssemblyLinearVelocity.Y * 0.5, 0)
		return
	end
	self.humanoid:MoveTo(self.root.Position)
end

--- A point at `radius` from the target, offset around the circle.
function EnemyAgent:CirclePoint(radius: number): Vector3
	local targetPosition = self.target.root.Position
	local toSelf = flat(self.root.Position - targetPosition)
	if toSelf.Magnitude < 0.5 then
		toSelf = Vector3.new(1, 0, 0)
	end
	local angle = math.atan2(toSelf.Z, toSelf.X) + self.strafeSign * self.behavior.strafeBias * 0.9
	return targetPosition + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius
end

--------------------------------------------------------------------------------
-- Attacks
--------------------------------------------------------------------------------

--- Attacks that are off cooldown and whose range band contains the current distance.
function EnemyAgent:UsableAttacks(distance: number): { any }
	local usable = {}
	local currentTime = os.clock()
	for _, attack in self.definition.attacks do
		if distance >= attack.minRange and distance <= attack.maxRange then
			if (self.attackCooldowns[attack.id] or 0) <= currentTime then
				table.insert(usable, attack)
			end
		end
	end
	return usable
end

local function weightedPick(attacks: { any })
	local total = 0
	for _, attack in attacks do
		total += attack.weight
	end
	if total <= 0 then
		return attacks[1]
	end
	local roll = math.random() * total
	for _, attack in attacks do
		roll -= attack.weight
		if roll <= 0 then
			return attack
		end
	end
	return attacks[#attacks]
end

--[[
	Broadcasts the attack warning. Telegraph shape and size come from the attack's
	own hitbox, so the warning is literally the volume that is about to become
	dangerous -- it cannot drift out of sync with the attack it describes.
]]
function EnemyAgent:SendTelegraph(attack: any)
	local hitbox = attack.hitbox
	local origin = CFrame.lookAt(self.root.Position, self.root.Position + flat(self.root.CFrame.LookVector))

	Net.FireAllClients("Telegraph", {
		id = self.character:GetAttribute("NetId"),
		shape = attack.telegraphShape or "Cone",
		cframe = origin * CFrame.new(hitbox.offset or Vector3.zero),
		range = hitbox.range,
		angle = hitbox.angle,
		width = hitbox.width,
		duration = attack.telegraph,
		undodgeable = attack.undodgeable == true,
	})
end

function EnemyAgent:StartAttack(attack: any)
	self.attackCooldowns[attack.id] = os.clock() + attack.cooldown
	self:SendTelegraph(attack)
	-- CombatService owns the status the attack carries, so it is cleared correctly
	-- when the next attack does not carry one.
	self.deps.CombatService.StartEnemyAttack(self.combatant, attack, self.damageScale)
	self:SetState(State.Attack)
end

--------------------------------------------------------------------------------
-- Token pool
--------------------------------------------------------------------------------

function EnemyAgent:TryTakeToken(): boolean
	if self.holdingToken then
		return true
	end
	if self.deps.tokens.available <= 0 then
		return false
	end
	self.deps.tokens.available -= 1
	self.holdingToken = true
	return true
end

function EnemyAgent:ReleaseToken()
	if self.holdingToken then
		self.holdingToken = false
		self.deps.tokens.available += 1
	end
end

--------------------------------------------------------------------------------
-- State machine
--------------------------------------------------------------------------------

function EnemyAgent:SetState(state: string)
	if self.state == state then
		return
	end
	self.state = state
	self.stateEnteredAt = os.clock()
end

function EnemyAgent:Update(deltaTime: number)
	if not self.alive or self.humanoid.Health <= 0 then
		return
	end

	local combat = self.combatant
	local currentTime = os.clock()

	-- Staggered enemies do nothing at all, and give their token back so somebody
	-- else can pressure the player while they are down.
	if combat.action == "Staggered" then
		self:ReleaseToken()
		self:Stop()
		return
	end

	-- Mid-attack: hold facing loosely and wait for the machine to finish.
	if combat.action ~= "Idle" then
		if self.state == State.Attack then
			self:FaceTarget(deltaTime * 0.3)
		end
		return
	end

	if self.state == State.Attack then
		-- The attack finished.
		self:ReleaseToken()
		self:SetState(State.Recover)
	end

	if currentTime >= self.nextRepathAt then
		self.nextRepathAt = currentTime + GameConfig.Enemies.RepathInterval
		self:AcquireTarget()
	end

	local target = self.target
	if not target or target.humanoid.Health <= 0 then
		self:ReleaseToken()
		self:Stop()
		self:SetState(State.Idle)
		return
	end

	local distance = self:DistanceToTarget()
	self:FaceTarget(deltaTime)

	if currentTime >= self.nextStrafeFlipAt then
		self.strafeSign = -self.strafeSign
		self.nextStrafeFlipAt = currentTime + math.random() * 4 + 2
	end

	-- Exploders are a special case: they do not circle, do not wait for a token,
	-- and prime visibly on approach.
	if self.behavior.archetype == "Exploder" then
		self:UpdateExploder(distance)
		return
	end

	local preferred = self.behavior.preferredRange

	-- Decide at intervals rather than every frame. Continuous re-evaluation makes
	-- enemies jitter between approach and circle at the boundary.
	if currentTime >= self.nextDecisionAt then
		self.nextDecisionAt = currentTime + 0.25

		local usable = self:UsableAttacks(distance)
		if #usable > 0 and math.random() < self.definition.stats.aggression then
			if self:TryTakeToken() then
				self:StartAttack(weightedPick(usable))
				return
			end
		end

		if distance > preferred * 1.35 then
			self:SetState(State.Approach)
		elseif distance < preferred * 0.55 then
			self:SetState(State.Reposition)
		else
			self:SetState(State.Circle)
		end
	end

	if self.state == State.Approach then
		self:MoveTo(target.root.Position)
	elseif self.state == State.Circle then
		-- Waiting for a token, in the open, at range. Being visible while waiting
		-- is the point.
		self:MoveTo(self:CirclePoint(preferred))
	elseif self.state == State.Reposition then
		local away = flat(self.root.Position - target.root.Position)
		if away.Magnitude < 0.5 then
			away = Vector3.new(1, 0, 0)
		end
		self:MoveTo(self.root.Position + away.Unit * 8)
	else
		self:Stop()
	end
end

--[[
	The Censer. It walks straight in, glowing brighter, and detonates. The pulse
	level is sent as an attribute rather than a remote because it changes often
	and only matters as a visual -- attributes replicate cheaply and the client
	can drive its own glow from it.
]]
function EnemyAgent:UpdateExploder(distance: number)
	local prime = self.behavior.primesOnApproach
	if prime then
		local level = math.clamp(1 - (distance / prime.startDistance), 0, 1)
		if math.abs(level - self.primeLevel) > 0.05 then
			self.primeLevel = level
			self.character:SetAttribute("PrimeLevel", level)
		end
	end

	local attack = self.definition.attacks[1]
	if attack and distance <= attack.maxRange then
		self:StartAttack(attack)
		return
	end

	self:MoveTo(self.target.root.Position)
	self:SetState(State.Approach)
end

function EnemyAgent:Destroy()
	self.alive = false
	self:ReleaseToken()
end

EnemyAgent.State = State

return EnemyAgent
