--!strict
--[[
	Spring — critically-dampable spring for camera and UI motion.

	Used for camera follow, FOV kicks and recoil. Springs beat tweens here because
	a new impulse can arrive mid-motion (three hits in a combo) and the spring just
	absorbs it instead of restarting an animation.

	Works on any type that supports +, - and scalar *: numbers, Vector3, Vector2.
]]

local Spring = {}
Spring.__index = Spring

export type Class<T> = typeof(setmetatable({}, Spring))

function Spring.new<T>(initial: T & any, speed: number?, damper: number?)
	return setmetatable({
		Position = initial,
		Velocity = initial * 0,
		Target = initial,
		Speed = speed or 12,
		Damper = damper or 1,
	}, Spring)
end

function Spring:Impulse(velocity: any)
	self.Velocity += velocity
end

function Spring:Reset(value: any)
	self.Position = value
	self.Target = value
	self.Velocity = value * 0
end

--[[
	Semi-implicit Euler. Subdivided when dt is large so a frame hitch cannot make a
	stiff spring explode -- important because Speed goes up to ~40 for hit reactions.
]]
function Spring:Update(deltaTime: number): any
	local steps = math.clamp(math.ceil(deltaTime / (1 / 90)), 1, 8)
	local step = deltaTime / steps

	for _ = 1, steps do
		local displacement = self.Position - self.Target
		local acceleration = -self.Speed * self.Speed * displacement
			- 2 * self.Speed * self.Damper * self.Velocity
		self.Velocity += acceleration * step
		self.Position += self.Velocity * step
	end

	return self.Position
end

return Spring
