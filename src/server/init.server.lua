--!strict
--[[
	HOLLOW VERGE — server bootstrap.

	Services are plain tables with an optional Init and Start. Init wires
	references; Start begins doing work. Both phases run in a fixed order, and
	every service reaches its peers through the registry passed to Init rather
	than by requiring them directly. That is the whole dependency-injection story,
	and it exists for one reason: CombatService and EnemyService genuinely need
	each other, and a require cycle between them would be a boot-time crash.

	Boot order matters. Data comes up before anything that reads a profile, the
	world exists before anything spawns into it, and combat is running before a
	player can join.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local PhysicsService = game:GetService("PhysicsService")

local Shared = ReplicatedStorage:WaitForChild("HollowVerge")
local Net = require(Shared.Net.Net)
local GameConfig = require(Shared.Config.GameConfig)

--------------------------------------------------------------------------------
-- Content validation
--
-- Every config module can check itself. Running all of them at boot turns the
-- entire class of "a designer typo'd a boon id" bugs into a loud message on the
-- server console instead of a nil index forty minutes into a playtest.
--------------------------------------------------------------------------------

local function validateContent()
	local validators = {
		{ name = "WeaponConfig", module = require(Shared.Config.WeaponConfig) },
		{ name = "BoonConfig", module = require(Shared.Config.BoonConfig) },
		{ name = "EnemyConfig", module = require(Shared.Config.EnemyConfig) },
		{ name = "BossConfig", module = require(Shared.Config.BossConfig) },
		{ name = "RoomConfig", module = require(Shared.Config.RoomConfig) },
		{ name = "RegionConfig", module = require(Shared.Config.RegionConfig) },
		{ name = "RelicConfig", module = require(Shared.Config.RelicConfig) },
		{ name = "CosmeticConfig", module = require(Shared.Config.CosmeticConfig) },
		{ name = "MasteryConfig", module = require(Shared.Config.MasteryConfig) },
		{ name = "DialogueConfig", module = require(Shared.Config.DialogueConfig) },
		{ name = "AudioConfig", module = require(Shared.Config.AudioConfig) },
	}

	local total = 0
	for _, entry in validators do
		local ok, problems = pcall(entry.module.Validate)
		if not ok then
			warn(("[HollowVerge] %s.Validate errored: %s"):format(entry.name, tostring(problems)))
			total += 1
		else
			for _, problem in problems do
				warn(("[HollowVerge] %s: %s"):format(entry.name, problem))
				total += 1
			end
		end
	end

	if total == 0 then
		print("[HollowVerge] content validation passed")
	else
		warn(("[HollowVerge] content validation found %d problem(s)"):format(total))
	end
end

--------------------------------------------------------------------------------
-- Collision groups
--
-- Players never collide with enemies. Bodies shoving each other around is the
-- fastest way to make a melee game feel bad -- you get pushed out of your own
-- combo by the thing you are hitting. Positioning is handled by the AI instead.
--------------------------------------------------------------------------------

local function setupCollisionGroups()
	local groups = GameConfig.Collision
	for _, name in { groups.Player, groups.Enemy, groups.Hitbox, groups.Debris } do
		local ok = pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, name)
		if not ok then
			-- Already registered (e.g. a soft restart in Studio). Fine.
		end
	end

	PhysicsService:CollisionGroupSetCollidable(groups.Player, groups.Enemy, false)
	PhysicsService:CollisionGroupSetCollidable(groups.Enemy, groups.Enemy, false)
	PhysicsService:CollisionGroupSetCollidable(groups.Hitbox, groups.Player, false)
	PhysicsService:CollisionGroupSetCollidable(groups.Hitbox, groups.Enemy, false)
	PhysicsService:CollisionGroupSetCollidable(groups.Hitbox, groups.Hitbox, false)
	PhysicsService:CollisionGroupSetCollidable(groups.Debris, groups.Player, false)
	PhysicsService:CollisionGroupSetCollidable(groups.Debris, groups.Enemy, false)
end

--------------------------------------------------------------------------------
-- World containers
--------------------------------------------------------------------------------

local function setupWorld(): { [string]: Folder }
	local containers = {}
	for _, name in { "Hub", "Run", "Enemies", "Effects", "Projectiles", "Interactables" } do
		local existing = workspace:FindFirstChild(name)
		if existing then
			existing:Destroy()
		end
		local folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = workspace
		containers[name] = folder
	end
	return containers
end

--------------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------------

local startedAt = os.clock()

validateContent()
setupCollisionGroups()
Net.Init()

local registry = {
	Shared = Shared,
	World = setupWorld(),
}

--- Order is load order. Later services may reference earlier ones during Init.
local SERVICE_ORDER = {
	"DataService",
	"ProgressionService",
	"StatusService",
	"WeaponService",
	"CombatService",
	"EnemyService",
	"BossService",
	"RoomBuilder",
	"RunGenerator",
	"BoonService",
	"RewardService",
	"RunManager",
	"HubService",
	"PlayerService",
}

local services = script.Services
for _, name in SERVICE_ORDER do
	local moduleScript = services:FindFirstChild(name)
	if not moduleScript then
		error(("[HollowVerge] missing service module %q"):format(name))
	end
	registry[name] = require(moduleScript)
end

for _, name in SERVICE_ORDER do
	local service = registry[name]
	if service.Init then
		local ok, err = pcall(service.Init, registry)
		if not ok then
			error(("[HollowVerge] %s.Init failed: %s"):format(name, tostring(err)))
		end
	end
end

for _, name in SERVICE_ORDER do
	local service = registry[name]
	if service.Start then
		local ok, err = pcall(service.Start)
		if not ok then
			error(("[HollowVerge] %s.Start failed: %s"):format(name, tostring(err)))
		end
	end
end

--[[
	One heartbeat, fanned out. Every per-frame system is driven from here rather
	than connecting its own RenderStepped/Heartbeat, so ordering between them is
	explicit: statuses tick before combat reads them, combat resolves before the
	AI decides what to do about it.
]]
local TICKED = { "StatusService", "CombatService", "EnemyService", "BossService", "RunManager" }

RunService.Heartbeat:Connect(function(deltaTime)
	for _, name in TICKED do
		local service = registry[name]
		if service and service.Tick then
			local ok, err = pcall(service.Tick, deltaTime)
			if not ok then
				warn(("[HollowVerge] %s.Tick error: %s"):format(name, tostring(err)))
			end
		end
	end
end)

game:BindToClose(function()
	-- Give every in-flight profile a chance to write before the server dies.
	if registry.DataService and registry.DataService.FlushAll then
		registry.DataService.FlushAll()
	end
end)

print(("[HollowVerge] %s booted in %.0fms"):format(GameConfig.Version, (os.clock() - startedAt) * 1000))
