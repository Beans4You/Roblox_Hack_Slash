--!strict
--[[
	VfxController — hit feedback, damage numbers and attack telegraphs.

	Everything here is pooled. Hit sparks and damage numbers spawn dozens of times
	a second during a fight, and creating and destroying Instances at that rate is
	one of the few things that reliably costs frames on a Roblox client.

	TELEGRAPHS ARE THE MOST IMPORTANT THING IN THIS FILE
	A telegraph is a promise: this exact volume becomes dangerous in this exact
	number of seconds. The shape drawn here is built from the attack's own hitbox
	data, sent by the server, so it cannot drift out of sync with the attack it
	describes. The fill animation runs to completion in real time -- it is never
	tweened to a duration different from the windup, because a telegraph that
	lies is worse than no telegraph.

	Undodgeable attacks are drawn in a different colour, always. The player has to
	be able to tell "get out of the way" from "you cannot dodge this" at a glance.

	HIT STOP
	The server sends a hit-stop duration with each landed hit. The client freezes
	the attacker's animation for that long. It is a handful of milliseconds and it
	is most of why a hit feels like it connected.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local GameConfig = require(Shared.Config.GameConfig)
local Lore = require(Shared.Config.Lore)
local ObjectPool = require(Shared.Util.ObjectPool)
local Net = require(Shared.Net.Net)

local VfxController = {}

local registry: any = nil
local player = Players.LocalPlayer

local effectsFolder: Folder
local damageNumberPool: any
local sparkPool: any

--- Rate limiting. A spin ultimate through eight enemies produces a lot of hits;
--- past a certain density more sparks add nothing but cost.
local vfxThisSecond = 0
local vfxWindowStart = 0
local activeDamageNumbers = 0

--------------------------------------------------------------------------------
-- Pools
--------------------------------------------------------------------------------

local function makeDamageNumber(): BillboardGui
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DamageNumber"
	billboard.Size = UDim2.fromOffset(180, 60)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 220
	billboard.Enabled = false

	local label = Instance.new("TextLabel")
	label.Name = "Value"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextStrokeTransparency = 0.35
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.Parent = billboard

	billboard.Parent = effectsFolder
	return billboard
end

local function resetDamageNumber(billboard: BillboardGui)
	billboard.Enabled = false
	billboard.Adornee = nil
	billboard.Parent = effectsFolder
	local label = billboard:FindFirstChild("Value") :: TextLabel?
	if label then
		label.TextTransparency = 0
		label.Position = UDim2.fromScale(0, 0)
	end
end

local function makeSpark(): Part
	local part = Instance.new("Part")
	part.Name = "HitSpark"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Shape = Enum.PartType.Ball
	part.Material = Enum.Material.Neon
	part.Size = Vector3.one
	part.Transparency = 1
	part.Parent = effectsFolder
	return part
end

local function resetSpark(part: Part)
	part.Transparency = 1
	part.Size = Vector3.one
end

--------------------------------------------------------------------------------
-- Feedback
--------------------------------------------------------------------------------

local function allowVfx(): boolean
	local clock = os.clock()
	if clock - vfxWindowStart >= 1 then
		vfxWindowStart = clock
		vfxThisSecond = 0
	end
	if vfxThisSecond >= GameConfig.Performance.MaxHitVfxPerSecond then
		return false
	end
	vfxThisSecond += 1
	return true
end

local function showDamageNumber(position: Vector3, amount: number, color: Color3, critical: boolean)
	if activeDamageNumbers >= GameConfig.Performance.MaxDamageNumbers then
		return
	end

	local billboard = damageNumberPool:Get()
	local label = billboard:FindFirstChild("Value") :: TextLabel
	label.Text = if critical then tostring(amount) .. "!" else tostring(amount)
	label.TextColor3 = color
	label.TextTransparency = 0

	-- Scatter so simultaneous hits do not stack into an unreadable pile.
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.1
	anchor.CFrame = CFrame.new(position + Vector3.new(
		(math.random() - 0.5) * 3,
		0,
		(math.random() - 0.5) * 3
	))
	anchor.Parent = effectsFolder

	billboard.Adornee = anchor
	billboard.Size = if critical then UDim2.fromOffset(240, 80) else UDim2.fromOffset(180, 60)
	billboard.Enabled = true
	activeDamageNumbers += 1

	local rise = TweenService:Create(anchor, TweenInfo.new(0.85, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = anchor.CFrame + Vector3.new(0, 7, 0),
	})
	local fade = TweenService:Create(label, TweenInfo.new(0.85, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		TextTransparency = 1,
	})
	rise:Play()
	fade:Play()

	task.delay(0.9, function()
		anchor:Destroy()
		activeDamageNumbers -= 1
		damageNumberPool:Release(billboard)
	end)
end

local function showSpark(position: Vector3, color: Color3, size: number)
	if not allowVfx() then
		return
	end
	local spark = sparkPool:Get()
	spark.Color = color
	spark.Size = Vector3.one * size
	spark.Transparency = 0.15
	spark.CFrame = CFrame.new(position)

	local grow = TweenService:Create(spark, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.one * size * 2.4,
		Transparency = 1,
	})
	grow:Play()

	task.delay(0.26, function()
		sparkPool:Release(spark)
	end)
end

--------------------------------------------------------------------------------
-- Telegraphs
--------------------------------------------------------------------------------

local DANGER = Color3.fromRGB(255, 82, 68)
local UNDODGEABLE = Color3.fromRGB(255, 200, 60)

--[[
	Draws a warning volume that fills over `duration`.

	Cone telegraphs are approximated with a flat wedge-ish slab sized to the arc.
	A true cone mesh would be more accurate and much less readable at a glance;
	what the player needs is "roughly this wide, roughly this far, right now".
]]
local function drawTelegraph(payload: any)
	local color = if payload.undodgeable then UNDODGEABLE else DANGER
	local duration = math.max(0.05, payload.duration or 0.4)

	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = 0.82
	part.Name = "Telegraph"

	local shape = payload.shape
	if shape == "Circle" or shape == "Ring" then
		part.Shape = Enum.PartType.Cylinder
		part.Size = Vector3.new(0.3, payload.range * 2, payload.range * 2)
		part.CFrame = CFrame.new(payload.cframe.Position) * CFrame.Angles(0, 0, math.rad(90))
	elseif shape == "Line" then
		local width = (payload.width or 2) * 2
		part.Size = Vector3.new(width, 0.3, payload.range)
		part.CFrame = payload.cframe * CFrame.new(0, -2.5, -payload.range * 0.5)
	else
		-- Cone.
		local angle = payload.angle or 100
		local width = payload.range * 2 * math.sin(math.rad(angle * 0.5))
		part.Size = Vector3.new(width, 0.3, payload.range)
		part.CFrame = payload.cframe * CFrame.new(0, -2.5, -payload.range * 0.5)
	end

	part.Parent = effectsFolder

	-- The fill is the countdown. It reaching full is the moment the hitbox opens.
	local fill = part:Clone()
	fill.Transparency = 0.45
	fill.Size = Vector3.new(part.Size.X * 0.06, part.Size.Y, part.Size.Z)
	fill.Parent = effectsFolder

	if shape == "Circle" or shape == "Ring" then
		fill.Size = Vector3.new(0.35, 0.6, 0.6)
		TweenService:Create(fill, TweenInfo.new(duration, Enum.EasingStyle.Linear), {
			Size = part.Size,
		}):Play()
	else
		fill.Size = Vector3.new(part.Size.X, part.Size.Y, 0.2)
		fill.CFrame = payload.cframe * CFrame.new(0, -2.5, 0)
		TweenService:Create(fill, TweenInfo.new(duration, Enum.EasingStyle.Linear), {
			Size = part.Size,
			CFrame = part.CFrame,
		}):Play()
	end

	Debris:AddItem(part, duration + 0.12)
	Debris:AddItem(fill, duration + 0.12)

	if payload.boss then
		registry.AudioController.PlayAt("Telegraph", payload.cframe.Position)
	end
end

--------------------------------------------------------------------------------
-- Hit handling
--------------------------------------------------------------------------------

local function onFeedback(payload: any)
	local color = Lore.ElementColor(payload.element or "Physical")

	if payload.kind == "Dodged" then
		showSpark(payload.position, Color3.fromRGB(200, 220, 255), 1.4)
		registry.AudioController.PlayAt("DodgePerfect", payload.position)
		return
	end

	if payload.kind == "Parried" then
		showSpark(payload.position, Color3.fromRGB(255, 240, 190), 4)
		registry.AudioController.PlayAt("ParryPerfect", payload.position)
		registry.CameraController.Shake(payload.shake or 1)
		registry.HudController.Flash(Color3.fromRGB(255, 240, 190), 0.25)
		return
	end

	if payload.kind == "Explosion" then
		showSpark(payload.position, color, (payload.radius or 10) * 0.5)
		registry.AudioController.PlayAt("Shockwave", payload.position)
		registry.CameraController.Shake(payload.shake or 1)
		return
	end

	if payload.kind == "BossBreak" then
		registry.CameraController.Shake(payload.shake or 2)
		registry.HudController.Flash(Color3.fromRGB(255, 200, 110), 0.4)
		registry.AudioController.PlayAt("BossBreak", payload.position)
		return
	end

	if payload.kind == "Heal" then
		showDamageNumber(payload.position, payload.amount, Color3.fromRGB(120, 255, 170), false)
		registry.AudioController.PlayLocal("Heal")
		return
	end

	-- An ordinary hit.
	local profile = registry.HudController.Settings()
	if profile.damageNumbers then
		showDamageNumber(
			payload.position,
			payload.amount,
			if payload.crit then Color3.fromRGB(255, 220, 120) else color,
			payload.crit == true
		)
	end
	showSpark(payload.position, color, if payload.crit then 3 else 1.8)

	local localCharacter = player.Character
	local isLocalTarget = localCharacter and localCharacter:GetAttribute("NetId") == payload.targetId

	if isLocalTarget then
		-- Being hit is louder than hitting: the player must never miss it.
		registry.CameraController.Shake(math.max(0.8, payload.shake or 0))
		registry.HudController.Flash(Color3.fromRGB(255, 70, 70), 0.3)
		registry.AudioController.PlayLocal("PlayerHurt")
	else
		registry.CameraController.Shake(payload.shake or 0.3)
		registry.AudioController.PlayAt("Slash", payload.position)

		-- Hit stop, applied to the local character's animation only.
		if payload.hitStop and payload.hitStop > 0 and localCharacter then
			registry.ProceduralAnimator.Freeze(localCharacter, payload.hitStop)
		end
	end
end

--------------------------------------------------------------------------------

function VfxController.Init(services: any)
	registry = services
end

function VfxController.Start()
	effectsFolder = workspace:FindFirstChild("Effects") :: Folder
	if not effectsFolder then
		effectsFolder = Instance.new("Folder")
		effectsFolder.Name = "Effects"
		effectsFolder.Parent = workspace
	end

	damageNumberPool = ObjectPool.new(makeDamageNumber, resetDamageNumber, 32)
	sparkPool = ObjectPool.new(makeSpark, resetSpark, 40)
	-- Pre-warming means the first fight of a session does not pay for allocation
	-- at exactly the moment the player is forming an opinion about how it feels.
	damageNumberPool:PreWarm(12)
	sparkPool:PreWarm(16)

	Net.OnClientEvent("CombatFeedback", function(payload)
		if type(payload) == "table" then
			local ok, err = pcall(onFeedback, payload)
			if not ok and GameConfig.Debug.Enabled then
				warn("[VfxController] " .. tostring(err))
			end
		end
	end)

	Net.OnClientEvent("Telegraph", function(payload)
		if type(payload) == "table" and typeof(payload.cframe) == "CFrame" then
			local ok, err = pcall(drawTelegraph, payload)
			if not ok and GameConfig.Debug.Enabled then
				warn("[VfxController] telegraph: " .. tostring(err))
			end
		end
	end)
end

function VfxController.Update() end

return VfxController
