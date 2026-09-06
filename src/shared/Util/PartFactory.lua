--!strict
--[[
	PartFactory — terse constructors for the geometry we build at runtime.

	Every room, weapon and enemy in this project is assembled from code rather than
	from uploaded .rbxm assets, so the whole game is reviewable as text and any
	contributor can change a room by editing a table. These helpers keep that
	readable.
]]

local PartFactory = {}

local DEFAULT_MATERIAL = Enum.Material.Slate

export type PartSpec = {
	Size: Vector3?,
	CFrame: CFrame?,
	Color: Color3?,
	Material: Enum.Material?,
	Transparency: number?,
	Anchored: boolean?,
	CanCollide: boolean?,
	CanQuery: boolean?,
	CanTouch: boolean?,
	Shape: Enum.PartType?,
	Name: string?,
	Reflectance: number?,
	CastShadow: boolean?,
	Parent: Instance?,
}

function PartFactory.Part(spec: PartSpec): Part
	local part = Instance.new("Part")
	part.Name = spec.Name or "Part"
	part.Size = spec.Size or Vector3.one
	part.CFrame = spec.CFrame or CFrame.identity
	part.Color = spec.Color or Color3.fromRGB(120, 120, 130)
	part.Material = spec.Material or DEFAULT_MATERIAL
	part.Transparency = spec.Transparency or 0
	part.Reflectance = spec.Reflectance or 0
	part.Anchored = if spec.Anchored == nil then true else spec.Anchored
	part.CanCollide = if spec.CanCollide == nil then true else spec.CanCollide
	part.CanQuery = if spec.CanQuery == nil then true else spec.CanQuery
	part.CanTouch = if spec.CanTouch == nil then false else spec.CanTouch
	part.CastShadow = if spec.CastShadow == nil then true else spec.CastShadow
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	if spec.Shape then
		part.Shape = spec.Shape
	end
	if spec.Parent then
		part.Parent = spec.Parent
	end
	return part
end

--- Purely decorative geometry: no collisions, no raycast hits, no touch events.
function PartFactory.Decor(spec: PartSpec): Part
	spec.CanCollide = false
	spec.CanQuery = false
	spec.CanTouch = false
	return PartFactory.Part(spec)
end

function PartFactory.Wedge(spec: PartSpec): WedgePart
	local wedge = Instance.new("WedgePart")
	wedge.Name = spec.Name or "Wedge"
	wedge.Size = spec.Size or Vector3.one
	wedge.CFrame = spec.CFrame or CFrame.identity
	wedge.Color = spec.Color or Color3.fromRGB(120, 120, 130)
	wedge.Material = spec.Material or DEFAULT_MATERIAL
	wedge.Anchored = if spec.Anchored == nil then true else spec.Anchored
	wedge.CanCollide = if spec.CanCollide == nil then true else spec.CanCollide
	wedge.Transparency = spec.Transparency or 0
	if spec.Parent then
		wedge.Parent = spec.Parent
	end
	return wedge
end

function PartFactory.Weld(a: BasePart, b: BasePart, parent: Instance?): WeldConstraint
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = a
	weld.Part1 = b
	weld.Parent = parent or a
	return weld
end

--- Rigid attach used for weapon-to-hand: keeps the exact relative offset.
function PartFactory.Motor(part0: BasePart, part1: BasePart, c0: CFrame?, c1: CFrame?): Motor6D
	local motor = Instance.new("Motor6D")
	motor.Part0 = part0
	motor.Part1 = part1
	motor.C0 = c0 or CFrame.identity
	motor.C1 = c1 or CFrame.identity
	motor.Parent = part0
	return motor
end

function PartFactory.Attachment(parent: BasePart, offset: CFrame?, name: string?): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = name or "Attachment"
	attachment.CFrame = offset or CFrame.identity
	attachment.Parent = parent
	return attachment
end

function PartFactory.PointLight(parent: BasePart, color: Color3, brightness: number, range: number): PointLight
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = brightness
	light.Range = range
	light.Shadows = false
	light.Parent = parent
	return light
end

--- Applies an outline-style highlight; used for lock-on and interactable prompts.
function PartFactory.Highlight(target: Instance, fill: Color3, outline: Color3, fillAlpha: number?): Highlight
	local highlight = Instance.new("Highlight")
	highlight.FillColor = fill
	highlight.OutlineColor = outline
	highlight.FillTransparency = fillAlpha or 0.85
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Adornee = target :: any
	return highlight
end

--- Sets the whole model non-collidable against players but still raycastable.
function PartFactory.SetCollisionGroup(container: Instance, groupName: string)
	for _, descendant in container:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = groupName
		end
	end
end

return PartFactory
