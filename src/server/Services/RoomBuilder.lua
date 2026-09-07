--!strict
--[[
	RoomBuilder — turns a layout description into geometry.

	One handler per geometry kind. A layout in RoomConfig is a list of these, and
	the region supplies the palette, so the same twelve layouts build as a flooded
	hall, a furnace floor, or a frozen library without any of them being authored
	three times.

	EVERYTHING IS ANCHORED AND OWNED
	Room parts are anchored (physics on hundreds of static parts is pure waste) and
	every one of them is added to the room's Maid. When a run ends, one call
	destroys the entire world it built. This is the only reason a roguelite that
	assembles and discards levels indefinitely does not leak.

	SEEDED VARIATION
	Decorative placement -- rubble, braziers, banners -- pulls from the run's Rng
	stream, so the same seed rebuilds the same room down to where the rubble sits.
	That is what makes a daily challenge genuinely identical for everyone.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local GameConfig = require(Shared.Config.GameConfig)
local RoomConfig = require(Shared.Config.RoomConfig)
local PartFactory = require(Shared.Util.PartFactory)
local Maid = require(Shared.Util.Maid)
local Rng = require(Shared.Util.Rng)

local RoomBuilder = {}

local registry: any = nil

export type BuiltRoom = {
	id: string,
	layout: any,
	model: Model,
	maid: any,
	origin: CFrame,
	spawnPoints: { Vector3 },
	featureAnchor: Vector3,
	secondaryAnchors: { Vector3 },
	entrance: Vector3,
	exits: { Vector3 },
	-- Parts a boss arena effect may manipulate (pillars, platforms).
	arenaParts: { BasePart },
}

type BuildContext = {
	model: Model,
	origin: CFrame,
	palette: any,
	rng: any,
	arenaParts: { BasePart },
	lightScale: number,
}

--------------------------------------------------------------------------------
-- Palette helpers
--------------------------------------------------------------------------------

local function shade(color: Color3, amount: number): Color3
	return Color3.new(
		math.clamp(color.R * amount, 0, 1),
		math.clamp(color.G * amount, 0, 1),
		math.clamp(color.B * amount, 0, 1)
	)
end

local function place(context: BuildContext, offset: Vector3, rotation: number?): CFrame
	local cframe = context.origin * CFrame.new(offset)
	if rotation then
		cframe *= CFrame.Angles(0, math.rad(rotation), 0)
	end
	return cframe
end

--------------------------------------------------------------------------------
-- Geometry handlers
--------------------------------------------------------------------------------

local Builders = {}

function Builders.Floor(context: BuildContext, spec: any)
	PartFactory.Part({
		Name = "Floor",
		Size = spec.size,
		Color = context.palette.floor,
		Material = Enum.Material.Slate,
		CFrame = place(context, spec.offset or Vector3.zero),
		Parent = context.model,
	})
end

--- Four walls plus a ceiling band. Ceilings are open above the band so the
--- camera never has to fight a roof.
function Builders.Perimeter(context: BuildContext, spec: any)
	local size = spec.size
	local thickness = spec.thickness or 4
	local halfX, halfZ = size.X * 0.5, size.Z * 0.5
	local height = size.Y

	local walls = {
		{ offset = Vector3.new(0, height * 0.5, -halfZ), size = Vector3.new(size.X, height, thickness) },
		{ offset = Vector3.new(0, height * 0.5, halfZ), size = Vector3.new(size.X, height, thickness) },
		{ offset = Vector3.new(-halfX, height * 0.5, 0), size = Vector3.new(thickness, height, size.Z) },
		{ offset = Vector3.new(halfX, height * 0.5, 0), size = Vector3.new(thickness, height, size.Z) },
	}

	for _, wall in walls do
		PartFactory.Part({
			Name = "Wall",
			Size = wall.size,
			Color = context.palette.stone,
			Material = Enum.Material.Slate,
			CFrame = place(context, wall.offset),
			Parent = context.model,
		})
	end
end

function Builders.PillarRing(context: BuildContext, spec: any)
	local count = spec.count or 8
	local radius = spec.radius or 24
	local height = spec.height or 24
	local thickness = spec.thickness or 3

	for index = 1, count do
		local angle = (index / count) * math.pi * 2
		local pillar = PartFactory.Part({
			Name = "ArenaPillar",
			Size = Vector3.new(thickness, height, thickness),
			Color = shade(context.palette.stone, spec.tint or 1),
			Material = Enum.Material.Slate,
			CFrame = place(context, Vector3.new(math.cos(angle) * radius, height * 0.5, math.sin(angle) * radius)),
			Parent = context.model,
		})
		table.insert(context.arenaParts, pillar)

		-- A capital at the top gives the silhouette a top edge to read against.
		PartFactory.Decor({
			Name = "Capital",
			Size = Vector3.new(thickness * 1.5, 1.2, thickness * 1.5),
			Color = shade(context.palette.trim, 1.1),
			Material = Enum.Material.Slate,
			CFrame = place(context, Vector3.new(math.cos(angle) * radius, height, math.sin(angle) * radius)),
			Parent = context.model,
		})
	end
end

function Builders.PillarRow(context: BuildContext, spec: any)
	local count = spec.count or 5
	local base = spec.offset or Vector3.zero
	local height = spec.height or 22
	local thickness = spec.thickness or 4
	local spacing = 18

	for index = 1, count do
		local z = (index - (count + 1) / 2) * spacing
		local pillar = PartFactory.Part({
			Name = "ArenaPillar",
			Size = Vector3.new(thickness, height, thickness),
			Color = context.palette.stone,
			Material = Enum.Material.Slate,
			CFrame = place(context, base + Vector3.new(0, height * 0.5, z)),
			Parent = context.model,
		})
		table.insert(context.arenaParts, pillar)
	end
end

function Builders.Rubble(context: BuildContext, spec: any)
	local count = spec.count or 8
	local radius = spec.radius or 24

	for _ = 1, count do
		local position = context.rng:PointInDisc(radius)
		local size = context.rng:Float(1.5, 4.5)
		PartFactory.Part({
			Name = "Rubble",
			Size = Vector3.new(size, size * context.rng:Float(0.5, 1), size * context.rng:Float(0.7, 1.3)),
			Color = shade(context.palette.stone, context.rng:Float(0.8, 1.1)),
			Material = Enum.Material.Slate,
			CFrame = place(context, position + Vector3.new(0, size * 0.3, 0))
				* CFrame.Angles(context.rng:Float(0, 0.4), context.rng:Float(0, 6.28), context.rng:Float(0, 0.4)),
			Parent = context.model,
		})
	end
end

function Builders.Banners(context: BuildContext, spec: any)
	local count = spec.count or 6
	local base = spec.offset or Vector3.new(0, 12, 0)

	for index = 1, count do
		local side = if index % 2 == 0 then 1 else -1
		local z = ((index - 1) // 2 - count / 4) * 22
		PartFactory.Decor({
			Name = "Banner",
			Size = Vector3.new(0.3, 9, 4),
			Color = context.palette.accent,
			Material = Enum.Material.Fabric,
			Transparency = 0.1,
			CFrame = place(context, base + Vector3.new(side * 18, 0, z)),
			Parent = context.model,
		})
	end
end

--- A bowl in the middle of the floor. Built as a ring of steps rather than a
--- true depression, because stepped ground reads better and is easier to fight on.
function Builders.Depression(context: BuildContext, spec: any)
	local radius = spec.radius or 24
	local depth = spec.height or 4

	PartFactory.Part({
		Name = "Floor",
		Size = Vector3.new(radius * 2, 2, radius * 2),
		Shape = Enum.PartType.Cylinder,
		Color = shade(context.palette.floor, 0.85),
		Material = Enum.Material.Slate,
		CFrame = place(context, Vector3.new(0, -depth - 1, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Parent = context.model,
	})
end

function Builders.Steps(context: BuildContext, spec: any)
	local count = spec.count or 3
	local radius = spec.radius or 30
	local height = spec.height or 4

	for index = 1, count do
		local stepRadius = radius - (index - 1) * 3
		PartFactory.Part({
			Name = "Step",
			Size = Vector3.new(stepRadius * 2, height / count, stepRadius * 2),
			Shape = Enum.PartType.Cylinder,
			Color = shade(context.palette.floor, 0.92 + index * 0.03),
			Material = Enum.Material.Slate,
			CFrame = place(context, Vector3.new(0, -(index - 0.5) * (height / count), 0))
				* CFrame.Angles(0, 0, math.rad(90)),
			Parent = context.model,
		})
	end
end

--- A hole. Falling in is not instant death; it teleports the player back to the
--- room entrance and costs health, which is a fairer answer to a physics shove.
function Builders.Void(context: BuildContext, spec: any)
	local zone = PartFactory.Part({
		Name = "VoidZone",
		Size = spec.size,
		CFrame = place(context, spec.offset or Vector3.zero),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = true,
		Parent = context.model,
	})
	zone:SetAttribute("IsVoid", true)
end

function Builders.Railing(context: BuildContext, spec: any)
	local base = spec.offset or Vector3.new(0, 2, 0)
	for _, side in { -1, 1 } do
		PartFactory.Part({
			Name = "Railing",
			Size = Vector3.new(1.2, 3, 70),
			Color = context.palette.trim,
			Material = Enum.Material.Metal,
			CFrame = place(context, base + Vector3.new(side * 29, 0, 0)),
			Parent = context.model,
		})
	end
end

--- Recesses around the perimeter. Cover, and somewhere to put a pedestal.
function Builders.Alcoves(context: BuildContext, spec: any)
	local count = spec.count or 6
	local radius = spec.radius or 24
	local height = spec.height or 10

	for index = 1, count do
		local angle = (index / count) * math.pi * 2
		local position = Vector3.new(math.cos(angle) * radius, height * 0.5, math.sin(angle) * radius)
		PartFactory.Part({
			Name = "Alcove",
			Size = Vector3.new(7, height, 3),
			Color = shade(context.palette.stone, 0.8),
			Material = Enum.Material.Slate,
			CFrame = place(context, position) * CFrame.Angles(0, -angle, 0),
			Parent = context.model,
		})
	end
end

function Builders.Platform(context: BuildContext, spec: any)
	local platform = PartFactory.Part({
		Name = "ArenaPlatform",
		Size = spec.size,
		Color = shade(context.palette.floor, 1.08),
		Material = Enum.Material.Slate,
		CFrame = place(context, spec.offset or Vector3.zero),
		Parent = context.model,
	})
	table.insert(context.arenaParts, platform)
end

function Builders.Ramp(context: BuildContext, spec: any)
	local size = spec.size
	PartFactory.Wedge({
		Name = "Ramp",
		Size = size,
		Color = shade(context.palette.floor, 0.96),
		Material = Enum.Material.Slate,
		CFrame = place(context, spec.offset or Vector3.zero, spec.rotation),
		Parent = context.model,
	})
end

--- The only light source in most rooms. Their placement is what makes a layout
--- legible in the dark, so they are deliberate rather than decorative.
function Builders.Braziers(context: BuildContext, spec: any)
	local count = spec.count or 4
	local radius = spec.radius or 18

	for index = 1, count do
		local angle = (index / count) * math.pi * 2 + 0.4
		local position = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)

		PartFactory.Part({
			Name = "BrazierStand",
			Size = Vector3.new(1.2, 4, 1.2),
			Color = context.palette.trim,
			Material = Enum.Material.Metal,
			CFrame = place(context, position + Vector3.new(0, 2, 0)),
			Parent = context.model,
		})

		local bowl = PartFactory.Decor({
			Name = "BrazierFlame",
			Size = Vector3.new(2.2, 1.4, 2.2),
			Color = context.palette.accent,
			Material = Enum.Material.Neon,
			CFrame = place(context, position + Vector3.new(0, 4.4, 0)),
			Parent = context.model,
		})
		PartFactory.PointLight(bowl, context.palette.accent, 2.2 * context.lightScale, 42)
	end
end

--- Alternating half-walls. Forces the fight into short, awkward spaces.
function Builders.Baffles(context: BuildContext, spec: any)
	local count = spec.count or 6
	local size = spec.size or Vector3.new(20, 10, 3)
	local base = spec.offset or Vector3.new(0, 5, 0)
	local spacing = 20

	for index = 1, count do
		local side = if index % 2 == 0 then 1 else -1
		local z = (index - (count + 1) / 2) * spacing
		PartFactory.Part({
			Name = "Baffle",
			Size = size,
			Color = shade(context.palette.stone, 0.9),
			Material = Enum.Material.Slate,
			CFrame = place(context, base + Vector3.new(side * 7, 0, z)),
			Parent = context.model,
		})
	end
end

--------------------------------------------------------------------------------
-- Region dressing
--------------------------------------------------------------------------------

--- Region hazards that cover the whole floor. Visual plus a gameplay attribute
--- the movement code reads.
local function applyRegionHazard(context: BuildContext, region: any, footprint: Vector3)
	local hazard = region.hazard
	if not hazard then
		return
	end

	if hazard.kind == "ShallowWater" then
		local water = PartFactory.Decor({
			Name = "HazardWater",
			Size = Vector3.new(footprint.X, hazard.depth, footprint.Z),
			Color = region.palette.accent,
			Material = Enum.Material.Glass,
			Transparency = 0.65,
			CFrame = place(context, Vector3.new(0, hazard.depth * 0.5 - 0.4, 0)),
			Parent = context.model,
		})
		water:SetAttribute("Hazard", hazard.kind)
	elseif hazard.kind == "EmberFloor" then
		for _ = 1, hazard.patchCount do
			local position = context.rng:PointInDisc(math.max(footprint.X, footprint.Z) * 0.42)
			local patch = PartFactory.Decor({
				Name = "HazardEmber",
				Size = Vector3.new(hazard.patchRadius * 2, 0.3, hazard.patchRadius * 2),
				Shape = Enum.PartType.Cylinder,
				Color = region.palette.accent,
				Material = Enum.Material.Neon,
				Transparency = 0.55,
				CFrame = place(context, position) * CFrame.Angles(0, 0, math.rad(90)),
				Parent = context.model,
			})
			patch:SetAttribute("Hazard", hazard.kind)
			-- Phase offset so patches flare out of sync with each other.
			patch:SetAttribute("CycleOffset", context.rng:Float(0, hazard.cycleTime))
		end
	elseif hazard.kind == "SlickFloor" then
		local ice = PartFactory.Decor({
			Name = "HazardIce",
			Size = Vector3.new(footprint.X, 0.3, footprint.Z),
			Color = region.palette.accent,
			Material = Enum.Material.Ice,
			Transparency = 0.5,
			Reflectance = 0.3,
			CFrame = place(context, Vector3.new(0, 0.2, 0)),
			Parent = context.model,
		})
		ice:SetAttribute("Hazard", hazard.kind)
		ice:SetAttribute("Friction", hazard.friction)
	end
end

--------------------------------------------------------------------------------
-- Region lighting
--
-- A region's palette does half the work of making it feel different; the light
-- does the other half. The Sunken March is a blue pre-dawn with heavy fog, the
-- Cinder Reach is a low orange dusk, the Rimefast Sanctum is flat and far too
-- bright. Applied on entering a run and restored on returning to Emberhold.
--------------------------------------------------------------------------------

local Lighting = game:GetService("Lighting")

local HUB_LIGHTING = {
	ambient = Color3.fromRGB(33, 30, 40),
	fogColor = Color3.fromRGB(23, 20, 30),
	fogEnd = 480,
	brightness = 2,
	clockTime = 17.5,
}

--- Eases Lighting toward a region's mood. Tweened rather than set, so the
--- transition between rooms and back to the hub is not a hard cut.
local function applyLighting(spec: any)
	local TweenService = game:GetService("TweenService")
	local info = TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	TweenService:Create(Lighting, info, {
		Ambient = spec.ambient,
		OutdoorAmbient = spec.ambient,
		FogColor = spec.fogColor,
		FogEnd = spec.fogEnd,
		Brightness = spec.brightness,
		ClockTime = spec.clockTime,
	}):Play()
end

function RoomBuilder.ApplyRegionLighting(region: any)
	if region and region.lighting then
		applyLighting(region.lighting)
	end
end

function RoomBuilder.ApplyHubLighting()
	applyLighting(HUB_LIGHTING)
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

function RoomBuilder.Build(layoutId: string, region: any, origin: CFrame, rng: any, parent: Instance): BuiltRoom?
	local layout = RoomConfig.Get(layoutId)
	if not layout then
		warn(("[RoomBuilder] unknown layout %q"):format(layoutId))
		return nil
	end

	local model = Instance.new("Model")
	model.Name = "Room_" .. layoutId

	local context: BuildContext = {
		model = model,
		origin = origin,
		palette = region.palette,
		rng = rng or Rng.new(),
		arenaParts = {},
		lightScale = layout.lightScale or 1,
	}

	for _, spec in layout.geometry do
		local builder = Builders[spec.kind]
		if builder then
			local ok, err = pcall(builder, context, spec)
			if not ok then
				warn(("[RoomBuilder] %s/%s failed: %s"):format(layoutId, spec.kind, tostring(err)))
			end
		else
			warn(("[RoomBuilder] unknown geometry kind %q in %s"):format(tostring(spec.kind), layoutId))
		end
	end

	applyRegionHazard(context, region, layout.footprint)

	model.Parent = parent
	PartFactory.SetCollisionGroup(model, GameConfig.Collision.Debris)

	-- Rooms are static. Anchoring everything is the single biggest performance
	-- decision in this file.
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end

	local maid = Maid.new()
	maid:Add(model)

	local function toWorld(offset: Vector3): Vector3
		return (origin * CFrame.new(offset)).Position
	end

	local spawnPoints = {}
	for _, point in layout.spawnPoints do
		table.insert(spawnPoints, point)
	end

	local exits = {}
	for _, exit in layout.exits do
		table.insert(exits, exit)
	end

	return {
		id = layoutId,
		layout = layout,
		model = model,
		maid = maid,
		origin = origin,
		spawnPoints = spawnPoints,
		featureAnchor = layout.featureAnchor,
		secondaryAnchors = layout.secondaryAnchors or {},
		entrance = layout.entrance,
		exits = exits,
		arenaParts = context.arenaParts,
	}
end

--- World position of a room-local offset.
function RoomBuilder.ToWorld(room: BuiltRoom, offset: Vector3): Vector3
	return (room.origin * CFrame.new(offset)).Position
end

function RoomBuilder.Init(services: any)
	registry = services
end

RoomBuilder.Builders = Builders

return RoomBuilder
