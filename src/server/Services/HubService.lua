--!strict
--[[
	HubService — Emberhold.

	Builds the hub, populates it with NPCs, and handles everything the player can
	do while standing in it. The hub is built once at server start and shared; it
	is the only persistent world in the game.

	THE HUB EVOLVES
	Emberhold starts as a ruin with three people in it. Structures are gated on
	milestones and appear as the player earns them -- the smith's roof, the
	mystic's brazier, the relic hall, the second gate. Nothing here is subtle: the
	brief asks for visible change and the most legible version of that is a
	building that was not there last time.

	Because the hub is shared, structures unlock on the *most advanced* player
	present. In a single-player session that is simply the player. This is the one
	place a shared world and per-player progression genuinely conflict, and showing
	somebody else's unlocked building is a much smaller problem than hiding one the
	player has earned.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local GameConfig = require(Shared.Config.GameConfig)
local Lore = require(Shared.Config.Lore)
local DialogueConfig = require(Shared.Config.DialogueConfig)
local WeaponConfig = require(Shared.Config.WeaponConfig)
local RegionConfig = require(Shared.Config.RegionConfig)
local RigBuilder = require(Shared.Util.RigBuilder)
local PartFactory = require(Shared.Util.PartFactory)
local Maid = require(Shared.Util.Maid)
local Net = require(Shared.Net.Net)

local HubService = {}

local registry: any = nil

local HUB_ORIGIN = CFrame.new(0, 200, 0)
local SPAWN_OFFSET = Vector3.new(0, 6, 14)

local STONE = Color3.fromRGB(96, 90, 84)
local WARM = Color3.fromRGB(255, 168, 88)
local DARK = Color3.fromRGB(58, 52, 48)

local hubModel: Model? = nil
local hubMaid = Maid.new()
local npcModels: { [string]: Model } = {}
local structures: { [string]: Model } = {}

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------

local function buildGround(parent: Instance)
	PartFactory.Part({
		Name = "HubGround",
		Size = Vector3.new(160, 4, 160),
		Color = Color3.fromRGB(72, 68, 64),
		Material = Enum.Material.Cobblestone,
		CFrame = HUB_ORIGIN * CFrame.new(0, -2, 0),
		Parent = parent,
	})

	-- A broken outer wall. Emberhold is a waystation somebody stopped maintaining.
	for index = 1, 14 do
		local angle = (index / 14) * math.pi * 2
		local height = 8 + (index % 4) * 5
		PartFactory.Part({
			Name = "HubWall",
			Size = Vector3.new(14, height, 4),
			Color = STONE,
			Material = Enum.Material.Slate,
			CFrame = HUB_ORIGIN
				* CFrame.new(math.cos(angle) * 74, height * 0.5, math.sin(angle) * 74)
				* CFrame.Angles(0, -angle + math.pi / 2, 0),
			Parent = parent,
		})
	end

	-- The central brazier. Everything in the hub is arranged around it.
	local pillar = PartFactory.Part({
		Name = "Hearth",
		Size = Vector3.new(6, 8, 6),
		Color = DARK,
		Material = Enum.Material.Slate,
		CFrame = HUB_ORIGIN * CFrame.new(0, 4, 0),
		Parent = parent,
	})
	local flame = PartFactory.Decor({
		Name = "HearthFlame",
		Size = Vector3.new(4.5, 5, 4.5),
		Color = WARM,
		Material = Enum.Material.Neon,
		Transparency = 0.15,
		CFrame = HUB_ORIGIN * CFrame.new(0, 10, 0),
		Parent = parent,
	})
	PartFactory.PointLight(flame, WARM, 6, 90)
	pillar:SetAttribute("Hearth", true)
end

--- The gate into a run. Interacting with it opens the expedition menu.
local function buildRunGate(parent: Instance)
	local frame = PartFactory.Part({
		Name = "RunGate",
		Size = Vector3.new(16, 22, 3),
		Color = Color3.fromRGB(40, 46, 54),
		Material = Enum.Material.Slate,
		CFrame = HUB_ORIGIN * CFrame.new(0, 11, -56),
		Parent = parent,
	})

	local veil = PartFactory.Decor({
		Name = "GateVeil",
		Size = Vector3.new(12, 18, 0.6),
		Color = Color3.fromRGB(120, 220, 210),
		Material = Enum.Material.Neon,
		Transparency = 0.45,
		CFrame = HUB_ORIGIN * CFrame.new(0, 11, -55),
		Parent = parent,
	})
	PartFactory.PointLight(veil, Color3.fromRGB(120, 220, 210), 5, 60)

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Descend"
	prompt.ObjectText = "The Verge"
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = 16
	prompt.Parent = frame

	hubMaid:Add(prompt.Triggered:Connect(function(player)
		HubService.OpenExpedition(player)
	end))

	return frame
end

--------------------------------------------------------------------------------
-- Structures that appear as the player progresses.
--------------------------------------------------------------------------------

type StructureSpec = {
	id: string,
	name: string,
	-- Returns true when this structure should exist.
	unlocked: (any) -> boolean,
	build: (Instance) -> Model,
}

local function simpleBuilding(name: string, position: Vector3, size: Vector3, color: Color3, accent: Color3)
	return function(parent: Instance): Model
		local model = Instance.new("Model")
		model.Name = name

		PartFactory.Part({
			Name = "Walls",
			Size = size,
			Color = color,
			Material = Enum.Material.Slate,
			CFrame = HUB_ORIGIN * CFrame.new(position + Vector3.new(0, size.Y * 0.5, 0)),
			Parent = model,
		})
		PartFactory.Part({
			Name = "Roof",
			Size = Vector3.new(size.X * 1.2, 1.5, size.Z * 1.2),
			Color = Color3.fromRGB(52, 44, 40),
			Material = Enum.Material.Wood,
			CFrame = HUB_ORIGIN * CFrame.new(position + Vector3.new(0, size.Y + 0.75, 0)),
			Parent = model,
		})
		local lamp = PartFactory.Decor({
			Name = "Lamp",
			Size = Vector3.new(1.4, 1.4, 1.4),
			Color = accent,
			Material = Enum.Material.Neon,
			CFrame = HUB_ORIGIN * CFrame.new(position + Vector3.new(0, size.Y + 2.6, 0)),
			Parent = model,
		})
		PartFactory.PointLight(lamp, accent, 3, 40)

		model.Parent = parent
		return model
	end
end

local STRUCTURES: { StructureSpec } = {
	{
		id = "Smithy",
		name = "Halvic's Smithy",
		-- Present from the start: the smith is how the player gets a weapon at all.
		unlocked = function()
			return true
		end,
		build = simpleBuilding("Smithy", Vector3.new(-38, 0, -22), Vector3.new(16, 10, 14), STONE, WARM),
	},
	{
		id = "MysticTent",
		name = "Ilka's Reading",
		unlocked = function(profile)
			return profile.stats.runs >= 1
		end,
		build = simpleBuilding("MysticTent", Vector3.new(34, 0, -26), Vector3.new(14, 9, 14), Color3.fromRGB(72, 62, 92), Color3.fromRGB(150, 118, 220)),
	},
	{
		id = "Reliquary",
		name = "Miren's Hall",
		unlocked = function(profile)
			local count = 0
			for _ in profile.relics.owned do
				count += 1
			end
			return count >= 1
		end,
		build = simpleBuilding("Reliquary", Vector3.new(-10, 0, -42), Vector3.new(20, 12, 16), Color3.fromRGB(88, 84, 76), Color3.fromRGB(255, 200, 110)),
	},
	{
		id = "ScoutPost",
		name = "Rannoch's Post",
		unlocked = function(profile)
			return profile.stats.runs >= 2
		end,
		build = simpleBuilding("ScoutPost", Vector3.new(10, 0, 34), Vector3.new(12, 8, 12), Color3.fromRGB(60, 72, 58), Color3.fromRGB(196, 248, 226)),
	},
	{
		id = "SecondGate",
		name = "The Lower Stair",
		unlocked = function(profile)
			local unlocked = 0
			for _ in profile.progress.regionsUnlocked do
				unlocked += 1
			end
			return unlocked >= 2
		end,
		build = function(parent: Instance): Model
			local model = Instance.new("Model")
			model.Name = "SecondGate"
			PartFactory.Part({
				Name = "Stair",
				Size = Vector3.new(20, 3, 26),
				Color = Color3.fromRGB(64, 46, 42),
				Material = Enum.Material.Slate,
				CFrame = HUB_ORIGIN * CFrame.new(30, 0.5, -50) * CFrame.Angles(math.rad(-12), 0, 0),
				Parent = model,
			})
			local glow = PartFactory.Decor({
				Name = "StairGlow",
				Size = Vector3.new(18, 0.4, 24),
				Color = Color3.fromRGB(255, 122, 48),
				Material = Enum.Material.Neon,
				Transparency = 0.4,
				CFrame = HUB_ORIGIN * CFrame.new(30, 1.6, -50) * CFrame.Angles(math.rad(-12), 0, 0),
				Parent = model,
			})
			PartFactory.PointLight(glow, Color3.fromRGB(255, 122, 48), 4, 50)
			model.Parent = parent
			return model
		end,
	},
	{
		id = "TrophyRow",
		name = "The Trophy Row",
		unlocked = function(profile)
			return profile.stats.bossesKilled >= 1
		end,
		build = function(parent: Instance): Model
			local model = Instance.new("Model")
			model.Name = "TrophyRow"
			-- One plinth per Warden. Empty plinths are as much of a statement as
			-- full ones.
			for index = 1, 3 do
				PartFactory.Part({
					Name = "Plinth",
					Size = Vector3.new(4, 6, 4),
					Color = Color3.fromRGB(88, 84, 76),
					Material = Enum.Material.Marble,
					CFrame = HUB_ORIGIN * CFrame.new(-52 + index * 8, 3, 30),
					Parent = model,
				})
			end
			model.Parent = parent
			return model
		end,
	},
	{
		id = "TrainingRing",
		name = "The Ring",
		unlocked = function(profile)
			return profile.stats.runs >= 3
		end,
		build = function(parent: Instance): Model
			local model = Instance.new("Model")
			model.Name = "TrainingRing"
			PartFactory.Part({
				Name = "RingFloor",
				Size = Vector3.new(34, 1, 34),
				Shape = Enum.PartType.Cylinder,
				Color = Color3.fromRGB(84, 78, 72),
				Material = Enum.Material.Sand,
				CFrame = HUB_ORIGIN * CFrame.new(46, 0.5, 18) * CFrame.Angles(0, 0, math.rad(90)),
				Parent = model,
			})
			for index = 1, 8 do
				local angle = (index / 8) * math.pi * 2
				PartFactory.Part({
					Name = "RingPost",
					Size = Vector3.new(1, 5, 1),
					Color = DARK,
					Material = Enum.Material.Wood,
					CFrame = HUB_ORIGIN * CFrame.new(46 + math.cos(angle) * 17, 2.5, 18 + math.sin(angle) * 17),
					Parent = model,
				})
			end
			model.Parent = parent
			return model
		end,
	},
}

--------------------------------------------------------------------------------
-- NPCs
--------------------------------------------------------------------------------

local function buildNPC(definition: any, parent: Instance): Model
	local rig = RigBuilder.Build({
		name = definition.name,
		scale = definition.rig.scale,
		palette = definition.rig.palette,
		silhouette = definition.rig.silhouette,
		material = definition.rig.material,
		glow = definition.rig.glow,
		maxHealth = 100,
		walkSpeed = 0,
	})

	rig:PivotTo(HUB_ORIGIN * CFrame.new(definition.position + Vector3.new(0, 3.2, 0)) * CFrame.Angles(0, math.rad(definition.facing), 0))
	rig.Parent = parent

	-- Hub NPCs are scenery with a conversation attached. Anchoring them means they
	-- cannot be shoved into the hearth, which players will absolutely try.
	for _, part in rig:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
		end
	end

	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayName = definition.name
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
		humanoid.NameDisplayDistance = 60
	end

	rig:SetAttribute("NpcId", definition.id)
	rig:SetAttribute("IdleClip", definition.idleClip)

	local torso = rig:FindFirstChild("Torso")
	if torso and torso:IsA("BasePart") then
		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Speak"
		prompt.ObjectText = definition.name
		prompt.HoldDuration = 0.2
		prompt.MaxActivationDistance = 14
		prompt.RequiresLineOfSight = false
		prompt.Parent = torso

		hubMaid:Add(prompt.Triggered:Connect(function(player)
			HubService.TalkTo(player, definition.id)
		end))
	end

	return rig
end

--------------------------------------------------------------------------------
-- Build / refresh
--------------------------------------------------------------------------------

--- Rebuilds the structure set to match the most advanced profile present.
function HubService.RefreshStructures()
	local best: any = nil
	for _, player in Players:GetPlayers() do
		local profile = registry.DataService.Get(player)
		if profile then
			if not best or profile.stats.runs > best.stats.runs then
				best = profile
			end
		end
	end
	if not best then
		return
	end

	local container = hubModel
	if not container then
		return
	end

	for _, spec in STRUCTURES do
		local exists = structures[spec.id] ~= nil
		local shouldExist = false
		local ok, result = pcall(spec.unlocked, best)
		if ok then
			shouldExist = result
		end

		if shouldExist and not exists then
			structures[spec.id] = spec.build(container)
			-- Announce it: a building appearing is the reward, and a player who
			-- misses it got nothing.
			for _, player in Players:GetPlayers() do
				Net.FireClient("Notify", player, {
					kind = "Hub",
					title = "EMBERHOLD GROWS",
					body = spec.name .. " has been rebuilt.",
				})
			end
		end
	end
end

function HubService.Build()
	hubMaid:DoCleaning()
	structures = {}
	npcModels = {}

	local model = Instance.new("Model")
	model.Name = "Emberhold"
	model.Parent = registry.World.Hub
	hubMaid:Add(model)
	hubModel = model

	buildGround(model)
	buildRunGate(model)

	for _, npcId in DialogueConfig.Order do
		local definition = DialogueConfig.Get(npcId)
		if definition then
			npcModels[npcId] = buildNPC(definition, model)
		end
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end
end

--------------------------------------------------------------------------------
-- Interactions
--------------------------------------------------------------------------------

function HubService.SpawnPosition(): CFrame
	return HUB_ORIGIN * CFrame.new(SPAWN_OFFSET)
end

function HubService.ReturnToHub(player: Player)
	local character = player.Character
	if character then
		character:PivotTo(HubService.SpawnPosition())
	end
	local combatant = registry.CombatService.GetByPlayer(player)
	if combatant then
		combatant.humanoid.Health = combatant.humanoid.MaxHealth
	end
	HubService.RefreshStructures()
end

--[[
	Resolves what an NPC has to say and sends it. Lines marked `once` are recorded
	as seen the moment they are sent, so a player cannot farm a story beat by
	walking away mid-conversation.
]]
function HubService.TalkTo(player: Player, npcId: string)
	local state = registry.ProgressionService.DialogueState(player)
	if not state then
		return
	end

	local line = DialogueConfig.Resolve(npcId, state)
	if not line then
		return
	end

	local npc = DialogueConfig.Get(npcId)
	Net.FireClient("Dialogue", player, {
		npcId = npcId,
		npcName = npc and npc.name or npcId,
		lines = line.text,
		opens = line.opens,
		style = "NPC",
	})

	if line.once then
		registry.ProgressionService.MarkLineSeen(player, line.id)
	end
	for _, flag in line.sets or {} do
		registry.ProgressionService.SetStoryFlag(player, flag)
	end
	if line.grants then
		if line.grants.cosmetic then
			registry.ProgressionService.GrantCosmetic(player, line.grants.cosmetic)
		end
		if line.grants.relic then
			registry.ProgressionService.GrantRelic(player, line.grants.relic)
		end
	end
end

function HubService.OpenExpedition(player: Player)
	local profile = registry.DataService.Get(player)
	if not profile then
		return
	end

	local regions = {}
	for regionId, region in RegionConfig.Regions do
		if profile.progress.regionsUnlocked[regionId] then
			table.insert(regions, {
				id = regionId,
				name = region.displayName,
				subtitle = region.subtitle,
				description = region.description,
				order = region.order,
				boss = region.boss,
			})
		end
	end
	table.sort(regions, function(a, b)
		return a.order < b.order
	end)

	local weapons = {}
	for _, weaponId in WeaponConfig.Order do
		local definition = WeaponConfig.Get(weaponId)
		local owned = profile.weapons[weaponId]
		if definition and owned then
			table.insert(weapons, {
				id = weaponId,
				name = definition.displayName,
				subtitle = definition.subtitle,
				playstyle = definition.playstyle,
				strengths = definition.strengths,
				weaknesses = definition.weaknesses,
				unlocked = owned.unlocked,
				cost = definition.unlockCost,
				level = owned.level,
				experience = owned.experience,
				equippedTemper = owned.equippedTemper,
			})
		end
	end

	Net.FireClient("Dialogue", player, {
		npcId = "gate",
		npcName = Lore.Terms.Hub,
		lines = {},
		opens = "Expedition",
		payload = { regions = regions, weapons = weapons, maxHeat = GameConfig.Run.MaxHeat },
		style = "Menu",
	})
end

--------------------------------------------------------------------------------
-- Hub actions
--------------------------------------------------------------------------------

local ACTIONS: { [string]: (Player, any) -> (boolean, string?) } = {
	UnlockWeapon = function(player, payload)
		return registry.ProgressionService.UnlockWeapon(player, tostring(payload.weaponId))
	end,
	BuyTemper = function(player, payload)
		return registry.ProgressionService.BuyTemper(player, tostring(payload.weaponId), tostring(payload.temperId))
	end,
	EquipTemper = function(player, payload)
		return registry.ProgressionService.EquipTemper(player, tostring(payload.weaponId), tostring(payload.temperId or ""))
	end,
	EquipRelic = function(player, payload)
		return registry.ProgressionService.EquipRelic(player, tostring(payload.relicId), payload.equip == true)
	end,
	EquipCosmetic = function(player, payload)
		return registry.ProgressionService.EquipCosmetic(player, tostring(payload.slot), tostring(payload.cosmeticId or ""))
	end,
	Talk = function(player, payload)
		HubService.TalkTo(player, tostring(payload.npcId))
		return true, nil
	end,
	Settings = function(player, payload)
		registry.DataService.Update(player, function(profile)
			for key, value in payload.settings or {} do
				if profile.settings[key] ~= nil and type(value) == type(profile.settings[key]) then
					profile.settings[key] = value
				end
			end
		end)
		return true, nil
	end,
}

--------------------------------------------------------------------------------

function HubService.Init(services: any)
	registry = services
end

function HubService.Start()
	HubService.Build()

	Net.OnServerInvoke("HubAction", function(player, action, payload)
		local handler = ACTIONS[tostring(action)]
		if not handler then
			return false, "unknown action"
		end
		if type(payload) ~= "table" then
			payload = {}
		end
		-- Hub actions are only legal outside a run: no buying a weapon mid-fight.
		if registry.RunManager.GetSession(player) and action ~= "Settings" then
			return false, "not while running"
		end
		return handler(player, payload)
	end)

	registry.DataService.ProfileLoaded:Connect(function()
		HubService.RefreshStructures()
	end)

	registry.ProgressionService.Unlocked:Connect(function()
		HubService.RefreshStructures()
	end)
end

return HubService
