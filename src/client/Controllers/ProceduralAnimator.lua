--!strict
--[[
	ProceduralAnimator — plays PoseLibrary clips by driving Motor6D C0 offsets.

	This is what stands in for Roblox's animation system in a project that ships no
	uploaded animations. It is a small, complete animator: clips, blending, layers,
	speed, and a rest pose to fall back to.

	HOW IT WORKS
	Each joint has a rest C0, recorded by RigBuilder (or read once on first touch
	for player rigs). A clip is a list of keyframes giving Euler offsets from that
	rest pose. Playing a clip means, each frame: find the two keyframes we are
	between, interpolate, compose the result onto the rest pose, and write it.

	TWO LAYERS
	Base holds locomotion -- idle, walk, run, fall -- and loops. Action holds
	everything else and always wins while it is playing. A joint the action clip
	does not mention falls back to the base layer's value for that joint, which is
	why a swing clip can specify only the arms and still look right while running.

	BLENDING
	Both layers keep a short cross-fade from whatever they were playing. Snapping
	between poses is the single most obvious tell that animation is procedural;
	80ms of blend removes almost all of it.

	CULLING
	Rigs beyond AnimationCullDistance are skipped entirely. In a room with nine
	enemies this is the difference between the animator being free and being
	something you can see in a microprofile.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local GameConfig = require(Shared.Config.GameConfig)
local PoseLibrary = require(Shared.Config.PoseLibrary)
local RigBuilder = require(Shared.Util.RigBuilder)

local ProceduralAnimator = {}

local player = Players.LocalPlayer

type Layer = {
	clip: any?,
	clipName: string?,
	time: number,
	speed: number,
	-- Cross-fade progress out of the previous pose, 0..1.
	blend: number,
	blendSpeed: number,
	-- Pose held at the moment this layer's clip started, for the cross-fade.
	fromPose: { [string]: CFrame },
	finished: boolean,
}

type Rig = {
	character: Model,
	joints: { [string]: Motor6D },
	restPoses: { [string]: CFrame },
	base: Layer,
	action: Layer,
	-- Reused each frame to avoid churning tables in the hot path.
	scratch: { [string]: CFrame },
	lastPose: { [string]: CFrame },
	-- Set by Freeze; clip time does not advance until this passes.
	frozenUntil: number?,
}

local rigs: { [Model]: Rig } = {}

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

local function newLayer(): Layer
	return {
		clip = nil,
		clipName = nil,
		time = 0,
		speed = 1,
		blend = 1,
		blendSpeed = 12,
		fromPose = {},
		finished = true,
	}
end

--[[
	Binds a character. Resolves logical joint names (Root, Neck, RightShoulder...)
	onto whatever the rig actually calls them, and records each joint's rest pose.

	Rest poses come from the `BaseC0` attribute when RigBuilder made the rig, and
	from the joint's current C0 otherwise -- which is correct for a player
	character bound on spawn, before anything has posed it.
]]
function ProceduralAnimator.Bind(character: Model): Rig?
	local existing = rigs[character]
	if existing then
		return existing
	end

	local names = RigBuilder.ResolveJointNames(character)
	local joints: { [string]: Motor6D } = {}
	local restPoses: { [string]: CFrame } = {}

	for logical, actual in names do
		local motor = RigBuilder.GetJoint(character, actual)
		if motor then
			joints[logical] = motor
			local recorded = motor:GetAttribute("BaseC0")
			if typeof(recorded) == "CFrame" then
				restPoses[logical] = recorded
			else
				restPoses[logical] = motor.C0
				motor:SetAttribute("BaseC0", motor.C0)
			end
		end
	end

	if next(joints) == nil then
		return nil
	end

	local rig: Rig = {
		character = character,
		joints = joints,
		restPoses = restPoses,
		base = newLayer(),
		action = newLayer(),
		scratch = {},
		lastPose = {},
		frozenUntil = 0,
	}
	rigs[character] = rig

	character.Destroying:Connect(function()
		rigs[character] = nil
	end)

	return rig
end

function ProceduralAnimator.Unbind(character: Model)
	rigs[character] = nil
end

--------------------------------------------------------------------------------
-- Playback
--------------------------------------------------------------------------------

local function startLayer(rig: Rig, layer: Layer, clipName: string, speed: number)
	local clip = PoseLibrary.Get(clipName)
	if not clip then
		return
	end

	-- Cross-fade starts from wherever the rig currently is, not from the rest pose.
	layer.fromPose = table.clone(rig.lastPose)
	layer.clip = clip
	layer.clipName = clipName
	layer.time = 0
	layer.speed = speed
	layer.blend = 0
	layer.blendSpeed = 1 / math.max(0.02, clip.blendIn or 0.1)
	layer.finished = false
end

--- Plays a one-shot action clip. Interrupts whatever action was playing.
function ProceduralAnimator.PlayAction(character: Model, clipName: string, speed: number?)
	local rig = rigs[character] or ProceduralAnimator.Bind(character)
	if not rig then
		return
	end
	startLayer(rig, rig.action, clipName, speed or 1)
end

--- Sets the looping base clip. A no-op if that clip is already playing, so this
--- can be called every frame from locomotion logic without restarting anything.
function ProceduralAnimator.SetBase(character: Model, clipName: string, speed: number?)
	local rig = rigs[character] or ProceduralAnimator.Bind(character)
	if not rig then
		return
	end
	if rig.base.clipName == clipName then
		rig.base.speed = speed or 1
		return
	end
	startLayer(rig, rig.base, clipName, speed or 1)
end

function ProceduralAnimator.StopAction(character: Model)
	local rig = rigs[character]
	if rig then
		rig.action.finished = true
		rig.action.clip = nil
		rig.action.clipName = nil
	end
end

--[[
	Hit stop. Holds a rig's current pose for a few milliseconds on a landed hit.

	Implemented as a pause on clip time rather than a pause on the whole update, so
	the character stays where it is and the camera keeps moving. Freezing the
	camera too reads as a frame drop; freezing only the swing reads as impact.

	Overlapping requests take the longest one rather than summing, so a spin
	through six enemies does not lock the rig for a third of a second.
]]
function ProceduralAnimator.Freeze(character: Model, duration: number)
	local rig = rigs[character]
	if not rig or duration <= 0 then
		return
	end
	rig.frozenUntil = math.max(rig.frozenUntil or 0, os.clock() + math.min(duration, 0.2))
end

function ProceduralAnimator.IsPlayingAction(character: Model): boolean
	local rig = rigs[character]
	return rig ~= nil and rig.action.clip ~= nil and not rig.action.finished
end

--------------------------------------------------------------------------------
-- Evaluation
--------------------------------------------------------------------------------

local function eulerCFrame(pose: any): CFrame
	local rotation = pose.rot
	local cframe = CFrame.Angles(math.rad(rotation[1]), math.rad(rotation[2]), math.rad(rotation[3]))
	local position = pose.pos
	if position then
		cframe = CFrame.new(position[1], position[2], position[3]) * cframe
	end
	return cframe
end

--[[
	Samples a clip at normalised time `alpha` into `out`.

	Keyframes are sparse per joint: a clip may mention RightShoulder at t=0 and
	t=0.5 only. Rather than requiring every keyframe to list every joint, we scan
	for the surrounding keyframes *that mention this joint* and interpolate those.
	That is what lets a swing clip be five lines instead of fifty.
]]
local function sampleClip(clip: any, alpha: number, out: { [string]: CFrame })
	local keys = clip.keys

	-- Collect the joints this clip touches at all.
	for _, key in keys do
		for jointName in key.joints do
			if out[jointName] == nil then
				out[jointName] = CFrame.identity
			end
		end
	end

	for jointName in out do
		local beforeKey, afterKey = nil, nil
		for _, key in keys do
			if key.joints[jointName] then
				if key.t <= alpha then
					beforeKey = key
				elseif not afterKey then
					afterKey = key
				end
			end
		end

		local pose: CFrame
		if beforeKey and afterKey then
			local span = afterKey.t - beforeKey.t
			local localAlpha = if span > 0 then (alpha - beforeKey.t) / span else 0
			-- Smoothstep: linear interpolation between poses reads as robotic, and
			-- easing every segment is most of what sells these as animations.
			localAlpha = localAlpha * localAlpha * (3 - 2 * localAlpha)
			pose = eulerCFrame(beforeKey.joints[jointName])
				:Lerp(eulerCFrame(afterKey.joints[jointName]), localAlpha)
		elseif beforeKey then
			pose = eulerCFrame(beforeKey.joints[jointName])
		elseif afterKey then
			pose = eulerCFrame(afterKey.joints[jointName])
		else
			pose = CFrame.identity
		end

		out[jointName] = pose
	end
end

local function advanceLayer(layer: Layer, deltaTime: number)
	if not layer.clip then
		return
	end

	layer.time += deltaTime * layer.speed
	layer.blend = math.min(1, layer.blend + deltaTime * layer.blendSpeed)

	local duration = layer.clip.duration
	if layer.clip.loop then
		layer.time %= duration
	elseif layer.time >= duration then
		layer.time = duration
		layer.finished = true
	end
end

--------------------------------------------------------------------------------
-- Update
--------------------------------------------------------------------------------

local function updateRig(rig: Rig, deltaTime: number)
	-- Hit stop: hold the pose, but keep evaluating so the write still happens.
	if rig.frozenUntil and os.clock() < rig.frozenUntil then
		deltaTime = 0
	end

	advanceLayer(rig.base, deltaTime)
	advanceLayer(rig.action, deltaTime)

	local pose: { [string]: CFrame } = {}

	-- Base layer.
	if rig.base.clip then
		local alpha = rig.base.time / rig.base.clip.duration
		local sampled = {}
		sampleClip(rig.base.clip, math.clamp(alpha, 0, 1), sampled)
		for jointName, value in sampled do
			local from = rig.base.fromPose[jointName] or CFrame.identity
			pose[jointName] = from:Lerp(value, rig.base.blend)
		end
	end

	-- Action layer wins wherever it has an opinion.
	if rig.action.clip and not rig.action.finished then
		local alpha = rig.action.time / rig.action.clip.duration
		local sampled = {}
		sampleClip(rig.action.clip, math.clamp(alpha, 0, 1), sampled)
		for jointName, value in sampled do
			local from = rig.action.fromPose[jointName] or pose[jointName] or CFrame.identity
			pose[jointName] = from:Lerp(value, rig.action.blend)
		end
	elseif rig.action.clip and rig.action.finished then
		-- Ease back out of a finished action rather than dropping it instantly.
		local sampled = {}
		sampleClip(rig.action.clip, 1, sampled)
		local decay = math.max(0, 1 - deltaTime * 6)
		local stillHolding = false
		for jointName, value in sampled do
			local blended = (pose[jointName] or CFrame.identity):Lerp(value, decay)
			pose[jointName] = blended
			if decay > 0.02 then
				stillHolding = true
			end
		end
		if not stillHolding then
			rig.action.clip = nil
			rig.action.clipName = nil
		end
		rig.action.blend = decay
	end

	-- Write to the joints.
	for jointName, offset in pose do
		local motor = rig.joints[jointName]
		local rest = rig.restPoses[jointName]
		if motor and rest and motor.Parent then
			motor.C0 = rest * offset
		end
	end

	-- Any joint the pose stopped mentioning returns to rest.
	for jointName, motor in rig.joints do
		if pose[jointName] == nil and rig.lastPose[jointName] ~= nil then
			local rest = rig.restPoses[jointName]
			if rest and motor.Parent then
				motor.C0 = motor.C0:Lerp(rest, math.clamp(deltaTime * 8, 0, 1))
			end
		end
	end

	rig.lastPose = pose
end

function ProceduralAnimator.Update(deltaTime: number)
	local camera = workspace.CurrentCamera
	local viewPosition = camera and camera.CFrame.Position or Vector3.zero
	local cullSquared = GameConfig.Performance.AnimationCullDistance ^ 2

	for character, rig in rigs do
		if not character.Parent then
			rigs[character] = nil
			continue
		end

		local root = character.PrimaryPart or character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			if (root.Position - viewPosition).Magnitude ^ 2 > cullSquared then
				continue
			end
		end

		local ok, err = pcall(updateRig, rig, deltaTime)
		if not ok and GameConfig.Debug.Enabled then
			warn(("[ProceduralAnimator] %s: %s"):format(character.Name, tostring(err)))
		end
	end
end

function ProceduralAnimator.Init() end

return ProceduralAnimator
