--!strict
--[[
	CameraController — a third-person combat camera.

	Everything here exists to keep the fight readable, which for a melee game means
	three things: you can always see what is about to hit you, the camera never
	fights you for control, and impacts have weight.

	SPRINGS, NOT TWEENS
	Position, look-at and FOV are springs. A new impulse can arrive mid-motion --
	three hits in a combo, a heavy landing during a dodge -- and a spring absorbs
	it rather than restarting an animation. It also means the camera has no
	discrete states to get stuck between.

	LOCK-ON
	Soft rather than hard. The camera frames the midpoint between the player and
	the target instead of pointing rigidly at it, so a locked-on fight still lets
	the player look around. Lock is dropped automatically when the target dies or
	leaves range, because a camera aimed at a corpse is the fastest way to get hit.

	OCCLUSION
	One raycast per frame from the player to the desired camera position. If
	something is in the way, the camera comes forward. This is a lot cheaper than
	it sounds and prevents the single worst camera failure: a pillar between you
	and your own character.

	SHAKE IS A SETTING
	Camera shake is applied as a positional and rotational offset scaled by a user
	setting that can be set to zero. The brief asks for this and it is also an
	accessibility baseline.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local GameConfig = require(Shared.Config.GameConfig)
local Spring = require(Shared.Util.Spring)

local CameraController = {}

local registry: any = nil
local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

--- Orbit angles, driven by mouse or thumbstick.
local yaw = 0
local pitch = math.rad(-12)
local distance = GameConfig.Camera.DefaultDistance

local positionSpring = Spring.new(Vector3.zero, 14, 1)
local focusSpring = Spring.new(Vector3.zero, 18, 1)
local fovSpring = Spring.new(GameConfig.Camera.DefaultFov, 10, 0.85)
local shakeSpring = Spring.new(Vector3.zero, 26, 0.35)
local rollSpring = Spring.new(0, 22, 0.4)

local lockTarget: Model? = nil
local shakeScale = 1

--------------------------------------------------------------------------------

local MIN_PITCH = math.rad(-72)
local MAX_PITCH = math.rad(48)
local MOUSE_SENSITIVITY = 0.0035
local GAMEPAD_SENSITIVITY = 2.6

local function characterParts(): (Model?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return character, root
	end
	return character, nil
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- Applies a shake impulse. `magnitude` roughly maps to swing weight: 0.3 for a
--- light hit, 3 for a Warden's slam.
function CameraController.Shake(magnitude: number)
	if not GameConfig.Camera.ShakeEnabled or shakeScale <= 0 then
		return
	end
	local scaled = magnitude * shakeScale
	shakeSpring:Impulse(Vector3.new(
		(math.random() - 0.5) * scaled * 8,
		(math.random() - 0.5) * scaled * 8,
		(math.random() - 0.5) * scaled * 4
	))
	rollSpring:Impulse((math.random() - 0.5) * scaled * 0.09)
end

--- A brief FOV change. Negative values pull in, which reads as a lunge.
function CameraController.FovKick(amount: number)
	fovSpring:Impulse(amount * 8)
end

function CameraController.SetShakeScale(scale: number)
	shakeScale = math.clamp(scale, 0, 2)
end

function CameraController.GetLockTarget(): Model?
	return lockTarget
end

--[[
	Toggles lock-on. Picks the enemy closest to the centre of the screen rather
	than the nearest one, because the player is already pointing at what they want.
]]
function CameraController.ToggleLock()
	if lockTarget then
		lockTarget = nil
		return
	end

	local _, root = characterParts()
	if not root then
		return
	end

	local best, bestScore = nil, -math.huge
	local forward = camera.CFrame.LookVector

	local enemies = workspace:FindFirstChild("Run")
	if not enemies then
		return
	end

	for _, descendant in enemies:GetDescendants() do
		if descendant:IsA("Humanoid") and descendant.Health > 0 then
			local model = descendant.Parent
			if model and model:IsA("Model") and model:GetAttribute("Team") == "Enemy" then
				local targetRoot = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
				if targetRoot and targetRoot:IsA("BasePart") then
					local delta = targetRoot.Position - root.Position
					local range = delta.Magnitude
					if range <= GameConfig.Camera.LockOnMaxRange then
						-- Score is "how centred", penalised by distance.
						local score = forward:Dot(delta.Unit) - range / GameConfig.Camera.LockOnMaxRange * 0.35
						if score > bestScore then
							best, bestScore = model, score
						end
					end
				end
			end
		end
	end

	lockTarget = best
end

--- The direction the player's input means, in camera space. Used for movement
--- and for directional dodges.
function CameraController.CameraRelative(input: Vector3): Vector3
	local flatLook = camera.CFrame.LookVector
	flatLook = Vector3.new(flatLook.X, 0, flatLook.Z)
	if flatLook.Magnitude < 1e-3 then
		return input
	end
	flatLook = flatLook.Unit
	local right = Vector3.new(flatLook.Z, 0, -flatLook.X)
	return (flatLook * -input.Z + right * input.X)
end

function CameraController.Facing(): Vector3
	local look = camera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	return if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
end

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------

local function onInputChanged(input: InputObject, processed: boolean)
	if processed then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseMovement then
		if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
			yaw -= input.Delta.X * MOUSE_SENSITIVITY
			pitch = math.clamp(pitch - input.Delta.Y * MOUSE_SENSITIVITY, MIN_PITCH, MAX_PITCH)
		end
	elseif input.UserInputType == Enum.UserInputType.MouseWheel then
		distance = math.clamp(
			distance - input.Position.Z * 2,
			GameConfig.Camera.MinDistance,
			GameConfig.Camera.MaxDistance
		)
	end
end

local gamepadLook = Vector2.zero

local function onGamepadInput(input: InputObject)
	if input.KeyCode == Enum.KeyCode.Thumbstick2 then
		local position = input.Position
		-- Deadzone: thumbsticks rest slightly off-centre and the camera drifting
		-- on its own is maddening.
		if math.abs(position.X) < 0.15 and math.abs(position.Y) < 0.15 then
			gamepadLook = Vector2.zero
		else
			gamepadLook = Vector2.new(position.X, position.Y)
		end
	end
end

--------------------------------------------------------------------------------

function CameraController.Init(services: any)
	registry = services
end

function CameraController.Start()
	camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable

	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false

	UserInputService.InputChanged:Connect(function(input, processed)
		onInputChanged(input, processed)
		if input.UserInputType == Enum.UserInputType.Gamepad1 then
			onGamepadInput(input)
		end
	end)

	-- The mouse must be freed whenever a menu is open, and recaptured after.
	registry.MenuController.MenuVisibilityChanged:Connect(function(visible: boolean)
		UserInputService.MouseBehavior = if visible
			then Enum.MouseBehavior.Default
			else Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = visible
	end)
end

function CameraController.Update(deltaTime: number)
	local character, root = characterParts()
	if not character or not root then
		return
	end

	if gamepadLook.Magnitude > 0 then
		yaw -= gamepadLook.X * GAMEPAD_SENSITIVITY * deltaTime
		pitch = math.clamp(pitch + gamepadLook.Y * GAMEPAD_SENSITIVITY * deltaTime, MIN_PITCH, MAX_PITCH)
	end

	-- Drop a lock that has become useless.
	if lockTarget then
		local humanoid = lockTarget:FindFirstChildOfClass("Humanoid")
		local targetRoot = lockTarget.PrimaryPart or lockTarget:FindFirstChild("HumanoidRootPart")
		if not lockTarget.Parent or not humanoid or humanoid.Health <= 0 or not targetRoot then
			lockTarget = nil
		elseif targetRoot:IsA("BasePart")
			and (targetRoot.Position - root.Position).Magnitude > GameConfig.Camera.LockOnMaxRange * 1.2
		then
			lockTarget = nil
		end
	end

	local focusPoint = root.Position + Vector3.new(0, GameConfig.Camera.Height, 0)
	local desiredDistance = distance

	if lockTarget then
		local targetRoot = lockTarget.PrimaryPart or lockTarget:FindFirstChild("HumanoidRootPart")
		if targetRoot and targetRoot:IsA("BasePart") then
			-- Frame the midpoint, weighted toward the player, and turn to face the
			-- target without snapping the player's own look direction away.
			local mid = focusPoint:Lerp(targetRoot.Position + Vector3.new(0, 2, 0), 0.38)
			focusPoint = mid

			local toTarget = targetRoot.Position - root.Position
			local flat = Vector3.new(toTarget.X, 0, toTarget.Z)
			if flat.Magnitude > 1 then
				local desiredYaw = math.atan2(-flat.X, -flat.Z)
				-- Shortest-path blend, so crossing the ±pi boundary does not spin.
				local delta = (desiredYaw - yaw + math.pi) % (math.pi * 2) - math.pi
				yaw += delta * math.clamp(deltaTime * 6, 0, 1)
			end

			desiredDistance = math.clamp(
				GameConfig.Camera.LockOnDistance + toTarget.Magnitude * 0.12,
				GameConfig.Camera.MinDistance,
				GameConfig.Camera.MaxDistance
			)
		end
	end

	local orbit = CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)
	local shoulder = orbit.RightVector * GameConfig.Camera.ShoulderOffset
	local desiredPosition = focusPoint + shoulder - orbit.LookVector * desiredDistance

	-- Occlusion: pull in if something is between the player and the camera.
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character, workspace:FindFirstChild("Effects") :: Instance }
	local direction = desiredPosition - focusPoint
	local hit = workspace:Raycast(focusPoint, direction, rayParams)
	if hit then
		desiredPosition = focusPoint + direction.Unit * math.max(3, (hit.Position - focusPoint).Magnitude - 1.2)
	end

	positionSpring.Target = desiredPosition
	focusSpring.Target = focusPoint

	local position = positionSpring:Update(deltaTime)
	local focus = focusSpring:Update(deltaTime)
	local shake = shakeSpring:Update(deltaTime)
	local roll = rollSpring:Update(deltaTime)
	local fov = fovSpring:Update(deltaTime)

	fovSpring.Target = GameConfig.Camera.DefaultFov

	camera.CFrame = CFrame.lookAt(position + shake, focus) * CFrame.Angles(0, 0, roll)
	camera.FieldOfView = math.clamp(fov, 40, 110)
end

return CameraController
