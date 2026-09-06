--!strict
--[[
	Hitbox — spatial queries for attacks.

	Shared between server and client. The server uses it to decide what got hit;
	the client uses the identical code to draw debug volumes, which means what you
	see in the debug view is exactly what the server tested, not an approximation
	of it.

	THREE SHAPES, ON PURPOSE
	  Arc     a cone in front of the attacker. Most melee. Cheap and readable.
	  Box     a rectangular volume. Thrusts, dashes, anything that pierces.
	  Sphere  radial. Slams, spins, explosions.

	That is enough to express every attack in the game, and a small shape set means
	the player learns to read hitboxes rather than memorising them.

	QUERIES RETURN CHARACTERS, NOT PARTS
	A rig has ten parts. Without deduplication a single swing would report ten hits
	on one enemy. Everything here folds parts up to their owning model and returns
	each character once, along with the part that was actually struck (used for
	boss weak points and for placing the impact effect).
]]

local GameConfig = require(script.Parent.Parent.Config.GameConfig)

local Hitbox = {}

export type Target = {
	character: Model,
	humanoid: Humanoid,
	part: BasePart,
	-- Distance from the attack origin to the struck part.
	distance: number,
	-- Signed angle in degrees between the attacker's facing and the target.
	angle: number,
}

export type Query = {
	shape: string,
	range: number,
	angle: number?,
	width: number?,
	height: number?,
	offset: Vector3?,
	maxTargets: number?,
	pierce: boolean?,
}

local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude
overlapParams.MaxParts = 200

--- Walks up to the Model that owns `part`, if it is a character.
local function characterOf(part: BasePart): (Model?, Humanoid?)
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			return model, humanoid
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil, nil
end

--[[
	Runs the query and returns each distinct character exactly once.

	`origin` is the attacker's root CFrame: -Z is forward, which matches Roblox's
	convention and every offset in the config files.
]]
function Hitbox.Query(origin: CFrame, query: Query, ignore: { Instance }): { Target }
	local offset = query.offset or Vector3.zero
	local centre = origin * CFrame.new(offset)

	overlapParams.FilterDescendantsInstances = ignore

	local parts: { BasePart }
	if query.shape == "Sphere" or query.shape == "Arc" then
		-- Both start as a sphere; the Arc is then filtered down by angle. This is
		-- cheaper than building a cone volume and gives identical results.
		parts = workspace:GetPartBoundsInRadius(centre.Position, query.range, overlapParams)
	elseif query.shape == "Box" then
		local size = Vector3.new(
			(query.width or 2) * 2,
			(query.height or 5),
			query.range
		)
		parts = workspace:GetPartBoundsInBox(centre, size, overlapParams)
	else
		return {}
	end

	local seen: { [Model]: boolean } = {}
	local targets: { Target } = {}
	local forward = origin.LookVector

	for _, part in parts do
		local character, humanoid = characterOf(part)
		if character and humanoid and not seen[character] and humanoid.Health > 0 then
			local toTarget = part.Position - origin.Position
			local flat = Vector3.new(toTarget.X, 0, toTarget.Z)
			local distance = toTarget.Magnitude

			-- Vertical reach: an attack should not hit something twenty studs above
			-- the attacker just because it was inside the radius.
			local heightLimit = (query.height or 6) * 0.5 + 2
			if math.abs(toTarget.Y) <= heightLimit then
				local angle = 0
				if flat.Magnitude > 0.05 then
					local flatForward = Vector3.new(forward.X, 0, forward.Z).Unit
					local dot = math.clamp(flatForward:Dot(flat.Unit), -1, 1)
					angle = math.deg(math.acos(dot))
				end

				local inside = true
				if query.shape == "Arc" then
					inside = angle <= (query.angle or 120) * 0.5
				end

				if inside then
					seen[character] = true
					table.insert(targets, {
						character = character,
						humanoid = humanoid,
						part = part,
						distance = distance,
						angle = angle,
					})
				end
			end
		end
	end

	-- Nearest first: when an attack is capped at N targets, it should hit the N
	-- things closest to the player, not an arbitrary N.
	table.sort(targets, function(a, b)
		return a.distance < b.distance
	end)

	local maxTargets = query.maxTargets or 6
	if not query.pierce and #targets > maxTargets then
		for index = #targets, maxTargets + 1, -1 do
			targets[index] = nil
		end
	end

	return targets
end

--[[
	Server-side validation of a hit the client is implicitly claiming by having
	asked for the attack. We do not trust the client's facing beyond a tolerance,
	because a client that can rotate freely mid-swing can hit things behind it.
]]
function Hitbox.ValidateFacing(serverFacing: Vector3, claimedFacing: Vector3): Vector3
	local a = Vector3.new(serverFacing.X, 0, serverFacing.Z)
	local b = Vector3.new(claimedFacing.X, 0, claimedFacing.Z)
	if a.Magnitude < 0.05 or b.Magnitude < 0.05 then
		return serverFacing
	end
	a, b = a.Unit, b.Unit

	local deviation = math.deg(math.acos(math.clamp(a:Dot(b), -1, 1)))
	if deviation <= GameConfig.Combat.MaxFacingDeviationDegrees then
		-- Within tolerance: honour the client, which keeps swings feeling responsive
		-- for players who turn as they attack.
		return b
	end

	-- Outside tolerance: clamp to the edge of what we will accept rather than
	-- rejecting the attack outright, so high-latency players are not punished.
	local axis = a:Cross(b)
	if axis.Magnitude < 1e-4 then
		return a
	end
	local clamped = CFrame.fromAxisAngle(axis.Unit, math.rad(GameConfig.Combat.MaxFacingDeviationDegrees))
		* a
	return Vector3.new(clamped.X, 0, clamped.Z).Unit
end

--- True when `target` is behind `attackerFacing` relative to `attackerPosition`.
--- Used by positional Graces and by backstab bonuses.
function Hitbox.IsBehind(attackerPosition: Vector3, targetCFrame: CFrame, threshold: number?): boolean
	local toAttacker = attackerPosition - targetCFrame.Position
	local flat = Vector3.new(toAttacker.X, 0, toAttacker.Z)
	if flat.Magnitude < 0.05 then
		return false
	end
	local targetForward = targetCFrame.LookVector
	local flatForward = Vector3.new(targetForward.X, 0, targetForward.Z)
	if flatForward.Magnitude < 0.05 then
		return false
	end
	local dot = flatForward.Unit:Dot(flat.Unit)
	-- dot < 0 means the attacker is on the far side of the target's facing.
	return dot < -(threshold or 0.25)
end

--- Debug volume matching what Query tested. Only ever called when the debug flag
--- is on; it deliberately shares the shape maths above.
function Hitbox.BuildDebugVolume(origin: CFrame, query: Query): BasePart
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 0.7
	part.Color = Color3.fromRGB(255, 80, 80)
	part.Material = Enum.Material.Neon
	part.Name = "DebugHitbox"

	local offset = query.offset or Vector3.zero
	if query.shape == "Box" then
		part.Size = Vector3.new((query.width or 2) * 2, query.height or 5, query.range)
		part.CFrame = origin * CFrame.new(offset)
	else
		part.Shape = Enum.PartType.Ball
		part.Size = Vector3.one * query.range * 2
		part.CFrame = origin * CFrame.new(offset)
	end

	return part
end

return Hitbox
