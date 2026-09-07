--!strict
--[[
	AnimationController — decides which clip every visible character should play.

	ProceduralAnimator does the maths; this decides the intent. It has two jobs:

	LOCOMOTION, locally decided
	Every character in view gets a base clip chosen from its own velocity and
	state: idle, guard, walk, run, fall. This is derived on each client rather than
	replicated, because it changes constantly and is worth exactly nothing if it is
	a frame late.

	ACTIONS, server driven
	Attacks, dodges, parries, staggers and deaths arrive over PlayClip from the
	server, so every client sees the same swing at the same time as the hitbox it
	belongs to. This is the half that must not be guessed.

	NEW CHARACTERS
	Anything with a Humanoid that appears in the world gets bound automatically.
	Rather than tracking spawn events across three services, the controller sweeps
	for unbound rigs a few times a second -- cheap, and it cannot miss one.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local GameConfig = require(Shared.Config.GameConfig)
local Net = require(Shared.Net.Net)

local AnimationController = {}

local registry: any = nil
local player = Players.LocalPlayer

--- NetId -> character, so a PlayClip addressed to an id finds its rig.
local byNetId: { [number]: Model } = {}
local sweepAccumulator = 0

--------------------------------------------------------------------------------

local function bindCharacter(character: Model)
	local animator = registry.ProceduralAnimator
	if animator.Bind(character) then
		local netId = character:GetAttribute("NetId")
		if netId then
			byNetId[netId] = character
		end
	end
end

--- Finds rigs that have appeared since the last sweep.
local function sweep()
	for _, container in { workspace:FindFirstChild("Enemies"), workspace:FindFirstChild("Run"), workspace:FindFirstChild("Hub") } do
		if container then
			for _, descendant in container:GetDescendants() do
				if descendant:IsA("Humanoid") then
					local model = descendant.Parent
					if model and model:IsA("Model") then
						bindCharacter(model)
					end
				end
			end
		end
	end

	for _, other in Players:GetPlayers() do
		if other.Character then
			bindCharacter(other.Character)
		end
	end
end

--------------------------------------------------------------------------------
-- Locomotion
--------------------------------------------------------------------------------

--[[
	Picks the base clip for a character.

	The `Guard` stance is used whenever a combatant has a target nearby, which is
	the cheap version of "the character knows it is in a fight". A character
	standing in a combat pose when nothing is happening looks tense; one standing
	idle mid-fight looks broken, so erring toward Guard is the right bias.
]]
local function chooseBaseClip(character: Model, humanoid: Humanoid, root: BasePart): (string, number)
	local velocity = root.AssemblyLinearVelocity
	local planarSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude

	if humanoid.Health <= 0 then
		return "Death", 1
	end

	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Freefall or state == Enum.HumanoidStateType.Jumping then
		return "Fall", 1
	end

	if planarSpeed > 12 then
		-- Play the run cycle at a rate matched to actual speed, so a slowed
		-- character does not moonwalk.
		return "Run", math.clamp(planarSpeed / 20, 0.6, 1.6)
	elseif planarSpeed > 1.5 then
		return "Walk", math.clamp(planarSpeed / 10, 0.6, 1.5)
	end

	local npcIdle = character:GetAttribute("IdleClip")
	if npcIdle then
		return npcIdle, 1
	end

	if character:GetAttribute("Team") == "Enemy" or character:GetAttribute("IsBoss") then
		return "Guard", 1
	end

	-- The local player holds guard whenever anything hostile is close.
	if character == player.Character then
		local combat = registry.CombatController
		if combat and combat.HasNearbyEnemy() then
			return "Guard", 1
		end
	end

	return "Idle", 1
end

--------------------------------------------------------------------------------

function AnimationController.Init(services: any)
	registry = services
end

function AnimationController.Start()
	Net.OnClientEvent("PlayClip", function(payload)
		if type(payload) ~= "table" then
			return
		end
		local character = byNetId[payload.characterId]
		if not character or not character.Parent then
			-- The rig may not have replicated yet; a sweep will pick it up, and one
			-- missed action clip on a just-spawned enemy is not worth chasing.
			return
		end
		registry.ProceduralAnimator.PlayAction(character, payload.clip, payload.speed)
	end)

	sweep()
end

function AnimationController.Update(deltaTime: number)
	sweepAccumulator += deltaTime
	if sweepAccumulator >= 0.4 then
		sweepAccumulator = 0
		sweep()
	end

	local camera = workspace.CurrentCamera
	local viewPosition = camera and camera.CFrame.Position or Vector3.zero
	local cullSquared = GameConfig.Performance.AnimationCullDistance ^ 2

	for netId, character in byNetId do
		if not character.Parent then
			byNetId[netId] = nil
			continue
		end

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local root = character.PrimaryPart or character:FindFirstChild("HumanoidRootPart")
		if not humanoid or not root or not root:IsA("BasePart") then
			continue
		end
		if (root.Position - viewPosition).Magnitude ^ 2 > cullSquared then
			continue
		end

		local clip, speed = chooseBaseClip(character, humanoid, root)
		registry.ProceduralAnimator.SetBase(character, clip, speed)
	end
end

--- Used by other controllers that need to resolve a server-sent character id.
function AnimationController.CharacterFromNetId(netId: number): Model?
	return byNetId[netId]
end

return AnimationController
