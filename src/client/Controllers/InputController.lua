--!strict
--[[
	InputController — raw input to intent.

	Deliberately thin: it knows which button means which action and nothing about
	whether that action is currently legal. Legality is the server's answer, and
	CombatController's local prediction of it.

	BINDINGS
	  M1        Light attack
	  M2        Heavy attack (becomes the finisher when one is offered)
	  Q         Dodge
	  F         Parry
	  E         Weapon ability
	  R         Ultimate
	  Space     Jump
	  Tab       Lock on / off
	  Esc       Menu

	THE FINISHER IS CONTEXTUAL
	It has no key of its own. When an enemy is low enough and close enough, the
	heavy attack becomes the finisher and the HUD says so. Adding a separate button
	for a move that is only available for about a second at a time means most
	players never press it.

	MOVEMENT
	Left to Roblox's own character controller. It reads the camera CFrame, which we
	set, so WASD is camera-relative without us reimplementing it. The only thing we
	need from movement is the current input direction, which the server wants for
	directional dodges.
]]

local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local InputController = {}

local registry: any = nil
local player = Players.LocalPlayer

--- Keyboard/mouse bindings. Gamepad is bound alongside each action.
local BINDINGS = {
	{ action = "Light", keys = { Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonX } },
	{ action = "Heavy", keys = { Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonY } },
	{ action = "Dodge", keys = { Enum.KeyCode.Q, Enum.KeyCode.ButtonB } },
	{ action = "Parry", keys = { Enum.KeyCode.F, Enum.KeyCode.ButtonL1 } },
	{ action = "Ability", keys = { Enum.KeyCode.E, Enum.KeyCode.ButtonR1 } },
	{ action = "Ultimate", keys = { Enum.KeyCode.R, Enum.KeyCode.ButtonR2 } },
}

local heldMoveDirection = Vector3.zero

--------------------------------------------------------------------------------

--- The player's current movement input, in world space. Falls back to facing when
--- there is no input, so a neutral dodge goes backwards rather than nowhere.
function InputController.MoveDirection(): Vector3
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.MoveDirection.Magnitude > 0.1 then
		return humanoid.MoveDirection
	end
	return heldMoveDirection
end

local function handleAction(actionName: string, inputState: Enum.UserInputState): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if registry.MenuController.IsBlockingInput() then
		return Enum.ContextActionResult.Pass
	end

	local intent = actionName
	-- The heavy attack becomes the finisher when one is on offer.
	if intent == "Heavy" and registry.CombatController.HasFinisherTarget() then
		intent = "Finisher"
	end

	registry.CombatController.SendIntent(intent)
	return Enum.ContextActionResult.Sink
end

--------------------------------------------------------------------------------

function InputController.Init(services: any)
	registry = services
end

function InputController.Start()
	for _, binding in BINDINGS do
		ContextActionService:BindAction(
			binding.action,
			function(_, inputState)
				return handleAction(binding.action, inputState)
			end,
			false,
			table.unpack(binding.keys)
		)
	end

	ContextActionService:BindAction("LockOn", function(_, inputState)
		if inputState == Enum.UserInputState.Begin and not registry.MenuController.IsBlockingInput() then
			registry.CameraController.ToggleLock()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Tab, Enum.KeyCode.ButtonL3)

	ContextActionService:BindAction("Menu", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			registry.MenuController.ToggleMenu()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Escape, Enum.KeyCode.ButtonStart)

	-- Left thumbstick is mirrored so a gamepad dodge is directional even when the
	-- humanoid has not yet started moving.
	UserInputService.InputChanged:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.Thumbstick1 then
			local position = input.Position
			if math.abs(position.X) > 0.2 or math.abs(position.Y) > 0.2 then
				heldMoveDirection = registry.CameraController.CameraRelative(
					Vector3.new(position.X, 0, -position.Y)
				)
			else
				heldMoveDirection = Vector3.zero
			end
		end
	end)
end

function InputController.Update() end

return InputController
