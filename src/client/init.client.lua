--!strict
--[[
	HOLLOW VERGE — client bootstrap.

	Mirrors the server's structure: controllers are tables with optional Init,
	Start and Update, wired through one registry and driven from one render loop.

	WHAT THE CLIENT IS FOR
	Feel. It owns the camera, the animation, the hit sparks, the sounds and the
	UI. It owns none of the truth: it sends intent and renders what the server says
	came of it. Every number it displays arrived from the server; it never computes
	damage, currency or unlocks.

	One consequence worth stating: the client animates an attack the instant the
	player presses the button, before the server has confirmed anything. If the
	server rejects the input, the animation is cut short. That trade -- occasionally
	showing a swing that gets cancelled -- buys the game its responsiveness, and
	the alternative (waiting a round trip before the character moves) is not worth
	considering for a melee game.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("HollowVerge")
local GameConfig = require(Shared.Config.GameConfig)

local player = Players.LocalPlayer
player:WaitForChild("PlayerGui")

local registry = {
	Shared = Shared,
	Player = player,
	-- Populated by HudController; shared so any controller can add a screen.
	ScreenGui = nil :: ScreenGui?,
}

--- Load order. Later controllers may reference earlier ones during Init.
local CONTROLLER_ORDER = {
	"UiKit",
	"AudioController",
	"ProceduralAnimator",
	"AnimationController",
	"VfxController",
	"CameraController",
	"HudController",
	"MenuController",
	"CombatController",
	"InputController",
}

local controllers = script.Controllers
for _, name in CONTROLLER_ORDER do
	local moduleScript = controllers:FindFirstChild(name)
	if not moduleScript then
		error(("[HollowVerge] missing controller %q"):format(name))
	end
	registry[name] = require(moduleScript)
end

for _, name in CONTROLLER_ORDER do
	local controller = registry[name]
	if controller.Init then
		local ok, err = pcall(controller.Init, registry)
		if not ok then
			warn(("[HollowVerge] %s.Init failed: %s"):format(name, tostring(err)))
		end
	end
end

for _, name in CONTROLLER_ORDER do
	local controller = registry[name]
	if controller.Start then
		local ok, err = pcall(controller.Start)
		if not ok then
			warn(("[HollowVerge] %s.Start failed: %s"):format(name, tostring(err)))
		end
	end
end

--[[
	Two loops, deliberately.

	RenderStepped drives anything that must be in lockstep with the frame the
	player sees: the camera and the animation poses. Running those on Heartbeat
	produces a visible half-frame lag between the camera and the character.

	Heartbeat drives everything else. VFX and HUD updating a frame late is free.
]]
local RENDER_STEPPED = { "CameraController", "ProceduralAnimator" }
local HEARTBEAT = { "AnimationController", "VfxController", "HudController", "CombatController", "InputController" }

RunService.RenderStepped:Connect(function(deltaTime)
	for _, name in RENDER_STEPPED do
		local controller = registry[name]
		if controller and controller.Update then
			local ok, err = pcall(controller.Update, deltaTime)
			if not ok and GameConfig.Debug.Enabled then
				warn(("[HollowVerge] %s.Update error: %s"):format(name, tostring(err)))
			end
		end
	end
end)

RunService.Heartbeat:Connect(function(deltaTime)
	for _, name in HEARTBEAT do
		local controller = registry[name]
		if controller and controller.Update then
			local ok, err = pcall(controller.Update, deltaTime)
			if not ok and GameConfig.Debug.Enabled then
				warn(("[HollowVerge] %s.Update error: %s"):format(name, tostring(err)))
			end
		end
	end
end)
