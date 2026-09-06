--!strict
--[[
	RigBuilder — builds character rigs from a table description, at runtime.

	Nothing in this project ships as an uploaded model. Enemies, bosses and NPCs
	are all assembled here from primitives so that a silhouette is a diff you can
	read, not a binary blob. The layout is classic R6 (six parts, six Motor6Ds)
	because it is the cheapest rig that still has enough joints for the
	procedural animator to sell a swing, a stagger and a death.

	Every joint records its rest pose in a `BaseC0` attribute. ProceduralAnimator
	composes its poses against that value, so a rig built at 1.8x scale animates
	correctly without the animator knowing anything about scale.
]]

local PartFactory = require(script.Parent.PartFactory)

local RigBuilder = {}

local HALF_PI = math.pi / 2

--- Canonical R6 joint table, expressed at scale 1. Offsets are scaled on build.
local JOINTS = {
	{
		name = "RootJoint",
		part0 = "HumanoidRootPart",
		part1 = "Torso",
		c0 = CFrame.new(0, 0, 0) * CFrame.Angles(-HALF_PI, 0, math.pi),
		c1 = CFrame.new(0, 0, 0) * CFrame.Angles(-HALF_PI, 0, math.pi),
	},
	{
		name = "Neck",
		part0 = "Torso",
		part1 = "Head",
		c0 = CFrame.new(0, 1, 0) * CFrame.Angles(-HALF_PI, 0, math.pi),
		c1 = CFrame.new(0, -0.5, 0) * CFrame.Angles(-HALF_PI, 0, math.pi),
	},
	{
		name = "RightShoulder",
		part0 = "Torso",
		part1 = "RightArm",
		c0 = CFrame.new(1, 0.5, 0) * CFrame.Angles(0, HALF_PI, 0),
		c1 = CFrame.new(-0.5, 0.5, 0) * CFrame.Angles(0, HALF_PI, 0),
	},
	{
		name = "LeftShoulder",
		part0 = "Torso",
		part1 = "LeftArm",
		c0 = CFrame.new(-1, 0.5, 0) * CFrame.Angles(0, -HALF_PI, 0),
		c1 = CFrame.new(0.5, 0.5, 0) * CFrame.Angles(0, -HALF_PI, 0),
	},
	{
		name = "RightHip",
		part0 = "Torso",
		part1 = "RightLeg",
		c0 = CFrame.new(1, -1, 0) * CFrame.Angles(0, HALF_PI, 0),
		c1 = CFrame.new(0.5, 1, 0) * CFrame.Angles(0, HALF_PI, 0),
	},
	{
		name = "LeftHip",
		part0 = "Torso",
		part1 = "LeftLeg",
		c0 = CFrame.new(-1, -1, 0) * CFrame.Angles(0, -HALF_PI, 0),
		c1 = CFrame.new(-0.5, 1, 0) * CFrame.Angles(0, -HALF_PI, 0),
	},
}

local PART_SIZES = {
	HumanoidRootPart = Vector3.new(2, 2, 1),
	Torso = Vector3.new(2, 2, 1),
	Head = Vector3.new(1.6, 1.4, 1.6),
	RightArm = Vector3.new(1, 2, 1),
	LeftArm = Vector3.new(1, 2, 1),
	RightLeg = Vector3.new(1, 2, 1),
	LeftLeg = Vector3.new(1, 2, 1),
}

export type Palette = {
	primary: Color3,
	secondary: Color3,
	accent: Color3,
	eye: Color3?,
}

export type RigSpec = {
	name: string,
	scale: number?,
	palette: Palette,
	silhouette: { string }?, -- decorative flags: "horns", "pauldrons", "cloak", "crest", "tatters", "halo"
	maxHealth: number?,
	walkSpeed: number?,
	material: Enum.Material?,
	glow: boolean?,
}

local function scaledCFrame(cframe: CFrame, scale: number): CFrame
	local position = cframe.Position * scale
	return CFrame.new(position) * (cframe - cframe.Position)
end

--[[
	Decorative silhouette pieces. These exist purely so a player can tell an
	Assassin from a Brute in one glance at 40 studs -- readability is a mechanic
	in a game where you dodge on reaction.
]]
local Silhouette = {}

function Silhouette.horns(rig, parts, palette, scale)
	for _, side in { -1, 1 } do
		local horn = PartFactory.Decor({
			Name = "Horn",
			Size = Vector3.new(0.24, 1.5, 0.24) * scale,
			Color = palette.accent,
			Material = Enum.Material.Slate,
			CFrame = parts.Head.CFrame
				* CFrame.new(0.45 * side * scale, 0.7 * scale, 0)
				* CFrame.Angles(math.rad(-18), 0, math.rad(24 * side)),
			Parent = rig,
		})
		PartFactory.Weld(parts.Head, horn)
	end
end

function Silhouette.pauldrons(rig, parts, palette, scale)
	for _, entry in { { part = parts.RightArm, side = 1 }, { part = parts.LeftArm, side = -1 } } do
		local plate = PartFactory.Decor({
			Name = "Pauldron",
			Size = Vector3.new(1.35, 0.6, 1.35) * scale,
			Color = palette.secondary,
			Material = Enum.Material.Metal,
			CFrame = entry.part.CFrame * CFrame.new(0, 0.85 * scale, 0),
			Parent = rig,
		})
		PartFactory.Weld(entry.part, plate)
	end
end

function Silhouette.cloak(rig, parts, palette, scale)
	local cloak = PartFactory.Decor({
		Name = "Cloak",
		Size = Vector3.new(2.1, 2.6, 0.2) * scale,
		Color = palette.secondary,
		Material = Enum.Material.Fabric,
		CFrame = parts.Torso.CFrame * CFrame.new(0, -0.35 * scale, 0.62 * scale) * CFrame.Angles(math.rad(6), 0, 0),
		Parent = rig,
	})
	PartFactory.Weld(parts.Torso, cloak)
end

function Silhouette.tatters(rig, parts, palette, scale)
	for index = 1, 5 do
		local strip = PartFactory.Decor({
			Name = "Tatter",
			Size = Vector3.new(0.32, 1.1 + (index % 3) * 0.4, 0.12) * scale,
			Color = palette.secondary,
			Material = Enum.Material.Fabric,
			Transparency = 0.15,
			CFrame = parts.Torso.CFrame
				* CFrame.new((-0.8 + index * 0.4) * scale, -1.3 * scale, 0.5 * scale),
			Parent = rig,
		})
		PartFactory.Weld(parts.Torso, strip)
	end
end

function Silhouette.crest(rig, parts, palette, scale)
	local crest = PartFactory.Decor({
		Name = "Crest",
		Size = Vector3.new(0.16, 0.9, 1.5) * scale,
		Color = palette.accent,
		Material = Enum.Material.Neon,
		CFrame = parts.Head.CFrame * CFrame.new(0, 0.85 * scale, -0.1 * scale),
		Parent = rig,
	})
	PartFactory.Weld(parts.Head, crest)
end

function Silhouette.halo(rig, parts, palette, scale)
	local halo = PartFactory.Decor({
		Name = "Halo",
		Size = Vector3.new(2.4, 0.14, 2.4) * scale,
		Shape = Enum.PartType.Cylinder,
		Color = palette.accent,
		Material = Enum.Material.Neon,
		Transparency = 0.25,
		CFrame = parts.Head.CFrame * CFrame.new(0, 1.4 * scale, 0) * CFrame.Angles(0, 0, math.rad(90)),
		Parent = rig,
	})
	PartFactory.Weld(parts.Head, halo)
end

--[[
	Builds a complete, anchored-free rig. The caller is responsible for parenting
	it into the world and for unanchoring the root (EnemyService does both once
	the spawn position is validated).
]]
function RigBuilder.Build(spec: RigSpec): Model
	local scale = spec.scale or 1
	local palette = spec.palette
	local material = spec.material or Enum.Material.Slate

	local rig = Instance.new("Model")
	rig.Name = spec.name

	local parts: { [string]: BasePart } = {}
	for partName, baseSize in PART_SIZES do
		local isRoot = partName == "HumanoidRootPart"
		local color = palette.primary
		if partName == "Head" then
			color = palette.secondary
		elseif partName == "RightLeg" or partName == "LeftLeg" then
			color = palette.secondary
		end

		local part = PartFactory.Part({
			Name = partName,
			Size = baseSize * scale,
			Color = color,
			Material = material,
			Anchored = false,
			CanCollide = not isRoot and partName ~= "Head",
			Transparency = isRoot and 1 or 0,
			CanQuery = not isRoot,
			CFrame = CFrame.identity,
			Parent = rig,
		})
		part.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.3, 0.5, 1, 1)
		parts[partName] = part
	end

	rig.PrimaryPart = parts.HumanoidRootPart

	-- Seat the parts at their rest poses before jointing so welds capture sane offsets.
	local rootCFrame = CFrame.identity
	parts.HumanoidRootPart.CFrame = rootCFrame
	parts.Torso.CFrame = rootCFrame
	parts.Head.CFrame = rootCFrame * CFrame.new(0, 1.5 * scale, 0)
	parts.RightArm.CFrame = rootCFrame * CFrame.new(1.5 * scale, 0, 0)
	parts.LeftArm.CFrame = rootCFrame * CFrame.new(-1.5 * scale, 0, 0)
	parts.RightLeg.CFrame = rootCFrame * CFrame.new(0.5 * scale, -2 * scale, 0)
	parts.LeftLeg.CFrame = rootCFrame * CFrame.new(-0.5 * scale, -2 * scale, 0)

	for _, joint in JOINTS do
		local c0 = scaledCFrame(joint.c0, scale)
		local c1 = scaledCFrame(joint.c1, scale)
		local motor = PartFactory.Motor(parts[joint.part0], parts[joint.part1], c0, c1)
		motor.Name = joint.name
		-- The animator poses relative to this; it never has to know the rig's scale.
		motor:SetAttribute("BaseC0", c0)
	end

	-- Glowing eyes read as "this thing is alive and looking at you" at any distance.
	local eyeColor = palette.eye or palette.accent
	for _, side in { -1, 1 } do
		local eye = PartFactory.Decor({
			Name = "Eye",
			Size = Vector3.new(0.28, 0.16, 0.1) * scale,
			Color = eyeColor,
			Material = Enum.Material.Neon,
			CFrame = parts.Head.CFrame * CFrame.new(0.32 * side * scale, 0.1 * scale, -0.8 * scale),
			Parent = rig,
		})
		PartFactory.Weld(parts.Head, eye)
	end

	for _, flag in spec.silhouette or {} do
		local builder = Silhouette[flag]
		if builder then
			builder(rig, parts, palette, scale)
		end
	end

	if spec.glow then
		PartFactory.PointLight(parts.Torso, palette.accent, 1.4, 14 * scale)
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R6
	humanoid.MaxHealth = spec.maxHealth or 100
	humanoid.Health = humanoid.MaxHealth
	humanoid.WalkSpeed = spec.walkSpeed or 12
	humanoid.HipHeight = 2 * scale
	humanoid.AutoRotate = false -- the AI steers deliberately; auto-rotate fights telegraphs
	humanoid.BreakJointsOnDeath = false
	humanoid.RequiresNeck = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.Parent = rig

	-- Anchor point for the world-space health bar / status icons.
	PartFactory.Attachment(parts.Head, CFrame.new(0, 1.6 * scale, 0), "OverheadAnchor")
	-- Where telegraph decals and impact VFX get parented.
	PartFactory.Attachment(parts.Torso, CFrame.new(0, 0, 0), "CoreAnchor")
	PartFactory.Attachment(parts.RightArm, CFrame.new(0, -1 * scale, 0), "WeaponGrip")

	rig:SetAttribute("RigScale", scale)
	return rig
end

--- Returns the named Motor6D on any rig (built here, or a live player character).
function RigBuilder.GetJoint(character: Model, jointName: string): Motor6D?
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("Motor6D") and descendant.Name == jointName then
			return descendant
		end
	end
	return nil
end

--[[
	Maps logical joint names onto whichever rig the character actually uses.
	Three cases exist in this game: rigs we built here (R6 layout, no spaces in
	joint names), stock Roblox R6 characters (spaces), and R15 player characters.
	The animator only ever speaks in logical names.
]]
function RigBuilder.ResolveJointNames(character: Model): { [string]: string }
	if character:GetAttribute("RigScale") ~= nil then
		-- Built by RigBuilder.Build.
		return {
			Root = "RootJoint",
			Waist = "RootJoint",
			Neck = "Neck",
			RightShoulder = "RightShoulder",
			LeftShoulder = "LeftShoulder",
			RightHip = "RightHip",
			LeftHip = "LeftHip",
		}
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.RigType == Enum.HumanoidRigType.R15 then
		return {
			Root = "Root",
			Waist = "Waist",
			Neck = "Neck",
			RightShoulder = "RightShoulder",
			LeftShoulder = "LeftShoulder",
			RightHip = "RightHip",
			LeftHip = "LeftHip",
		}
	end

	-- Stock R6.
	return {
		Root = "RootJoint",
		Waist = "RootJoint",
		Neck = "Neck",
		RightShoulder = "Right Shoulder",
		LeftShoulder = "Left Shoulder",
		RightHip = "Right Hip",
		LeftHip = "Left Hip",
	}
end

return RigBuilder
