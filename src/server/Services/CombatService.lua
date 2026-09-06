--!strict
--[[
	CombatService — the combat state machine, and the only place damage happens.

	One machine drives players, enemies and bosses. They differ in who supplies
	the intent (a client, an AI, a boss script) and in which move table they read
	from; everything after that -- phases, hitboxes, cancels, poise, damage -- is
	shared. That is why a Grace that triggers on hit works identically whether the
	hit came from a player combo or a Censer detonation.

	THE MACHINE
	Every action is windup -> active -> recovery. The hitbox exists only during
	active. A character in Idle can start anything it can afford; a character
	mid-action can only start something the current swing's cancel window allows.
	There is no other way to act.

	AUTHORITY
	The client sends "I pressed light attack, facing roughly here". The server
	decides whether that is legal, runs the hitbox against server-side positions,
	computes damage, and tells everyone what happened. The client's facing is
	honoured within a tolerance (so turning as you swing feels responsive) and
	clamped beyond it (so it cannot be used to hit things behind you).

	INPUT BUFFERING
	Buffered on both sides for different reasons. The client buffers so its own
	animation feels instant. The server buffers so an input that arrives a few
	frames before the cancel window opens still lands, rather than being dropped
	and blamed on the player. The server's buffer is one slot deep and expires --
	queueing inputs indefinitely turns a dropped frame into a delayed attack you
	no longer want.

	HIT STOP
	A successful hit briefly extends the attacker's current phase and tells nearby
	clients to freeze the visual. It is a tiny number, it is the cheapest thing in
	this file, and it is most of why a swing feels like it connected.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local GameConfig = require(Shared.Config.GameConfig)
local WeaponConfig = require(Shared.Config.WeaponConfig)
local CombatEnums = require(Shared.Combat.CombatEnums)
local Hitbox = require(Shared.Combat.Hitbox)
local DamageMath = require(Shared.Combat.DamageMath)
local Net = require(Shared.Net.Net)
local Signal = require(Shared.Util.Signal)

local CombatService = {}

CombatService.Damaged = Signal.new()
CombatService.Killed = Signal.new()
CombatService.Staggered = Signal.new()
CombatService.ParrySucceeded = Signal.new()
--- Fires with (target, amount) whenever poise damage is applied, including to
--- targets that cannot be staggered. Bosses convert it into break meter.
CombatService.PoiseApplied = Signal.new()

local Action = CombatEnums.Action
local Phase = CombatEnums.Phase

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

export type Combatant = {
	character: Model,
	humanoid: Humanoid,
	root: BasePart,
	team: string,
	player: Player?,

	-- Resolved weapon (WeaponService.Resolve output) for players; nil for enemies,
	-- which carry their moves in `enemyAttack` instead.
	weapon: any?,

	action: string,
	phase: string,
	actionStartedAt: number,
	phaseEndsAt: number,
	actionEndsAt: number,
	currentSwing: any?,
	-- Which entry of the light chain is next.
	comboIndex: number,
	lastSwingAt: number,

	-- Targets already struck by the current swing, so one swing hits once.
	hitThisSwing: { [Model]: boolean },
	nextMultiHitAt: number,
	multiHitsLeft: number,

	stamina: number,
	staminaBlockedUntil: number,
	ultimate: number,
	cooldowns: { [string]: number },

	invulnerableUntil: number,
	superArmorUntil: number,
	damageReduction: number,
	damageReductionUntil: number,

	-- Parry timing.
	parryStartedAt: number,
	parryActiveUntil: number,

	poise: number,
	poiseThreshold: number,
	staggerUntil: number,

	facing: Vector3,
	moveDirection: Vector3,
	baseWalkSpeed: number,

	-- One-slot server-side input buffer.
	bufferedIntent: string?,
	bufferedAt: number,
	bufferedFacing: Vector3?,

	-- Set by BoonService; read in the damage pipeline.
	modifiers: any,

	-- Enemy and boss extensions. Absent on players; the machine treats them as
	-- neutral defaults when they are.
	enemyDamage: number?,
	currentAttackId: string?,
	-- Status the current enemy attack applies on its first landed hit.
	pendingStatus: string?,
	-- Knockback resistance. Higher is heavier.
	weight: number?,
	-- Shieldbearers reduce damage inside this cone of their facing, in degrees.
	frontalBlockAngle: number?,
	-- Ironbound elites and bosses between breaks.
	unstaggerable: boolean?,
	-- partName -> damage multiplier, for boss weak points.
	weakPoints: { [string]: number }?,
	weakPointsActive: boolean?,

	alive: boolean,
}

local combatants: { [Model]: Combatant } = {}
local registry: any = nil
local nextNetId = 0

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function now(): number
	return os.clock()
end

local function flatUnit(vector: Vector3): Vector3
	local flat = Vector3.new(vector.X, 0, vector.Z)
	if flat.Magnitude < 1e-3 then
		return Vector3.new(0, 0, -1)
	end
	return flat.Unit
end

local function statusModifiers(character: Model)
	if registry and registry.StatusService then
		return registry.StatusService.GetModifiers(character)
	end
	return { moveSpeed = 1, damageTaken = 1, damageDealt = 1, attackSpeed = 1, incapacitated = false }
end

--- The origin every hitbox is measured from: the attacker's position with the
--- server's own idea of where they are, and the (validated) facing they claim.
local function attackOrigin(state: Combatant): CFrame
	return CFrame.lookAt(state.root.Position, state.root.Position + state.facing)
end

local function isPlayerTeam(state: Combatant): boolean
	return state.team == CombatEnums.Team.Player
end

--- Things this combatant is allowed to hit.
local function hostileTo(state: Combatant, other: Combatant): boolean
	if state.team == other.team then
		return false
	end
	return true
end

--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------

function CombatService.Register(character: Model, team: string, options: any?): Combatant?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		return nil
	end

	local opts = options or {}
	nextNetId += 1
	character:SetAttribute("NetId", nextNetId)
	character:SetAttribute("Team", team)

	local state: Combatant = {
		character = character,
		humanoid = humanoid,
		root = root,
		team = team,
		player = Players:GetPlayerFromCharacter(character),

		weapon = opts.weapon,

		action = Action.Idle,
		phase = Phase.Done,
		actionStartedAt = 0,
		phaseEndsAt = 0,
		actionEndsAt = 0,
		currentSwing = nil,
		comboIndex = 1,
		lastSwingAt = 0,

		hitThisSwing = {},
		nextMultiHitAt = 0,
		multiHitsLeft = 0,

		stamina = GameConfig.Player.BaseMaxStamina,
		staminaBlockedUntil = 0,
		ultimate = 0,
		cooldowns = {},

		invulnerableUntil = 0,
		superArmorUntil = 0,
		damageReduction = 0,
		damageReductionUntil = 0,

		parryStartedAt = 0,
		parryActiveUntil = 0,

		poise = 0,
		poiseThreshold = opts.poiseThreshold or 40,
		staggerUntil = 0,

		facing = flatUnit(root.CFrame.LookVector),
		moveDirection = Vector3.zero,
		baseWalkSpeed = humanoid.WalkSpeed,

		bufferedIntent = nil,
		bufferedAt = 0,
		bufferedFacing = nil,

		modifiers = opts.modifiers or {},
		alive = true,
	}

	combatants[character] = state

	humanoid.Died:Connect(function()
		CombatService.Unregister(character)
	end)

	return state
end

function CombatService.Unregister(character: Model)
	local state = combatants[character]
	if state then
		state.alive = false
	end
	combatants[character] = nil
end

function CombatService.Get(character: Model): Combatant?
	return combatants[character]
end

function CombatService.GetByPlayer(player: Player): Combatant?
	local character = player.Character
	return character and combatants[character] or nil
end

--- Swaps in a newly resolved weapon (equip, Temper change, mastery level-up).
function CombatService.SetWeapon(character: Model, weapon: any)
	local state = combatants[character]
	if state then
		state.weapon = weapon
		state.comboIndex = 1
		local speedScale = weapon and weapon.stats.moveSpeedMultiplier or 1
		state.baseWalkSpeed = GameConfig.Player.BaseWalkSpeed * speedScale
	end
end

function CombatService.SetModifiers(character: Model, modifiers: any)
	local state = combatants[character]
	if state then
		state.modifiers = modifiers
	end
end

--------------------------------------------------------------------------------
-- Legality
--------------------------------------------------------------------------------

local function isCommitted(state: Combatant): boolean
	return CombatEnums.Committed[state.action] == true
end

--- Whether `intent` can begin right now, and if not, whether it is worth buffering.
local function canStart(state: Combatant, intent: string): (boolean, boolean)
	if not state.alive or state.humanoid.Health <= 0 then
		return false, false
	end
	if statusModifiers(state.character).incapacitated then
		return false, false
	end
	if isCommitted(state) then
		-- Committed actions cannot be interrupted, and buffering through them is
		-- how an ultimate flows straight into a combo.
		return false, true
	end

	if state.action == Action.Idle then
		return true, false
	end

	-- Mid-action: only the current swing's cancel window decides.
	local swing = state.currentSwing
	if not swing then
		return true, false
	end

	local key = string.lower(intent)
	if key == "ultimate" then
		-- The ultimate is allowed to interrupt anything that is not committed.
		-- It costs a full meter; being told "not yet" would feel terrible.
		return true, false
	end

	local cancelScale = state.weapon and state.weapon.cancelScale or 1
	local cancelAt = WeaponConfig.CancelTime(swing, key, cancelScale)
	if not cancelAt then
		return false, true
	end
	return (now() - state.actionStartedAt) >= cancelAt, true
end

local function spendStamina(state: Combatant, amount: number): boolean
	if amount <= 0 then
		return true
	end
	if state.stamina < amount then
		return false
	end
	state.stamina -= amount
	state.staminaBlockedUntil = now() + GameConfig.Player.StaminaRegenDelay
	return true
end

local function onCooldown(state: Combatant, key: string): boolean
	return (state.cooldowns[key] or 0) > now()
end

--------------------------------------------------------------------------------
-- Starting actions
--------------------------------------------------------------------------------

local function broadcastClip(state: Combatant, clip: string, speed: number?)
	Net.FireAllClients("PlayClip", {
		characterId = state.character:GetAttribute("NetId"),
		clip = clip,
		speed = speed or 1,
	})
end

local function beginSwing(state: Combatant, action: string, swing: any, extra: any?)
	local at = now()
	local speedScale = statusModifiers(state.character).attackSpeed
	local duration = WeaponConfig.SwingDuration(swing) / math.max(0.2, speedScale)

	state.action = action
	state.phase = Phase.Windup
	state.currentSwing = swing
	state.actionStartedAt = at
	state.actionEndsAt = at + duration
	state.phaseEndsAt = at + swing.windup / math.max(0.2, speedScale)
	state.hitThisSwing = {}
	state.lastSwingAt = at

	local multiHit = extra and extra.multiHit
	state.multiHitsLeft = multiHit and multiHit.ticks or 1
	state.nextMultiHitAt = 0

	if extra and extra.invulnerable then
		state.invulnerableUntil = math.max(state.invulnerableUntil, state.actionEndsAt)
	end
	if extra and extra.selfEffect then
		local effect = extra.selfEffect
		if effect.damageReduction then
			state.damageReduction = effect.damageReduction
			state.damageReductionUntil = at + swing.windup + swing.active
		end
		if effect.superArmor then
			state.superArmorUntil = math.max(state.superArmorUntil, state.actionEndsAt)
		end
		if effect.invulnerable then
			state.invulnerableUntil = math.max(state.invulnerableUntil, at + swing.windup + swing.active)
		end
	end
	if swing.superArmorFrom then
		state.superArmorUntil = math.max(state.superArmorUntil, at + swing.superArmorFrom)
	end

	broadcastClip(state, swing.clip, speedScale)

	-- Root motion. Applied as a velocity impulse rather than a CFrame set, so it
	-- interacts correctly with walls and with the physics the client is simulating.
	if swing.motion then
		local direction = state.facing
		if swing.motion.direction == "Input" and state.moveDirection.Magnitude > 0.1 then
			direction = flatUnit(state.moveDirection)
		end
		CombatService.ApplyImpulse(state, direction * (swing.motion.distance / swing.motion.duration), swing.motion.duration)
	end
end

local function startLight(state: Combatant): boolean
	local weapon = state.weapon
	if not weapon then
		return false
	end

	-- The chain resets if you stopped swinging for long enough.
	if now() - state.lastSwingAt > GameConfig.Combat.ComboResetWindow then
		state.comboIndex = 1
	end

	local swing = weapon.lightCombo[state.comboIndex]
	if not swing then
		state.comboIndex = 1
		swing = weapon.lightCombo[1]
	end
	if not swing then
		return false
	end

	beginSwing(state, Action.Light, swing)
	state.comboIndex = if state.comboIndex >= #weapon.lightCombo then 1 else state.comboIndex + 1
	return true
end

local function startHeavy(state: Combatant): boolean
	local weapon = state.weapon
	if not weapon or not weapon.heavy then
		return false
	end
	local cost = 18 * weapon.stats.staminaCostMultiplier * (weapon.heavyStaminaScale or 1)
	if not spendStamina(state, cost) then
		return false
	end
	beginSwing(state, Action.Heavy, weapon.heavy)
	state.comboIndex = 1
	return true
end

local function startAbility(state: Combatant): boolean
	local weapon = state.weapon
	if not weapon or not weapon.ability then
		return false
	end
	if onCooldown(state, "ability") then
		return false
	end
	if not spendStamina(state, weapon.ability.staminaCost or 0) then
		return false
	end

	state.cooldowns.ability = now() + weapon.ability.cooldown
	beginSwing(state, Action.Ability, weapon.ability.swing, weapon.ability)

	if registry.BoonService then
		registry.BoonService.OnAbility(state)
	end
	return true
end

local function startUltimate(state: Combatant): boolean
	local weapon = state.weapon
	if not weapon or not weapon.ultimate then
		return false
	end

	local costScale = 1 - ((state.modifiers.ultimateCostReduction or 0))
	local cost = (weapon.ultimate.cost or GameConfig.Combat.UltimateMax) * costScale
	if state.ultimate < cost then
		return false
	end
	state.ultimate -= cost

	beginSwing(state, Action.Ultimate, weapon.ultimate.swing, weapon.ultimate)
	state.comboIndex = 1
	return true
end

local function startDodge(state: Combatant): boolean
	if onCooldown(state, "dodge") then
		return false
	end

	local modifiers = state.modifiers
	local cost = GameConfig.Combat.DodgeCost * (1 - (modifiers.dodgeCostReduction or 0))
	if not spendStamina(state, cost) then
		return false
	end

	local at = now()
	local distanceScale = 1 + (modifiers.dodgeDistanceBonus or 0)
	local iframeScale = 1 + (modifiers.dodgeIframeBonus or 0)

	state.action = Action.Dodge
	state.phase = Phase.Active
	state.currentSwing = nil
	state.actionStartedAt = at
	state.actionEndsAt = at + GameConfig.Combat.DodgeDuration
	state.phaseEndsAt = state.actionEndsAt
	state.cooldowns.dodge = at + GameConfig.Combat.DodgeCooldown

	-- Invulnerability starts slightly after the dodge does, so a dodge pressed
	-- after an attack has already connected does not retroactively save you.
	state.invulnerableUntil = math.max(
		state.invulnerableUntil,
		at + GameConfig.Combat.DodgeIFrameStart + GameConfig.Combat.DodgeIFrameDuration * iframeScale
	)

	local direction = if state.moveDirection.Magnitude > 0.1
		then flatUnit(state.moveDirection)
		else -state.facing
	local distance = GameConfig.Combat.DodgeDistance * distanceScale
	CombatService.ApplyImpulse(state, direction * (distance / GameConfig.Combat.DodgeDuration), GameConfig.Combat.DodgeDuration)

	broadcastClip(state, "Dodge", 1)

	if registry.BoonService then
		registry.BoonService.OnDodge(state, direction)
	end
	return true
end

local function startParry(state: Combatant): boolean
	if onCooldown(state, "parry") then
		return false
	end

	local at = now()
	state.action = Action.Parry
	state.phase = Phase.Active
	state.currentSwing = nil
	state.actionStartedAt = at
	state.parryStartedAt = at
	state.parryActiveUntil = at + GameConfig.Combat.ParryBlockDuration
	state.actionEndsAt = state.parryActiveUntil
	state.phaseEndsAt = state.actionEndsAt
	state.cooldowns.parry = at + GameConfig.Combat.ParryCooldown

	broadcastClip(state, "Parry", 1)
	return true
end

--------------------------------------------------------------------------------
-- Intent
--------------------------------------------------------------------------------

local STARTERS: { [string]: (Combatant) -> boolean } = {
	Light = startLight,
	Heavy = startHeavy,
	Ability = startAbility,
	Ultimate = startUltimate,
	Dodge = startDodge,
	Parry = startParry,
}

--- Runs an intent immediately if legal, buffers it if it is nearly legal,
--- drops it otherwise.
function CombatService.TryIntent(state: Combatant, intent: string, facing: Vector3?, moveDirection: Vector3?): boolean
	if facing then
		state.facing = Hitbox.ValidateFacing(flatUnit(state.root.CFrame.LookVector), flatUnit(facing))
	end
	if moveDirection then
		state.moveDirection = moveDirection
	end

	local starter = STARTERS[intent]
	if not starter then
		return false
	end

	local allowed, bufferable = canStart(state, intent)
	if allowed then
		state.bufferedIntent = nil
		return starter(state)
	end

	if bufferable then
		state.bufferedIntent = intent
		state.bufferedAt = now()
		state.bufferedFacing = state.facing
	end
	return false
end

local function consumeBuffer(state: Combatant)
	local intent = state.bufferedIntent
	if not intent then
		return
	end
	if now() - state.bufferedAt > GameConfig.Combat.InputBufferWindow then
		state.bufferedIntent = nil
		return
	end

	local allowed = canStart(state, intent)
	if allowed then
		state.bufferedIntent = nil
		local starter = STARTERS[intent]
		if starter then
			starter(state)
		end
	end
end

--------------------------------------------------------------------------------
-- Movement impulses
--------------------------------------------------------------------------------

local activeImpulses: { { state: Combatant, velocity: Vector3, until_: number, instance: LinearVelocity, attachment: Attachment } } = {}

--[[
	Root motion. A LinearVelocity constraint for a fixed window beats setting
	CFrame directly: it collides with walls, it does not fight the client's own
	physics simulation of its character, and it cannot teleport anyone through
	geometry.
]]
function CombatService.ApplyImpulse(state: Combatant, velocity: Vector3, duration: number)
	local attachment = Instance.new("Attachment")
	attachment.Parent = state.root

	local mover = Instance.new("LinearVelocity")
	mover.Attachment0 = attachment
	mover.MaxForce = 1e6
	mover.RelativeTo = Enum.ActuatorRelativeTo.World
	mover.VectorVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	mover.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	mover.Parent = state.root

	table.insert(activeImpulses, {
		state = state,
		velocity = velocity,
		until_ = now() + duration,
		instance = mover,
		attachment = attachment,
	})
end

local function updateImpulses()
	local currentTime = now()
	for index = #activeImpulses, 1, -1 do
		local impulse = activeImpulses[index]
		if currentTime >= impulse.until_ or not impulse.state.alive or not impulse.instance.Parent then
			impulse.instance:Destroy()
			impulse.attachment:Destroy()
			table.remove(activeImpulses, index)
		end
	end
end

--------------------------------------------------------------------------------
-- Damage
--------------------------------------------------------------------------------

local function sendFeedback(target: Combatant, kind: string, amount: number, result: any, position: Vector3, extra: any?)
	local payload = {
		kind = kind,
		position = position,
		amount = amount,
		crit = result and result.critical or false,
		element = result and result.element or "Physical",
		targetId = target.character:GetAttribute("NetId"),
		hitStop = extra and extra.hitStop or 0,
		shake = extra and extra.shake or 0,
	}
	Net.FireAllClients("CombatFeedback", payload)
end

--[[
	Applies damage from `attacker` to `target`. This is the only function in the
	game that reduces a Humanoid's health, which means every defensive check --
	invulnerability, parry, block, faction -- has exactly one place to live.
]]
function CombatService.ApplyDamage(attackerState: Combatant?, target: Combatant, context: any): any?
	if not target.alive or target.humanoid.Health <= 0 then
		return nil
	end

	local currentTime = now()

	-- i-frames.
	if currentTime < target.invulnerableUntil then
		sendFeedback(target, CombatEnums.HitResult.Dodged, 0, nil, target.root.Position)
		return nil
	end

	-- Parry. A perfect parry is the first fraction of the window; after that it
	-- degrades to a block. Both are handled here so an attack cannot bypass a
	-- parry by taking a different code path into damage.
	if target.action == Action.Parry and currentTime <= target.parryActiveUntil then
		local sinceParry = currentTime - target.parryStartedAt
		if sinceParry <= GameConfig.Combat.PerfectParryWindow then
			CombatService.ResolvePerfectParry(target, attackerState)
			return nil
		end
		context.blockedFrontally = true
		context.blockReduction = GameConfig.Combat.BlockDamageReduction
	end

	-- Shield-carrying enemies block from the front.
	if target.frontalBlockAngle and attackerState then
		local toAttacker = flatUnit(attackerState.root.Position - target.root.Position)
		local dot = flatUnit(target.root.CFrame.LookVector):Dot(toAttacker)
		local angle = math.deg(math.acos(math.clamp(dot, -1, 1)))
		if angle <= target.frontalBlockAngle * 0.5 then
			context.blockedFrontally = true
			context.blockReduction = context.blockReduction or 0.8
		end
	end

	-- Ability-granted damage reduction (Vigil's HOLD THE LINE).
	if currentTime < target.damageReductionUntil and target.damageReduction > 0 then
		context.multipliers = context.multipliers or {}
		table.insert(context.multipliers, 1 - target.damageReduction)
	end

	local targetStatus = statusModifiers(target.character)
	context.targetDamageTakenMultiplier = (context.targetDamageTakenMultiplier or 1) * targetStatus.damageTaken

	if attackerState then
		local attackerStatus = statusModifiers(attackerState.character)
		context.multipliers = context.multipliers or {}
		table.insert(context.multipliers, attackerStatus.damageDealt)
	end

	-- Staggered targets take more. This is the payoff for building poise.
	if currentTime < target.staggerUntil then
		context.multipliers = context.multipliers or {}
		table.insert(context.multipliers, GameConfig.Combat.StaggerDamageBonus)
	end

	local result = DamageMath.Resolve(context, context.rng)

	target.humanoid.Health -= result.amount

	sendFeedback(target, result.result, result.amount, result, target.root.Position + Vector3.new(0, 2, 0), {
		hitStop = context.hitStop,
		shake = context.shake,
	})

	-- Meter. Dealing damage charges slower than taking it; getting hit should
	-- never feel like it gave you nothing.
	if attackerState then
		local chargeScale = 1 + (attackerState.modifiers.ultimateChargeBonus or 0)
		attackerState.ultimate = math.min(
			GameConfig.Combat.UltimateMax,
			attackerState.ultimate
				+ result.amount * GameConfig.Combat.UltimateGainPerDamageDealt * chargeScale
		)
	end
	target.ultimate = math.min(
		GameConfig.Combat.UltimateMax,
		target.ultimate + result.amount * GameConfig.Combat.UltimateGainPerDamageTaken
	)

	CombatService.Damaged:Fire(target, attackerState, result)

	if registry.BoonService then
		if attackerState and isPlayerTeam(attackerState) then
			registry.BoonService.OnHit(attackerState, target, result, context)
		end
		if isPlayerTeam(target) then
			registry.BoonService.OnDamaged(target, result.amount, attackerState)
		end
	end

	if target.humanoid.Health <= 0 then
		CombatService.HandleDeath(target, attackerState)
	end

	return result
end

--- Entry point for damage-over-time, which has no swing behind it.
function CombatService.ApplyStatusDamage(character: Model, amount: number, source: Model?, statusId: string)
	local target = combatants[character]
	if not target then
		return
	end
	local attackerState = source and combatants[source] or nil

	CombatService.ApplyDamage(attackerState, target, {
		baseDamage = amount,
		swingMultiplier = 1,
		element = statusId,
		-- DoT never crits and never triggers on-hit effects; otherwise a single
		-- burn would re-enter the Grace pipeline several times a second.
		suppressHooks = true,
	})
end

--------------------------------------------------------------------------------
-- Poise and stagger
--------------------------------------------------------------------------------

function CombatService.ApplyPoise(target: Combatant, amount: number)
	if now() < target.superArmorUntil then
		return
	end

	-- Announced before the unstaggerable check, because a boss still needs to hear
	-- about poise it is immune to being staggered by -- that is its break meter.
	CombatService.PoiseApplied:Fire(target, amount)

	if target.unstaggerable then
		return
	end

	target.poise += amount
	if target.poise >= target.poiseThreshold then
		target.poise = 0
		CombatService.Stagger(target, GameConfig.Combat.StaggerDuration)
	end
end

function CombatService.Stagger(target: Combatant, duration: number)
	target.action = Action.Staggered
	target.phase = Phase.Active
	target.currentSwing = nil
	target.staggerUntil = now() + duration
	target.actionEndsAt = target.staggerUntil
	target.phaseEndsAt = target.staggerUntil
	target.comboIndex = 1
	target.bufferedIntent = nil

	broadcastClip(target, "Stagger", 1)
	CombatService.Staggered:Fire(target)
end

--------------------------------------------------------------------------------
-- Parry
--------------------------------------------------------------------------------

function CombatService.ResolvePerfectParry(defender: Combatant, attackerState: Combatant?)
	defender.invulnerableUntil = math.max(defender.invulnerableUntil, now() + 0.35)
	defender.ultimate = math.min(
		GameConfig.Combat.UltimateMax,
		defender.ultimate + GameConfig.Combat.PerfectParryUltimateGain
	)

	broadcastClip(defender, "ParrySuccess", 1)
	sendFeedback(defender, CombatEnums.HitResult.Parried, 0, nil, defender.root.Position + Vector3.new(0, 3, 0), {
		hitStop = 0.14,
		shake = 0.9,
	})

	if attackerState then
		CombatService.ApplyPoise(attackerState, GameConfig.Combat.PerfectParryStaggerBonus)
	end

	-- Riposte Temper: a perfect parry hands the ability straight back.
	local temper = defender.weapon and defender.weapon.temperFlags
	if temper and temper.parryRefundAbility then
		defender.cooldowns.ability = 0
	end

	CombatService.ParrySucceeded:Fire(defender, attackerState)

	if registry.BoonService then
		registry.BoonService.OnParry(defender, attackerState)
	end
end

--------------------------------------------------------------------------------
-- Death
--------------------------------------------------------------------------------

function CombatService.HandleDeath(target: Combatant, killer: Combatant?)
	if not target.alive then
		return
	end
	target.alive = false
	target.action = Action.Dead
	target.humanoid.Health = 0

	broadcastClip(target, "Death", 1)

	if registry.BoonService and killer and isPlayerTeam(killer) then
		registry.BoonService.OnKill(killer, target)
	end

	CombatService.Killed:Fire(target, killer)
end

--------------------------------------------------------------------------------
-- Hitbox resolution
--------------------------------------------------------------------------------

local function ignoreListFor(state: Combatant): { Instance }
	-- Never hit yourself; never let a hitbox find a weapon model.
	return { state.character }
end

local function resolveSwingHit(state: Combatant, swing: any)
	local origin = attackOrigin(state)
	local targets = Hitbox.Query(origin, swing.hitbox, ignoreListFor(state))
	if #targets == 0 then
		return
	end

	local weapon = state.weapon
	local baseDamage = weapon and weapon.stats.baseDamage or (state.enemyDamage or 10)
	local poiseScale = weapon and weapon.stats.poise or 1

	local hitCount = 0
	for _, target in targets do
		local other = combatants[target.character]
		if other and other.alive and hostileTo(state, other) and not state.hitThisSwing[target.character] then
			-- Range sanity: the query can catch something a hair outside the
			-- attack's stated reach because it works on part bounds.
			if target.distance <= swing.hitbox.range + GameConfig.Combat.HitRangeSlack then
				state.hitThisSwing[target.character] = true
				hitCount += 1

				local context: any = {
					baseDamage = baseDamage,
					swingMultiplier = swing.damage,
					additiveBonuses = {},
					multipliers = {},
					element = "Physical",
					attackType = state.action,
					hitStop = swing.hitStop,
					shake = swing.camera and swing.camera.shake or 0,
					swing = swing,
					hitPart = target.part,
					targetCharacter = target.character,
				}

				-- Graces modify the outgoing hit before it is resolved.
				if registry.BoonService and isPlayerTeam(state) then
					registry.BoonService.ModifyOutgoing(state, other, context)
				end

				-- Boss weak points.
				if other.weakPoints and other.weakPointsActive then
					local multiplier = other.weakPoints[target.part.Name]
					if multiplier then
						table.insert(context.multipliers, multiplier)
					end
				end

				local result = CombatService.ApplyDamage(state, other, context)

				if result then
					local poise = DamageMath.ResolvePoise(swing.poise, poiseScale, context.poiseBonuses)
					CombatService.ApplyPoise(other, poise)

					if swing.knockback and swing.knockback > 0 then
						local direction = flatUnit(other.root.Position - state.root.Position)
						local force = DamageMath.ResolveKnockback(
							swing.knockback,
							other.weight or 1,
							now() < other.staggerUntil
						)
						CombatService.ApplyImpulse(other, direction * force, 0.18)
					end
					if swing.pull and swing.pull > 0 then
						local direction = flatUnit(state.root.Position - other.root.Position)
						CombatService.ApplyImpulse(other, direction * swing.pull, 0.25)
					end
					if swing.launch and swing.launch > 0 then
						other.root.AssemblyLinearVelocity = Vector3.new(
							other.root.AssemblyLinearVelocity.X,
							swing.launch / math.max(0.5, other.weight or 1),
							other.root.AssemblyLinearVelocity.Z
						)
					end
				end
			end
		end
	end

	if hitCount > 0 then
		-- Hit stop scales down when several things are hit at once, or a spin
		-- through six enemies would stop the game dead.
		local stop = (swing.hitStop or 0) / math.sqrt(hitCount)
		state.actionEndsAt += stop
		state.phaseEndsAt += stop
	end
end

--------------------------------------------------------------------------------
-- Tick
--------------------------------------------------------------------------------

local function advancePhase(state: Combatant)
	local currentTime = now()
	if currentTime < state.phaseEndsAt then
		return
	end

	local swing = state.currentSwing
	local speedScale = math.max(0.2, statusModifiers(state.character).attackSpeed)

	if state.phase == Phase.Windup and swing then
		state.phase = Phase.Active
		state.phaseEndsAt = currentTime + swing.active / speedScale
		state.hitThisSwing = {}

		if state.weapon then
			registry.WeaponService.SetTrailEnabled(state.character, true)
		end

		if swing.projectile then
			-- Ranged attacks spawn a projectile instead of opening a hitbox. The
			-- windup still ran, so the telegraph and the shot stay in sync.
			CombatService.FireSwingProjectile(state, swing)
		elseif state.multiHitsLeft > 1 then
			state.nextMultiHitAt = currentTime
		else
			resolveSwingHit(state, swing)
		end
		return
	end

	if state.phase == Phase.Active and swing then
		state.phase = Phase.Recovery
		state.phaseEndsAt = state.actionEndsAt
		if state.weapon then
			registry.WeaponService.SetTrailEnabled(state.character, false)
		end
		return
	end

	-- Action over.
	if currentTime >= state.actionEndsAt then
		if state.action == Action.Staggered then
			state.poise = 0
		end
		state.action = Action.Idle
		state.phase = Phase.Done
		state.currentSwing = nil
		state.multiHitsLeft = 0
		if state.weapon then
			registry.WeaponService.SetTrailEnabled(state.character, false)
		end
	end
end

local function tickMultiHit(state: Combatant)
	if state.multiHitsLeft <= 1 or state.phase ~= Phase.Active then
		return
	end
	local currentTime = now()
	if currentTime < state.nextMultiHitAt then
		return
	end

	local swing = state.currentSwing
	if not swing then
		return
	end

	local weapon = state.weapon
	local source = if state.action == Action.Ultimate then weapon and weapon.ultimate else nil
	local interval = source and source.multiHit and source.multiHit.interval or 0.1

	-- Each tick is a fresh swing as far as "hit once per swing" is concerned,
	-- which is what makes a flurry ultimate hit the same target repeatedly.
	state.hitThisSwing = {}
	resolveSwingHit(state, swing)

	state.multiHitsLeft -= 1
	state.nextMultiHitAt = currentTime + interval
end

local function tickResources(state: Combatant, deltaTime: number)
	local currentTime = now()

	if currentTime >= state.staminaBlockedUntil and state.stamina < GameConfig.Player.BaseMaxStamina then
		state.stamina = math.min(
			GameConfig.Player.BaseMaxStamina,
			state.stamina + GameConfig.Player.StaminaRegenPerSecond * deltaTime
		)
	end

	state.poise = DamageMath.DecayPoise(state.poise, deltaTime)

	-- Movement speed is the base, scaled by statuses, and cut hard while
	-- attacking so a swing is a commitment rather than a thing you stroll through.
	local status = statusModifiers(state.character)
	local speed = state.baseWalkSpeed * status.moveSpeed
	if state.action == Action.Light or state.action == Action.Heavy or state.action == Action.Ability then
		speed *= 0.35
	elseif state.action == Action.Parry then
		speed *= 0.45
	elseif isCommitted(state) then
		speed = 0
	end
	if status.incapacitated then
		speed = 0
	end
	state.humanoid.WalkSpeed = speed
end

local function syncPlayer(state: Combatant)
	local player = state.player
	if not player then
		return
	end
	Net.FireClient("CombatState", player, {
		action = state.action,
		phase = state.phase,
		comboIndex = state.comboIndex,
		actionEndsAt = state.actionEndsAt,
		stamina = state.stamina,
		maxStamina = GameConfig.Player.BaseMaxStamina,
		ultimate = state.ultimate,
		ultimateMax = GameConfig.Combat.UltimateMax,
		abilityReadyAt = state.cooldowns.ability or 0,
		dodgeReadyAt = state.cooldowns.dodge or 0,
		health = state.humanoid.Health,
		maxHealth = state.humanoid.MaxHealth,
		serverTime = now(),
	})
end

local syncAccumulator = 0

function CombatService.Tick(deltaTime: number)
	updateImpulses()

	for character, state in combatants do
		if not character.Parent or state.humanoid.Health <= 0 then
			if state.alive then
				CombatService.HandleDeath(state, nil)
			end
			combatants[character] = nil
			continue
		end

		tickResources(state, deltaTime)
		tickMultiHit(state)
		advancePhase(state)

		if state.action == Action.Idle then
			consumeBuffer(state)
		end
	end

	-- Players get a state packet at 20Hz. Everything the HUD shows changes slowly
	-- enough that this is invisible, and it is a twentieth of the bandwidth of
	-- syncing every frame.
	syncAccumulator += deltaTime
	if syncAccumulator >= 0.05 then
		syncAccumulator = 0
		for _, state in combatants do
			if state.player then
				syncPlayer(state)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Enemy entry points
--------------------------------------------------------------------------------

--- Runs an enemy or boss attack through the same machine players use.
function CombatService.StartEnemyAttack(state: Combatant, attack: any, damageScale: number)
	local swing = {
		clip = attack.clip,
		windup = attack.windup,
		active = attack.active,
		recovery = attack.recovery,
		damage = 1,
		poise = attack.poiseDamage or 20,
		knockback = attack.knockback or 0,
		hitbox = attack.hitbox,
		motion = attack.motion,
		hitStop = 0.04,
		camera = { shake = 0.4 },
		superArmorFrom = attack.superArmorFrom,
		tags = { "IsEnemy" },
		applies = attack.applies,
		projectile = attack.projectile,
	}

	-- Assigned unconditionally so an attack with no status clears the previous
	-- one, rather than an enemy inheriting a status from an attack it is no
	-- longer performing.
	state.pendingStatus = attack.applies
	state.enemyDamage = attack.damage * damageScale
	beginSwing(state, Action.Heavy, swing)
	state.currentAttackId = attack.id
	return true
end

--[[
	Launches a swing's projectile(s). Volley-style attacks fan `count` shots across
	`spreadDegrees`; a single shot is just the degenerate case of that, so there is
	one code path.
]]
function CombatService.FireSwingProjectile(state: Combatant, swing: any)
	local spec = swing.projectile
	if not spec or not registry.EnemyService then
		return
	end

	local origin = state.root.Position + Vector3.new(0, 2, 0)
	local aim = state.facing

	-- Lead the target so a moving player actually has to keep moving.
	if spec.leadsTarget then
		local best, bestDistance = nil, math.huge
		for _, other in combatants do
			if other.alive and other.team ~= state.team then
				local distance = (other.root.Position - origin).Magnitude
				if distance < bestDistance then
					best, bestDistance = other, distance
				end
			end
		end
		if best then
			local travel = bestDistance / math.max(1, spec.speed)
			local predicted = best.root.Position + best.root.AssemblyLinearVelocity * travel
			aim = flatUnit(predicted - origin)
		end
	end

	local count = spec.count or 1
	local spread = spec.spreadDegrees or 0

	for index = 1, count do
		local direction = aim
		if count > 1 and spread > 0 then
			local offset = (index - (count + 1) / 2) * (spread / math.max(1, count - 1))
			direction = (CFrame.Angles(0, math.rad(offset), 0) * aim)
		end

		registry.EnemyService.FireProjectile({
			origin = origin,
			direction = direction,
			speed = spec.speed,
			radius = spec.radius,
			maxRange = spec.maxRange,
			damage = state.enemyDamage or 10,
			source = state.character,
			team = state.team,
			applies = swing.applies,
		})
	end
end

function CombatService.IsBusy(state: Combatant): boolean
	return state.action ~= Action.Idle
end

function CombatService.SetFacing(state: Combatant, facing: Vector3)
	state.facing = flatUnit(facing)
end

function CombatService.Heal(state: Combatant, amount: number)
	if not state.alive then
		return
	end
	local before = state.humanoid.Health
	state.humanoid.Health = math.min(state.humanoid.MaxHealth, before + amount)
	local healed = state.humanoid.Health - before
	if healed > 0.5 then
		sendFeedback(state, "Heal", math.floor(healed), nil, state.root.Position + Vector3.new(0, 3, 0))
	end
end

function CombatService.GrantInvulnerability(state: Combatant, duration: number)
	state.invulnerableUntil = math.max(state.invulnerableUntil, now() + duration)
end

function CombatService.AllCombatants(): { [Model]: Combatant }
	return combatants
end

--------------------------------------------------------------------------------

function CombatService.Init(services: any)
	registry = services
end

function CombatService.Start()
	Net.OnServerEvent("CombatIntent", function(player, payload)
		if type(payload) ~= "table" or type(payload.action) ~= "string" then
			return
		end
		local state = CombatService.GetByPlayer(player)
		if not state then
			return
		end

		local facing = if typeof(payload.facing) == "Vector3" then payload.facing else nil
		local move = if typeof(payload.moveDirection) == "Vector3" then payload.moveDirection else nil
		CombatService.TryIntent(state, payload.action, facing, move)
	end)
end

return CombatService
