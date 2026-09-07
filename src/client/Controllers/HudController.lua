--!strict
--[[
	HudController — the in-fight overlay.

	Layout decisions this encodes, all in service of the fight staying readable:

	  - Bottom-left: health, stamina. Where your eye already is when you are
	    watching your own character.
	  - Bottom-right: ability, ultimate. Cooldowns you glance at between attacks.
	  - Top-left: held Graces. Reference information, checked between rooms.
	  - Top-centre: the boss bar, and nothing else. Only one thing is ever allowed
	    to sit in the top-centre.
	  - Dead centre: nothing, ever, except the finisher prompt and the damage
	    flash. The middle of the screen belongs to the enemy.

	The whole HUD fades out in the hub, where none of it is relevant, and fades
	back in when a run starts.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local Net = require(Shared.Net.Net)

local HudController = {}

local registry: any = nil
local player = Players.LocalPlayer
local UiKit: any

local screenGui: ScreenGui
local elements: any = {}
local settings = {
	cameraShake = 1.0,
	screenFlash = true,
	damageNumbers = true,
	hudScale = 1.0,
}

local runActive = false
local bossVisible = false
local notificationQueue: { any } = {}
local showingNotification = false

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function buildVitals(parent: Instance)
	local container = UiKit.Frame({
		Name = "Vitals",
		Size = UDim2.fromOffset(340, 92),
		Position = UDim2.new(0, 28, 1, -28),
		AnchorPoint = Vector2.new(0, 1),
		BackgroundTransparency = 1,
		Parent = parent,
	})

	elements.health = UiKit.Bar({
		Size = UDim2.new(1, 0, 0, 26),
		Position = UDim2.fromOffset(0, 0),
		Color = UiKit.Colors.Health,
		GhostColor = UiKit.Colors.HealthLost,
		ShowText = true,
		Parent = container,
	})

	elements.stamina = UiKit.Bar({
		Size = UDim2.new(0.78, 0, 0, 10),
		Position = UDim2.fromOffset(0, 32),
		Color = UiKit.Colors.Stamina,
		GhostColor = Color3.fromRGB(70, 96, 88),
		Parent = container,
	})

	elements.weaponLabel = UiKit.Label({
		Size = UDim2.new(1, 0, 0, 18),
		Position = UDim2.fromOffset(0, 48),
		Text = "",
		TextSize = 13,
		TextColor3 = UiKit.Colors.TextDim,
		Font = UiKit.Fonts.Heading,
		Parent = container,
	})

	-- Status effect row. Icons are text glyphs; the colour carries the meaning.
	elements.statusRow = UiKit.Frame({
		Name = "Statuses",
		Size = UDim2.new(1, 0, 0, 22),
		Position = UDim2.fromOffset(0, 68),
		BackgroundTransparency = 1,
		Parent = container,
	})
	UiKit.HList(elements.statusRow, 6)
end

local function buildAbilities(parent: Instance)
	local container = UiKit.Frame({
		Name = "Abilities",
		Size = UDim2.fromOffset(230, 96),
		Position = UDim2.new(1, -28, 1, -28),
		AnchorPoint = Vector2.new(1, 1),
		BackgroundTransparency = 1,
		Parent = parent,
	})

	local function slot(name: string, key: string, x: number, color: Color3)
		local frame = UiKit.Panel({
			Name = name,
			Size = UDim2.fromOffset(66, 66),
			Position = UDim2.fromOffset(x, 30),
			BackgroundColor3 = UiKit.Colors.Panel,
			StrokeColor = color,
			Parent = container,
		})

		local keyLabel = UiKit.Label({
			Size = UDim2.new(1, 0, 0, 16),
			Position = UDim2.fromOffset(0, 4),
			Text = key,
			TextSize = 13,
			TextColor3 = color,
			Font = UiKit.Fonts.Heading,
			TextXAlignment = Enum.TextXAlignment.Center,
			Parent = frame,
		})

		-- Cooldown is drawn as a shade that wipes downward, so "how much longer"
		-- is readable without reading a number.
		local cover = UiKit.Frame({
			Name = "Cover",
			Size = UDim2.fromScale(1, 0),
			Position = UDim2.fromScale(0, 0),
			BackgroundColor3 = UiKit.Colors.Void,
			BackgroundTransparency = 0.4,
			Parent = frame,
		})
		local coverCorner = Instance.new("UICorner")
		coverCorner.CornerRadius = UDim.new(0, 8)
		coverCorner.Parent = cover

		local timeLabel = UiKit.Label({
			Size = UDim2.new(1, 0, 0, 20),
			Position = UDim2.fromOffset(0, 34),
			Text = "",
			TextSize = 18,
			Font = UiKit.Fonts.Display,
			TextXAlignment = Enum.TextXAlignment.Center,
			Parent = frame,
		})

		return { frame = frame, cover = cover, time = timeLabel, key = keyLabel }
	end

	elements.ability = slot("Ability", "E", 0, UiKit.Colors.Ability)
	elements.ultimate = slot("Ultimate", "R", 78, UiKit.Colors.Ultimate)

	elements.ultimateBar = UiKit.Bar({
		Size = UDim2.fromOffset(144, 8),
		Position = UDim2.fromOffset(0, 14),
		Color = UiKit.Colors.Ultimate,
		GhostColor = Color3.fromRGB(96, 74, 40),
		Parent = container,
	})
end

local function buildRunInfo(parent: Instance)
	local container = UiKit.Frame({
		Name = "RunInfo",
		Size = UDim2.fromOffset(300, 200),
		Position = UDim2.fromOffset(28, 28),
		BackgroundTransparency = 1,
		Parent = parent,
	})

	elements.regionLabel = UiKit.Label({
		Size = UDim2.new(1, 0, 0, 22),
		Text = "",
		TextSize = 17,
		Font = UiKit.Fonts.Display,
		Parent = container,
	})

	elements.roomLabel = UiKit.Label({
		Size = UDim2.new(1, 0, 0, 18),
		Position = UDim2.fromOffset(0, 22),
		Text = "",
		TextSize = 13,
		TextColor3 = UiKit.Colors.TextDim,
		Parent = container,
	})

	elements.motesLabel = UiKit.Label({
		Size = UDim2.new(1, 0, 0, 18),
		Position = UDim2.fromOffset(0, 42),
		Text = "",
		TextSize = 14,
		TextColor3 = UiKit.Colors.Accent,
		Font = UiKit.Fonts.Heading,
		Parent = container,
	})

	elements.boonList = UiKit.Frame({
		Name = "Graces",
		Size = UDim2.new(1, 0, 1, -70),
		Position = UDim2.fromOffset(0, 70),
		BackgroundTransparency = 1,
		Parent = container,
	})
	UiKit.VList(elements.boonList, 3)
end

local function buildBossBar(parent: Instance)
	local container = UiKit.Frame({
		Name = "BossBar",
		Size = UDim2.fromOffset(640, 86),
		Position = UDim2.new(0.5, 0, 0, 34),
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = parent,
	})

	elements.bossName = UiKit.Label({
		Size = UDim2.new(1, 0, 0, 26),
		Text = "",
		TextSize = 22,
		Font = UiKit.Fonts.Display,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = container,
	})

	elements.bossSubtitle = UiKit.Label({
		Size = UDim2.new(1, 0, 0, 16),
		Position = UDim2.fromOffset(0, 26),
		Text = "",
		TextSize = 12,
		TextColor3 = UiKit.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = container,
	})

	elements.bossHealth = UiKit.Bar({
		Size = UDim2.new(1, 0, 0, 16),
		Position = UDim2.fromOffset(0, 46),
		Color = UiKit.Colors.Health,
		GhostColor = UiKit.Colors.HealthLost,
		Parent = container,
	})

	-- The break meter sits directly under the health bar because the player needs
	-- to read both in one glance to decide whether to push.
	elements.bossBreak = UiKit.Bar({
		Size = UDim2.new(1, 0, 0, 6),
		Position = UDim2.fromOffset(0, 66),
		Color = UiKit.Colors.Ultimate,
		GhostColor = Color3.fromRGB(80, 62, 34),
		Parent = container,
	})

	elements.bossPhase = UiKit.Label({
		Size = UDim2.new(1, 0, 0, 14),
		Position = UDim2.fromOffset(0, 72),
		Text = "",
		TextSize = 11,
		TextColor3 = UiKit.Colors.Accent,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = container,
	})

	elements.bossBar = container
end

local function buildOverlays(parent: Instance)
	-- Damage flash. Sits above everything, ignores input.
	elements.flash = UiKit.Frame({
		Name = "Flash",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = UiKit.Colors.Danger,
		BackgroundTransparency = 1,
		ZIndex = 50,
		Parent = parent,
	})

	elements.finisherPrompt = UiKit.Panel({
		Name = "FinisherPrompt",
		Size = UDim2.fromOffset(230, 44),
		Position = UDim2.new(0.5, 0, 0.62, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = UiKit.Colors.Panel,
		StrokeColor = UiKit.Colors.Accent,
		Visible = false,
		ZIndex = 20,
		Parent = parent,
	})
	UiKit.Label({
		Size = UDim2.fromScale(1, 1),
		Text = "<b>RIGHT CLICK</b>  ·  FINISH",
		TextSize = 15,
		TextColor3 = UiKit.Colors.Accent,
		Font = UiKit.Fonts.Heading,
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 21,
		Parent = elements.finisherPrompt,
	})

	-- Notifications: unlocks, mastery, Keepsakes. Queued so two never overlap.
	elements.notification = UiKit.Panel({
		Name = "Notification",
		Size = UDim2.fromOffset(420, 74),
		Position = UDim2.new(0.5, 0, 0, -90),
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundColor3 = UiKit.Colors.PanelRaised,
		StrokeColor = UiKit.Colors.Accent,
		Padding = 12,
		ZIndex = 30,
		Parent = parent,
	})
	elements.notificationTitle = UiKit.Label({
		Size = UDim2.new(1, 0, 0, 22),
		Text = "",
		TextSize = 18,
		Font = UiKit.Fonts.Display,
		ZIndex = 31,
		Parent = elements.notification,
	})
	elements.notificationBody = UiKit.Label({
		Size = UDim2.new(1, 0, 0, 30),
		Position = UDim2.fromOffset(0, 24),
		Text = "",
		TextSize = 13,
		TextColor3 = UiKit.Colors.TextDim,
		TextWrapped = true,
		ZIndex = 31,
		Parent = elements.notification,
	})
end

--------------------------------------------------------------------------------
-- Notifications
--------------------------------------------------------------------------------

local function pumpNotifications()
	if showingNotification then
		return
	end
	local next_ = table.remove(notificationQueue, 1)
	if not next_ then
		return
	end

	showingNotification = true
	elements.notificationTitle.Text = next_.title or ""
	elements.notificationBody.Text = next_.body or ""
	local stroke = elements.notification:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = next_.color or UiKit.Colors.Accent
	end

	local slideIn = TweenService:Create(elements.notification, UiKit.Tween.Smooth, {
		Position = UDim2.new(0.5, 0, 0, 26),
	})
	slideIn:Play()
	UiKit.Pop(elements.notification, 0.06)
	registry.AudioController.PlayLocal("UnlockEarned")

	task.delay(3.4, function()
		local slideOut = TweenService:Create(elements.notification, UiKit.Tween.Smooth, {
			Position = UDim2.new(0.5, 0, 0, -90),
		})
		slideOut:Play()
		task.delay(0.35, function()
			showingNotification = false
			pumpNotifications()
		end)
	end)
end

function HudController.Notify(payload: any)
	table.insert(notificationQueue, payload)
	pumpNotifications()
end

--------------------------------------------------------------------------------
-- Public helpers used by other controllers
--------------------------------------------------------------------------------

function HudController.Flash(color: Color3, strength: number)
	if not settings.screenFlash then
		return
	end
	elements.flash.BackgroundColor3 = color
	elements.flash.BackgroundTransparency = 1 - math.clamp(strength, 0, 1) * 0.35
	TweenService:Create(elements.flash, TweenInfo.new(0.35, Enum.EasingStyle.Quad), {
		BackgroundTransparency = 1,
	}):Play()
end

function HudController.Settings()
	return settings
end

--- True while a run is in progress. Menus use it to decide what to offer.
function HudController.IsRunActive(): boolean
	return runActive
end

function HudController.ScreenGui(): ScreenGui
	return screenGui
end

function HudController.SetRunActive(active: boolean)
	runActive = active
	for _, name in { "RunInfo", "Vitals", "Abilities" } do
		local element = screenGui:FindFirstChild(name, true)
		if element and element:IsA("GuiObject") then
			element.Visible = active
		end
	end
end

--------------------------------------------------------------------------------
-- Grace list
--------------------------------------------------------------------------------

local function renderBoons(boons: { any })
	elements.boonList:ClearAllChildren()
	UiKit.VList(elements.boonList, 3)

	for index, boon in boons do
		local row = UiKit.Frame({
			Size = UDim2.new(1, 0, 0, 18),
			BackgroundTransparency = 1,
			LayoutOrder = index,
			Parent = elements.boonList,
		})
		UiKit.Frame({
			Size = UDim2.fromOffset(3, 14),
			Position = UDim2.fromOffset(0, 2),
			BackgroundColor3 = boon.color or UiKit.Colors.Accent,
			Parent = row,
		})
		UiKit.Label({
			Size = UDim2.new(1, -10, 1, 0),
			Position = UDim2.fromOffset(10, 0),
			Text = boon.name,
			TextSize = 12,
			TextColor3 = boon.color or UiKit.Colors.Text,
			Font = UiKit.Fonts.Heading,
			Parent = row,
		})
	end
end

--------------------------------------------------------------------------------
-- Statuses
--------------------------------------------------------------------------------

local function renderStatuses(statuses: any)
	elements.statusRow:ClearAllChildren()
	UiKit.HList(elements.statusRow, 6)

	local StatusConfig = require(Shared.Config.StatusConfig)
	for statusId, entry in statuses do
		local config = StatusConfig.Get(statusId)
		if config then
			local pip = UiKit.Frame({
				Size = UDim2.fromOffset(if entry.stacks > 1 then 30 else 18, 18),
				BackgroundColor3 = config.color,
				BackgroundTransparency = 0.25,
				Parent = elements.statusRow,
			})
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 4)
			corner.Parent = pip

			if entry.stacks > 1 then
				UiKit.Label({
					Size = UDim2.fromScale(1, 1),
					Text = tostring(entry.stacks),
					TextSize = 11,
					TextColor3 = Color3.new(0, 0, 0),
					Font = UiKit.Fonts.Heading,
					TextXAlignment = Enum.TextXAlignment.Center,
					TextStrokeTransparency = 1,
					Parent = pip,
				})
			end
		end
	end
end

--------------------------------------------------------------------------------

function HudController.Init(services: any)
	registry = services
	UiKit = services.UiKit
end

function HudController.Start()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "HollowVergeHud"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = player:WaitForChild("PlayerGui")
	registry.ScreenGui = screenGui

	buildVitals(screenGui)
	buildAbilities(screenGui)
	buildRunInfo(screenGui)
	buildBossBar(screenGui)
	buildOverlays(screenGui)

	HudController.SetRunActive(false)

	Net.OnClientEvent("RunSync", function(payload)
		if type(payload) ~= "table" then
			return
		end
		HudController.SetRunActive(payload.active == true)
		if not payload.active then
			elements.bossBar.Visible = false
			return
		end

		elements.regionLabel.Text = payload.regionName or ""
		elements.roomLabel.Text = ("ROOM %d / %d  ·  %s"):format(
			payload.slot or 0,
			payload.roomCount or 0,
			payload.roomType or ""
		)
		elements.motesLabel.Text = ("%d MOTES"):format(payload.motes or 0)
		if payload.boons then
			renderBoons(payload.boons)
		end
	end)

	Net.OnClientEvent("BossSync", function(payload)
		if type(payload) ~= "table" then
			return
		end
		if not payload.active then
			if bossVisible then
				bossVisible = false
				elements.bossBar.Visible = false
			end
			return
		end

		if not bossVisible then
			bossVisible = true
			elements.bossBar.Visible = true
			UiKit.Pop(elements.bossBar, 0.1)
		end

		elements.bossName.Text = payload.name or ""
		elements.bossSubtitle.Text = payload.subtitle or ""
		elements.bossHealth:SetValue(payload.health or 0, payload.maxHealth or 1)
		elements.bossBreak:SetValue(payload.breakMeter or 0, payload.breakThreshold or 1)
		elements.bossPhase.Text = ("PHASE %d / %d  ·  %s%s"):format(
			payload.phase or 1,
			payload.phaseCount or 1,
			payload.phaseName or "",
			if payload.broken then "  ·  <b>OPEN</b>" else ""
		)
	end)

	Net.OnClientEvent("StatusSync", function(payload)
		if type(payload) ~= "table" then
			return
		end
		local character = player.Character
		if character and character:GetAttribute("NetId") == payload.characterId then
			renderStatuses(payload.statuses or {})
		end
	end)

	Net.OnClientEvent("Notify", function(payload)
		if type(payload) == "table" then
			HudController.Notify(payload)
		end
	end)

	Net.OnClientEvent("ProfileSync", function(profile)
		if type(profile) ~= "table" or not profile.settings then
			return
		end
		settings.cameraShake = profile.settings.cameraShake
		settings.screenFlash = profile.settings.screenFlash
		settings.damageNumbers = profile.settings.damageNumbers
		settings.hudScale = profile.settings.hudScale

		registry.CameraController.SetShakeScale(settings.cameraShake)
		registry.AudioController.SetVolumes(
			profile.settings.masterVolume,
			profile.settings.musicVolume,
			profile.settings.sfxVolume
		)

		local scale = screenGui:FindFirstChildOfClass("UIScale")
		if not scale then
			scale = Instance.new("UIScale")
			scale.Parent = screenGui
		end
		scale.Scale = settings.hudScale
	end)
end

function HudController.Update(_deltaTime: number)
	if not runActive then
		return
	end

	local state = registry.CombatController.State()

	elements.health:SetValue(state.health, state.maxHealth)
	elements.stamina:SetValue(registry.CombatController.PredictedStamina(), state.maxStamina)
	elements.ultimateBar:SetValue(state.ultimate, state.ultimateMax)

	elements.weaponLabel.Text = string.upper(registry.CombatController.WeaponId())

	-- Cooldown covers. Drawn from the remaining fraction rather than an absolute
	-- time, so a Grace that shortens a cooldown is visible immediately.
	local now = state.serverTime > 0 and state.serverTime or os.clock()
	local abilityRemaining = math.max(0, state.abilityReadyAt - now)
	elements.ability.cover.Size = UDim2.fromScale(1, math.clamp(abilityRemaining / 10, 0, 1))
	elements.ability.time.Text = if abilityRemaining > 0.1 then ("%.1f"):format(abilityRemaining) else "E"

	local ultimateReady = state.ultimate >= state.ultimateMax
	elements.ultimate.cover.Size = UDim2.fromScale(1, if ultimateReady then 0 else 1)
	elements.ultimate.time.Text = if ultimateReady then "R" else ("%d%%"):format(
		math.floor(state.ultimate / math.max(1, state.ultimateMax) * 100)
	)

	elements.finisherPrompt.Visible = registry.CombatController.HasFinisherTarget()
end

return HudController
