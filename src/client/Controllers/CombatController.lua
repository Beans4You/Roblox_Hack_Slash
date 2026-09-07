--!strict
--[[
	CombatController — the client half of combat.

	Sends intent, predicts the animation, and renders whatever the server says
	actually happened.

	PREDICTION, AND ITS LIMIT
	When the player presses light attack, this plays the swing clip immediately.
	It does not compute damage, does not spawn a hitbox, and does not decide
	whether the attack was legal. If the server disagrees -- the input arrived
	during a lockout, the stamina was not there -- the next CombatState packet
	overwrites the local guess and the animation is cut. Occasionally showing half
	a swing that gets cancelled is a much better trade than making the player wait
	a round trip to see their own character move.

	The predicted state is also what the HUD reads between server packets, so the
	stamina bar moves the instant you dodge rather than 50ms later.

	INPUT BUFFERING
	Buffered here as well as on the server, for a different reason: the client
	buffer decides whether to *play* the next animation early, which is what makes
	a combo feel like it flows. The server buffer decides whether the input counts.

	FINISHERS
	The controller keeps a live "is there an execute available" answer by scanning
	nearby enemies for low health. Done locally because it drives a HUD prompt that
	has to appear instantly; the server re-checks before actually granting one.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local GameConfig = require(Shared.Config.GameConfig)
local WeaponConfig = require(Shared.Config.WeaponConfig)
local CombatEnums = require(Shared.Combat.CombatEnums)
local Net = require(Shared.Net.Net)
local Signal = require(Shared.Util.Signal)

local CombatController = {}

CombatController.StateChanged = Signal.new()

local registry: any = nil
local player = Players.LocalPlayer

--- Authoritative state, replaced wholesale by each CombatState packet.
local serverState = {
	action = CombatEnums.Action.Idle,
	phase = CombatEnums.Phase.Done,
	comboIndex = 1,
	actionEndsAt = 0,
	stamina = GameConfig.Player.BaseMaxStamina,
	maxStamina = GameConfig.Player.BaseMaxStamina,
	ultimate = 0,
	ultimateMax = GameConfig.Combat.UltimateMax,
	abilityReadyAt = 0,
	dodgeReadyAt = 0,
	health = GameConfig.Player.BaseMaxHealth,
	maxHealth = GameConfig.Player.BaseMaxHealth,
	serverTime = 0,
}

--- Local guess, used for animation and the HUD between packets.
local predicted = {
	busyUntil = 0,
	comboIndex = 1,
	lastSwingAt = 0,
	stamina = GameConfig.Player.BaseMaxStamina,
}

local bufferedIntent: string? = nil
local bufferedAt = 0

local weaponId = "Vigil"
local finisherTarget: Model? = nil
local nearbyEnemy = false
local scanAccumulator = 0

--------------------------------------------------------------------------------
-- Prediction
--------------------------------------------------------------------------------

local function weaponDefinition()
	return WeaponConfig.GetOrDefault(weaponId)
end

--- The clip a predicted action would play, and how long it lasts.
local function predictClip(intent: string): (string?, number)
	local weapon = weaponDefinition()

	if intent == "Light" then
		if os.clock() - predicted.lastSwingAt > GameConfig.Combat.ComboResetWindow then
			predicted.comboIndex = 1
		end
		local swing = weapon.lightCombo[predicted.comboIndex] or weapon.lightCombo[1]
		if not swing then
			return nil, 0
		end
		predicted.comboIndex = if predicted.comboIndex >= #weapon.lightCombo then 1 else predicted.comboIndex + 1
		return swing.clip, WeaponConfig.SwingDuration(swing)
	elseif intent == "Heavy" then
		return weapon.heavy.clip, WeaponConfig.SwingDuration(weapon.heavy)
	elseif intent == "Ability" and weapon.ability then
		return weapon.ability.swing.clip, WeaponConfig.SwingDuration(weapon.ability.swing)
	elseif intent == "Ultimate" and weapon.ultimate then
		return weapon.ultimate.swing.clip, WeaponConfig.SwingDuration(weapon.ultimate.swing)
	elseif intent == "Dodge" then
		return "Dodge", GameConfig.Combat.DodgeDuration
	elseif intent == "Parry" then
		return "Parry", GameConfig.Combat.ParryBlockDuration
	elseif intent == "Finisher" then
		return weapon.finisher and weapon.finisher.clip or nil, weapon.finisher and weapon.finisher.duration or 0.8
	end

	return nil, 0
end

--- Camera feedback for a predicted swing, so the kick lands on the same frame as
--- the animation rather than when the server's hit lands.
local function predictCamera(intent: string)
	local weapon = weaponDefinition()
	local swing = nil

	if intent == "Heavy" then
		swing = weapon.heavy
	elseif intent == "Ability" and weapon.ability then
		swing = weapon.ability.swing
	elseif intent == "Ultimate" and weapon.ultimate then
		swing = weapon.ultimate.swing
	end

	if swing and swing.camera and swing.camera.fovKick then
		registry.CameraController.FovKick(swing.camera.fovKick)
	end
	if intent == "Dodge" then
		registry.CameraController.FovKick(1.5)
	end
end

--------------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------------

local function fire(intent: string)
	local character = player.Character
	if not character then
		return
	end

	Net.FireServer("CombatIntent", {
		action = intent,
		facing = registry.CameraController.Facing(),
		moveDirection = registry.InputController.MoveDirection(),
	})

	local clip, duration = predictClip(intent)
	if clip then
		registry.ProceduralAnimator.PlayAction(character, clip, 1)
		predicted.busyUntil = os.clock() + duration
		predicted.lastSwingAt = os.clock()
	end

	predictCamera(intent)
	registry.AudioController.PlayLocal(
		if intent == "Dodge" then "Dodge" elseif intent == "Parry" then "ParryPerfect" else "SwingLight"
	)
end

--[[
	Accepts an intent from InputController. Fires immediately when the local
	prediction says we are free, buffers otherwise.

	The buffer is one slot and expires after InputBufferWindow, matching the
	server. Queueing more than one input turns a dropped frame into a delayed
	attack the player has stopped wanting.
]]
function CombatController.SendIntent(intent: string)
	local clock = os.clock()

	-- Dodge and Ultimate are allowed to interrupt a predicted action, because the
	-- server allows it too; predicting otherwise would make them feel unresponsive.
	local interrupting = intent == "Dodge" or intent == "Ultimate"

	if clock >= predicted.busyUntil or interrupting then
		bufferedIntent = nil
		fire(intent)
		return
	end

	bufferedIntent = intent
	bufferedAt = clock
end

function CombatController.HasFinisherTarget(): boolean
	return finisherTarget ~= nil
end

function CombatController.HasNearbyEnemy(): boolean
	return nearbyEnemy
end

function CombatController.State()
	return serverState
end

function CombatController.PredictedStamina(): number
	return math.min(serverState.stamina, predicted.stamina)
end

function CombatController.WeaponId(): string
	return weaponId
end

--------------------------------------------------------------------------------
-- Scanning
--------------------------------------------------------------------------------

--[[
	Looks for an execute target and for whether a fight is happening at all.

	Run four times a second rather than per frame: the finisher prompt appearing
	60ms late is imperceptible, and the scan walks every enemy in the room.
]]
local function scan()
	finisherTarget = nil
	nearbyEnemy = false

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end

	local runFolder = workspace:FindFirstChild("Run")
	if not runFolder then
		return
	end

	local bestDistance = math.huge
	for _, descendant in runFolder:GetDescendants() do
		if descendant:IsA("Humanoid") and descendant.Health > 0 then
			local model = descendant.Parent
			if model and model:IsA("Model") and model:GetAttribute("Team") == "Enemy" then
				local targetRoot = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
				if targetRoot and targetRoot:IsA("BasePart") then
					local distance = (targetRoot.Position - root.Position).Magnitude
					if distance < 45 then
						nearbyEnemy = true
					end
					-- Bosses are never executable; a finisher is not a phase skip.
					if
						not model:GetAttribute("IsBoss")
						and distance <= GameConfig.Combat.FinisherRange
						and descendant.Health / descendant.MaxHealth <= GameConfig.Combat.FinisherHealthThreshold
						and distance < bestDistance
					then
						finisherTarget = model
						bestDistance = distance
					end
				end
			end
		end
	end
end

--------------------------------------------------------------------------------

function CombatController.Init(services: any)
	registry = services
end

function CombatController.Start()
	Net.OnClientEvent("CombatState", function(payload)
		if type(payload) ~= "table" then
			return
		end
		for key, value in payload do
			serverState[key] = value
		end
		predicted.stamina = payload.stamina or predicted.stamina

		-- The server is the authority on when we are free; correct the prediction
		-- toward it rather than trusting the local guess indefinitely.
		if payload.action == CombatEnums.Action.Idle then
			predicted.busyUntil = math.min(predicted.busyUntil, os.clock())
		end
		if payload.comboIndex then
			predicted.comboIndex = payload.comboIndex
		end

		CombatController.StateChanged:Fire(serverState)
	end)

	Net.OnClientEvent("RunSync", function(payload)
		if type(payload) == "table" and payload.weaponId then
			weaponId = payload.weaponId
		end
	end)

	-- The weapon in hand is replicated as an attribute by WeaponService.
	local function watchCharacter(character: Model)
		weaponId = character:GetAttribute("WeaponId") or weaponId
		character:GetAttributeChangedSignal("WeaponId"):Connect(function()
			weaponId = character:GetAttribute("WeaponId") or weaponId
			predicted.comboIndex = 1
		end)
	end

	if player.Character then
		watchCharacter(player.Character)
	end
	player.CharacterAdded:Connect(watchCharacter)
end

function CombatController.Update(deltaTime: number)
	scanAccumulator += deltaTime
	if scanAccumulator >= 0.25 then
		scanAccumulator = 0
		scan()
	end

	-- Stamina is predicted forward between packets so the bar is never stale.
	if predicted.stamina < serverState.maxStamina then
		predicted.stamina = math.min(
			serverState.maxStamina,
			predicted.stamina + GameConfig.Player.StaminaRegenPerSecond * deltaTime
		)
	end

	local buffered = bufferedIntent
	if buffered then
		if os.clock() - bufferedAt > GameConfig.Combat.InputBufferWindow then
			bufferedIntent = nil
		elseif os.clock() >= predicted.busyUntil then
			bufferedIntent = nil
			fire(buffered)
		end
	end
end

return CombatController
