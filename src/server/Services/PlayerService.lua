--!strict
--[[
	PlayerService — the player's body.

	Owns the character: spawning it in Emberhold, registering it with combat,
	dressing it, and handling what happens when it dies. It loads last, because it
	is the thing that connects a person to everything the other services built.

	DEATH
	Dying does not respawn you into a fresh run. It ends the current run, plays out
	the summary, and puts you back in the hub with everything you earned already
	written to your profile. The brief asks for death to read as progression rather
	than punishment, and the mechanical version of that is: nothing you gained is
	rolled back, and the screen you see when you lose leads with what you kept.

	COSMETICS
	Built from CosmeticConfig's part specs and welded on, the same way weapons and
	enemies are. Re-dressing rebuilds from scratch rather than diffing, because a
	character has at most nine cosmetic pieces and the rebuild is imperceptible.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local GameConfig = require(Shared.Config.GameConfig)
local CosmeticConfig = require(Shared.Config.CosmeticConfig)
local WeaponConfig = require(Shared.Config.WeaponConfig)
local Lore = require(Shared.Config.Lore)
local PartFactory = require(Shared.Util.PartFactory)
local Maid = require(Shared.Util.Maid)
local Net = require(Shared.Net.Net)

local PlayerService = {}

local registry: any = nil

local characterMaids: { [Player]: any } = {}

--------------------------------------------------------------------------------
-- Cosmetics
--------------------------------------------------------------------------------

local function jointPartFor(character: Model, jointName: string): BasePart?
	local candidates: { string }
	if jointName == "Head" then
		candidates = { "Head" }
	elseif jointName == "Torso" then
		candidates = { "UpperTorso", "Torso", "HumanoidRootPart" }
	elseif jointName == "RightArm" then
		candidates = { "RightHand", "RightUpperArm", "Right Arm" }
	elseif jointName == "RightLeg" then
		candidates = { "RightFoot", "RightUpperLeg", "Right Leg" }
	else
		candidates = { "HumanoidRootPart" }
	end

	for _, name in candidates do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end
	return nil
end

local function buildCosmetic(character: Model, cosmetic: any, container: Model)
	local slot = CosmeticConfig.Slots[cosmetic.slot]
	if not slot then
		return
	end
	local anchorPart = jointPartFor(character, slot.joint)
	if not anchorPart then
		return
	end

	for _, spec in cosmetic.build do
		if spec.trail then
			-- Trail cosmetics need two attachments and no geometry of their own.
			local from = PartFactory.Attachment(anchorPart, CFrame.new(-0.8, 0, 0), "CosmeticTrailA")
			local to = PartFactory.Attachment(anchorPart, CFrame.new(0.8, 0, 0), "CosmeticTrailB")
			local trail = Instance.new("Trail")
			trail.Attachment0 = from
			trail.Attachment1 = to
			trail.Color = ColorSequence.new(spec.trail.color)
			trail.Lifetime = spec.trail.lifetime
			trail.WidthScale = NumberSequence.new(1, 0)
			trail.Transparency = NumberSequence.new(0.2, 1)
			trail.LightEmission = 0.7
			trail.Parent = anchorPart
			continue
		end

		local part = PartFactory.Part({
			Name = spec.name or "Cosmetic",
			Size = spec.size,
			Color = spec.color,
			Material = spec.material,
			Transparency = spec.transparency or 0,
			Anchored = false,
			CanCollide = false,
			CanQuery = false,
		})
		part.Massless = true
		part.CollisionGroup = GameConfig.Collision.Hitbox

		local offset = CFrame.new(spec.offset or Vector3.zero)
		if spec.rotation then
			offset *= CFrame.Angles(
				math.rad(spec.rotation.X),
				math.rad(spec.rotation.Y),
				math.rad(spec.rotation.Z)
			)
		end
		part.CFrame = anchorPart.CFrame * offset
		part.Parent = container
		PartFactory.Weld(anchorPart, part, part)

		if spec.light then
			PartFactory.PointLight(part, spec.color, spec.light, 24)
		end
		if spec.spin then
			-- Aura rings rotate. Driven by a spinning constraint rather than a
			-- per-frame loop, so it costs nothing on the server.
			part:SetAttribute("SpinRate", spec.spin)
		end
	end
end

function PlayerService.RefreshAppearance(player: Player)
	local character = player.Character
	local profile = registry.DataService.Get(player)
	if not character or not profile then
		return
	end

	local existing = character:FindFirstChild("Cosmetics")
	if existing then
		existing:Destroy()
	end
	-- Trails live on the body part, not in the container, so they are cleared here.
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("Trail") and descendant.Name == "Trail" then
			descendant:Destroy()
		end
	end

	local container = Instance.new("Model")
	container.Name = "Cosmetics"
	container.Parent = character

	for slot, cosmeticId in profile.cosmetics.equipped do
		if cosmeticId ~= "" then
			local cosmetic = CosmeticConfig.Get(cosmeticId)
			if cosmetic and profile.cosmetics.owned[cosmeticId] then
				buildCosmetic(character, cosmetic, container)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Character lifecycle
--------------------------------------------------------------------------------

local function resolveWeaponFor(player: Player, weaponId: string)
	local profile = registry.DataService.Get(player)
	if not profile then
		return WeaponConfig.GetOrDefault(weaponId)
	end
	local weaponData = profile.weapons[weaponId]
	return registry.WeaponService.Resolve(
		weaponId,
		weaponData and weaponData.level or 1,
		weaponData and weaponData.equippedTemper or ""
	)
end

local function onCharacterAdded(player: Player, character: Model)
	local maid = characterMaids[player]
	if maid then
		maid:DoCleaning()
	end
	maid = Maid.new()
	characterMaids[player] = maid

	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	local root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not humanoid or not root then
		return
	end

	humanoid.MaxHealth = GameConfig.Player.BaseMaxHealth
	humanoid.Health = humanoid.MaxHealth
	humanoid.WalkSpeed = GameConfig.Player.BaseWalkSpeed
	humanoid.JumpPower = GameConfig.Player.JumpPower
	humanoid.UseJumpPower = true
	humanoid.BreakJointsOnDeath = false
	-- The game's own death flow owns this; Roblox's automatic respawn would fight it.
	humanoid.RequiresNeck = false

	PartFactory.SetCollisionGroup(character, GameConfig.Collision.Player)

	-- Default weapon so the player is never empty-handed in the hub.
	local profile = registry.DataService.Get(player)
	local defaultWeapon = "Vigil"
	if profile then
		for _, weaponId in WeaponConfig.Order do
			if profile.weapons[weaponId] and profile.weapons[weaponId].unlocked then
				defaultWeapon = weaponId
				break
			end
		end
	end

	local resolved = resolveWeaponFor(player, defaultWeapon)
	local combatant = registry.CombatService.Register(character, "Player", {
		weapon = resolved,
		poiseThreshold = 60,
	})
	if combatant then
		combatant.weight = 1
		combatant.baseWalkSpeed = GameConfig.Player.BaseWalkSpeed * resolved.stats.moveSpeedMultiplier
	end

	registry.WeaponService.Equip(character, defaultWeapon)
	PlayerService.RefreshAppearance(player)

	character:PivotTo(registry.HubService.SpawnPosition())

	maid:Add(humanoid.Died:Connect(function()
		PlayerService.HandleDeath(player, character)
	end))

	-- Falling out of the world in the hub is a soft reset, not a death.
	maid:Add(root:GetPropertyChangedSignal("Position"):Connect(function()
		if root.Position.Y < -400 and not registry.RunManager.GetSession(player) then
			character:PivotTo(registry.HubService.SpawnPosition())
		end
	end))
end

--[[
	Prepares the character for a run: the chosen weapon resolved with its mastery
	and Temper, full health, and any Keepsake that changes starting state.
]]
function PlayerService.PrepareForRun(player: Player, weaponId: string)
	local character = player.Character
	if not character then
		return
	end

	local resolved = resolveWeaponFor(player, weaponId)
	registry.WeaponService.Equip(character, weaponId)
	registry.CombatService.SetWeapon(character, resolved)

	local combatant = registry.CombatService.GetByPlayer(player)
	if combatant then
		combatant.humanoid.MaxHealth = GameConfig.Player.BaseMaxHealth
		combatant.humanoid.Health = combatant.humanoid.MaxHealth * GameConfig.Run.StartingHealthFraction
		combatant.stamina = GameConfig.Player.BaseMaxStamina
		combatant.ultimate = 0
		combatant.cooldowns = {}
	end

	registry.StatusService.Clear(character)
end

--------------------------------------------------------------------------------
-- Death
--------------------------------------------------------------------------------

function PlayerService.HandleDeath(player: Player, character: Model)
	local session = registry.RunManager.GetSession(player)

	-- Identify what killed them, for the "died to the same thing five times"
	-- Keepsake and for the boss's death counter.
	local killerEnemyId: string? = nil
	local bossId: string? = nil
	if session then
		bossId = if session.phase == "Boss" then session.region.boss else nil
		local combatant = registry.CombatService.Get(character)
		if combatant and combatant.lastAttackerId then
			killerEnemyId = combatant.lastAttackerId
		end
	end

	registry.ProgressionService.NoteDeath(player, killerEnemyId, bossId)

	if session then
		-- A SECOND KNIFE: one death per run is survivable if the Keepsake is on.
		for _, effect in registry.ProgressionService.RelicEffects(player) do
			if effect.kind == "ExtraLife" and not session.extraLifeUsed then
				session.extraLifeUsed = true
				local combatant = registry.CombatService.Get(character)
				if combatant then
					combatant.alive = true
					combatant.action = "Idle"
					combatant.humanoid.Health = combatant.humanoid.MaxHealth * effect.healthOnRevive
					registry.CombatService.GrantInvulnerability(combatant, GameConfig.Player.ReviveInvulnerability)
					Net.FireClient("Notify", player, {
						kind = "Revive",
						title = "A SECOND KNIFE",
						body = "You had another one.",
					})
					return
				end
			end
		end

		registry.RunManager.EndRun(player, "Death")
	end

	-- Respawn happens after the summary has had time to land.
	task.delay(GameConfig.Player.DeathCameraHold, function()
		if player.Parent then
			player:LoadCharacter()
		end
	end)
end

--------------------------------------------------------------------------------

function PlayerService.Init(services: any)
	registry = services
end

function PlayerService.Start()
	Players.CharacterAutoLoads = false

	local function setup(player: Player)
		player.CharacterAdded:Connect(function(character)
			task.spawn(onCharacterAdded, player, character)
		end)
		player.CharacterRemoving:Connect(function()
			local maid = characterMaids[player]
			if maid then
				maid:DoCleaning()
			end
		end)
	end

	-- The character is loaded only once the profile is in hand, so it can be
	-- dressed and armed correctly on its first frame rather than popping.
	registry.DataService.ProfileLoaded:Connect(function(player: Player)
		setup(player)
		player:LoadCharacter()

		Net.FireClient("Notify", player, {
			kind = "Welcome",
			title = Lore.GameName,
			body = Lore.Tagline,
		})
	end)

	Players.PlayerRemoving:Connect(function(player)
		local maid = characterMaids[player]
		if maid then
			maid:DoCleaning()
		end
		characterMaids[player] = nil
	end)

	-- Track who last hit each player, for death attribution.
	registry.CombatService.Damaged:Connect(function(target: any, attacker: any)
		if target.player and attacker then
			target.lastAttackerId = attacker.character:GetAttribute("EnemyId")
				or (attacker.character:GetAttribute("IsBoss") and "Warden")
				or nil
		end
	end)

	Net.OnServerEvent("SettingsSync", function(player, payload)
		if type(payload) ~= "table" then
			return
		end
		registry.DataService.Update(player, function(profile)
			for key, value in payload do
				if profile.settings[key] ~= nil and type(value) == type(profile.settings[key]) then
					profile.settings[key] = value
				end
			end
		end)
	end)
end

return PlayerService
