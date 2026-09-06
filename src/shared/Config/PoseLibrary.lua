--!strict
--[[
	PoseLibrary — every animation in the game, as keyframe data.

	This project has no uploaded animation assets. Instead the ProceduralAnimator
	drives Motor6D C0 offsets from the clips defined here. That buys three things
	that matter more than fidelity for a game like this:

	  1. A moveset is readable and diffable. Changing how Grudge's overhead lands
	     is a two-number edit, not a re-upload.
	  2. Timing is authoritative and shared. The server's hitbox windows and the
	     client's visible swing are driven off the same durations, so the moment
	     the blade looks like it connects is the moment it does.
	  3. It works on any rig -- R6, R15, or something RigBuilder invented -- since
	     poses are expressed as offsets from each joint's rest pose.

	AUTHORING
	Rotations are Euler degrees, applied XYZ, relative to the joint's rest pose.
	`t` is normalised time in [0, 1]. Positions are studs, also relative.
	If a clip omits a joint, the animator blends that joint back toward rest.

	Joint names are logical (see RigBuilder.ResolveJointNames), so `RightShoulder`
	means the right shoulder on whatever rig this is playing on.
]]

export type JointPose = { rot: { number }, pos: { number }? }
export type Keyframe = { t: number, joints: { [string]: JointPose } }
export type Clip = {
	duration: number,
	keys: { Keyframe },
	loop: boolean?,
	-- Fraction of duration spent easing in from whatever was playing before.
	blendIn: number?,
}

local PoseLibrary = {}

--- Authoring shorthand. `r` = rotation in degrees, `p` = optional position offset.
local function j(rx: number, ry: number, rz: number, px: number?, py: number?, pz: number?): JointPose
	local pose: JointPose = { rot = { rx, ry, rz } }
	if px or py or pz then
		pose.pos = { px or 0, py or 0, pz or 0 }
	end
	return pose
end

--[[
	Archetype builders.

	Most melee animation is the same four shapes with different timing and
	amplitude, so the shapes are functions and the movesets are the parameters.
	Hand-authored clips below use these where they fit and go bespoke where they
	do not.
]]

--- Overhead chop: blade goes up behind the head, then down through the target.
--- `side` is 1 for right-handed, -1 for a mirrored left-hand version.
local function overhead(duration: number, reach: number, side: number): Clip
	return {
		duration = duration,
		blendIn = 0.12,
		keys = {
			{
				t = 0,
				joints = {
					RightShoulder = j(-20 * side, 0, -25),
					LeftShoulder = j(-10, 0, 20),
					Waist = j(-6, -14 * side, 0),
					Root = j(0, 0, 0),
				},
			},
			{ -- wind up: coil back and load the shoulder
				t = 0.34,
				joints = {
					RightShoulder = j(-158, 8 * side, -18),
					LeftShoulder = j(-46, 0, 26),
					Waist = j(-14, -26 * side, 0),
					Neck = j(-8, -10 * side, 0),
				},
			},
			{ -- contact: the frame the hitbox is open on
				t = 0.52,
				joints = {
					RightShoulder = j(28 * reach, -6 * side, 6),
					LeftShoulder = j(-18, 0, -14),
					Waist = j(20, 18 * side, 0),
					Neck = j(10, 6 * side, 0),
					Root = j(0, 0, 0, 0, -0.4, 0),
				},
			},
			{ -- follow through: the weight keeps going
				t = 0.72,
				joints = {
					RightShoulder = j(46 * reach, -14 * side, 12),
					Waist = j(26, 22 * side, 0),
					Root = j(0, 0, 0, 0, -0.6, 0),
				},
			},
			{ -- recover
				t = 1,
				joints = {
					RightShoulder = j(-20 * side, 0, -25),
					LeftShoulder = j(-10, 0, 20),
					Waist = j(-4, -8 * side, 0),
				},
			},
		},
	}
end

--- Horizontal sweep across the body. `direction` 1 = right-to-left, -1 = reverse.
local function sweep(duration: number, amplitude: number, direction: number): Clip
	return {
		duration = duration,
		blendIn = 0.1,
		keys = {
			{
				t = 0,
				joints = {
					RightShoulder = j(-30, 0, -30 * direction),
					LeftShoulder = j(-15, 0, 18),
					Waist = j(0, -30 * direction, 0),
				},
			},
			{
				t = 0.3,
				joints = {
					RightShoulder = j(-42, 40 * direction, -76 * direction),
					LeftShoulder = j(-30, 0, 30),
					Waist = j(-4, -52 * direction, 0),
					Neck = j(0, -22 * direction, 0),
				},
			},
			{
				t = 0.5,
				joints = {
					RightShoulder = j(-70 * amplitude, -30 * direction, 62 * direction),
					LeftShoulder = j(-20, 0, -20),
					Waist = j(4, 44 * direction, 0),
					Neck = j(0, 18 * direction, 0),
				},
			},
			{
				t = 0.74,
				joints = {
					RightShoulder = j(-58 * amplitude, -46 * direction, 84 * direction),
					Waist = j(6, 56 * direction, 0),
				},
			},
			{
				t = 1,
				joints = {
					RightShoulder = j(-28, 0, -20 * direction),
					LeftShoulder = j(-12, 0, 16),
					Waist = j(0, -10 * direction, 0),
				},
			},
		},
	}
end

--- Straight thrust. Reads as a poke; the body leans behind it.
local function thrust(duration: number, extension: number): Clip
	return {
		duration = duration,
		blendIn = 0.09,
		keys = {
			{
				t = 0,
				joints = {
					RightShoulder = j(-46, 0, -46),
					LeftShoulder = j(-40, 0, 34),
					Waist = j(0, -34, 0),
				},
			},
			{ -- draw back
				t = 0.3,
				joints = {
					RightShoulder = j(-30, 0, -70),
					LeftShoulder = j(-52, 0, 44),
					Waist = j(-4, -52, 0),
					Root = j(0, 0, 0, 0, 0, 0.3),
				},
			},
			{ -- extend
				t = 0.46,
				joints = {
					RightShoulder = j(-92 * extension, 0, -8),
					LeftShoulder = j(-30, 0, 20),
					Waist = j(6, 16, 0),
					Neck = j(4, 0, 0),
					Root = j(0, 0, 0, 0, 0, -0.5),
				},
			},
			{
				t = 0.68,
				joints = {
					RightShoulder = j(-88 * extension, 0, -12),
					Waist = j(4, 12, 0),
				},
			},
			{
				t = 1,
				joints = {
					RightShoulder = j(-46, 0, -46),
					LeftShoulder = j(-40, 0, 34),
					Waist = j(0, -26, 0),
				},
			},
		},
	}
end

--- Rising slash used for launchers and finishing flourishes.
local function uppercut(duration: number): Clip
	return {
		duration = duration,
		blendIn = 0.1,
		keys = {
			{
				t = 0,
				joints = {
					RightShoulder = j(30, 0, -40),
					LeftShoulder = j(-10, 0, 18),
					Waist = j(14, -20, 0),
					Root = j(0, 0, 0, 0, -0.5, 0),
				},
			},
			{
				t = 0.28,
				joints = {
					RightShoulder = j(52, 10, -56),
					Waist = j(22, -30, 0),
					Root = j(0, 0, 0, 0, -0.9, 0),
				},
			},
			{
				t = 0.48,
				joints = {
					RightShoulder = j(-150, -10, -10),
					LeftShoulder = j(-40, 0, -20),
					Waist = j(-18, 14, 0),
					Neck = j(-16, 0, 0),
					Root = j(0, 0, 0, 0, 0.7, 0),
				},
			},
			{
				t = 1,
				joints = {
					RightShoulder = j(-24, 0, -28),
					LeftShoulder = j(-12, 0, 16),
					Waist = j(0, -8, 0),
				},
			},
		},
	}
end

--- Full-body spin. Root yaw is driven by the animator, not baked, so it composes
--- with whatever direction the character is actually facing.
local function spin(duration: number, turns: number): Clip
	return {
		duration = duration,
		blendIn = 0.08,
		keys = {
			{
				t = 0,
				joints = {
					RightShoulder = j(-70, 0, -80),
					LeftShoulder = j(-70, 0, 80),
					Waist = j(0, -40, 0),
				},
			},
			{
				t = 0.2,
				joints = {
					RightShoulder = j(-88, 0, -92),
					LeftShoulder = j(-88, 0, 92),
					Waist = j(-6, 60 * turns, 0),
					Root = j(0, 360 * turns * 0.25, 0),
				},
			},
			{
				t = 0.6,
				joints = {
					RightShoulder = j(-88, 0, -92),
					LeftShoulder = j(-88, 0, 92),
					Waist = j(0, 20, 0),
					Root = j(0, 360 * turns * 0.8, 0),
				},
			},
			{
				t = 1,
				joints = {
					RightShoulder = j(-30, 0, -30),
					LeftShoulder = j(-20, 0, 24),
					Waist = j(0, 0, 0),
					Root = j(0, 360 * turns, 0),
				},
			},
		},
	}
end

PoseLibrary.Archetypes = {
	overhead = overhead,
	sweep = sweep,
	thrust = thrust,
	uppercut = uppercut,
	spin = spin,
}

--------------------------------------------------------------------------------
-- Clips
--------------------------------------------------------------------------------

PoseLibrary.Clips = {} :: { [string]: Clip }
local Clips = PoseLibrary.Clips

--- Locomotion and stance. These loop and sit at low priority under actions.
Clips.Idle = {
	duration = 3.4,
	loop = true,
	blendIn = 0.3,
	keys = {
		{
			t = 0,
			joints = {
				RightShoulder = j(-14, 0, -16),
				LeftShoulder = j(-8, 0, 14),
				Waist = j(2, -6, 0),
				Neck = j(-2, 4, 0),
			},
		},
		{
			t = 0.5,
			joints = {
				RightShoulder = j(-18, 0, -13),
				LeftShoulder = j(-5, 0, 17),
				Waist = j(-2, -4, 0),
				Neck = j(2, -3, 0),
				Root = j(0, 0, 0, 0, 0.12, 0),
			},
		},
		{
			t = 1,
			joints = {
				RightShoulder = j(-14, 0, -16),
				LeftShoulder = j(-8, 0, 14),
				Waist = j(2, -6, 0),
				Neck = j(-2, 4, 0),
			},
		},
	},
}

--- Combat stance: weapon up, weight forward. Used whenever an enemy is engaged.
Clips.Guard = {
	duration = 2.2,
	loop = true,
	blendIn = 0.22,
	keys = {
		{
			t = 0,
			joints = {
				RightShoulder = j(-44, 12, -40),
				LeftShoulder = j(-34, 0, 30),
				Waist = j(4, -22, 0),
				Neck = j(0, 18, 0),
			},
		},
		{
			t = 0.5,
			joints = {
				RightShoulder = j(-48, 14, -37),
				LeftShoulder = j(-31, 0, 33),
				Waist = j(2, -20, 0),
				Neck = j(2, 16, 0),
				Root = j(0, 0, 0, 0, 0.1, 0),
			},
		},
		{
			t = 1,
			joints = {
				RightShoulder = j(-44, 12, -40),
				LeftShoulder = j(-34, 0, 30),
				Waist = j(4, -22, 0),
				Neck = j(0, 18, 0),
			},
		},
	},
}

Clips.Run = {
	duration = 0.62,
	loop = true,
	blendIn = 0.16,
	keys = {
		{
			t = 0,
			joints = {
				RightShoulder = j(-46, 0, -22),
				LeftShoulder = j(34, 0, 18),
				RightHip = j(38, 0, 0),
				LeftHip = j(-34, 0, 0),
				Waist = j(10, 0, 0),
			},
		},
		{
			t = 0.25,
			joints = {
				RightShoulder = j(-10, 0, -20),
				LeftShoulder = j(-6, 0, 18),
				RightHip = j(4, 0, 0),
				LeftHip = j(0, 0, 0),
				Waist = j(12, 0, 0),
				Root = j(0, 0, 0, 0, 0.35, 0),
			},
		},
		{
			t = 0.5,
			joints = {
				RightShoulder = j(34, 0, -18),
				LeftShoulder = j(-46, 0, 22),
				RightHip = j(-34, 0, 0),
				LeftHip = j(38, 0, 0),
				Waist = j(10, 0, 0),
			},
		},
		{
			t = 0.75,
			joints = {
				RightShoulder = j(-6, 0, -18),
				LeftShoulder = j(-10, 0, 20),
				RightHip = j(0, 0, 0),
				LeftHip = j(4, 0, 0),
				Waist = j(12, 0, 0),
				Root = j(0, 0, 0, 0, 0.35, 0),
			},
		},
		{
			t = 1,
			joints = {
				RightShoulder = j(-46, 0, -22),
				LeftShoulder = j(34, 0, 18),
				RightHip = j(38, 0, 0),
				LeftHip = j(-34, 0, 0),
				Waist = j(10, 0, 0),
			},
		},
	},
}

Clips.Walk = {
	duration = 0.92,
	loop = true,
	blendIn = 0.2,
	keys = {
		{
			t = 0,
			joints = {
				RightShoulder = j(-30, 0, -20),
				LeftShoulder = j(18, 0, 16),
				RightHip = j(22, 0, 0),
				LeftHip = j(-20, 0, 0),
				Waist = j(4, 0, 0),
			},
		},
		{
			t = 0.5,
			joints = {
				RightShoulder = j(18, 0, -16),
				LeftShoulder = j(-30, 0, 20),
				RightHip = j(-20, 0, 0),
				LeftHip = j(22, 0, 0),
				Waist = j(4, 0, 0),
			},
		},
		{
			t = 1,
			joints = {
				RightShoulder = j(-30, 0, -20),
				LeftShoulder = j(18, 0, 16),
				RightHip = j(22, 0, 0),
				LeftHip = j(-20, 0, 0),
				Waist = j(4, 0, 0),
			},
		},
	},
}

Clips.Fall = {
	duration = 0.6,
	loop = true,
	blendIn = 0.14,
	keys = {
		{
			t = 0,
			joints = {
				RightShoulder = j(-120, 0, -30),
				LeftShoulder = j(-120, 0, 30),
				RightHip = j(-14, 0, 0),
				LeftHip = j(14, 0, 0),
				Waist = j(-8, 0, 0),
			},
		},
		{
			t = 1,
			joints = {
				RightShoulder = j(-134, 0, -24),
				LeftShoulder = j(-134, 0, 24),
				RightHip = j(-8, 0, 0),
				LeftHip = j(20, 0, 0),
				Waist = j(-12, 0, 0),
			},
		},
	},
}

--- Reactions.
Clips.Dodge = {
	duration = 0.36,
	blendIn = 0.05,
	keys = {
		{ t = 0, joints = { Waist = j(-6, 0, 0), RightShoulder = j(-30, 0, -30) } },
		{
			t = 0.3,
			joints = {
				Waist = j(52, 0, 0),
				RightShoulder = j(-120, 0, -46),
				LeftShoulder = j(-120, 0, 46),
				RightHip = j(-58, 0, 0),
				LeftHip = j(-58, 0, 0),
				Root = j(0, 0, 0, 0, -1.1, 0),
			},
		},
		{
			t = 0.66,
			joints = {
				Waist = j(30, 0, 0),
				RightShoulder = j(-70, 0, -30),
				LeftShoulder = j(-70, 0, 30),
				RightHip = j(-20, 0, 0),
				LeftHip = j(-20, 0, 0),
				Root = j(0, 0, 0, 0, -0.5, 0),
			},
		},
		{ t = 1, joints = { Waist = j(2, 0, 0), RightShoulder = j(-34, 0, -30) } },
	},
}

Clips.Parry = {
	duration = 0.42,
	blendIn = 0.04,
	keys = {
		{ t = 0, joints = { RightShoulder = j(-40, 0, -36), LeftShoulder = j(-30, 0, 30) } },
		{
			t = 0.14,
			joints = {
				RightShoulder = j(-96, 40, -18),
				LeftShoulder = j(-72, -20, 22),
				Waist = j(-8, 26, 0),
				Neck = j(-4, 10, 0),
			},
		},
		{
			t = 0.42,
			joints = {
				RightShoulder = j(-84, 30, -22),
				LeftShoulder = j(-64, -14, 26),
				Waist = j(-4, 20, 0),
			},
		},
		{ t = 1, joints = { RightShoulder = j(-44, 8, -38), LeftShoulder = j(-34, 0, 30) } },
	},
}

Clips.ParrySuccess = {
	duration = 0.5,
	blendIn = 0.03,
	keys = {
		{ t = 0, joints = { RightShoulder = j(-96, 40, -18), Waist = j(-8, 26, 0) } },
		{
			t = 0.16,
			joints = {
				RightShoulder = j(-56, -60, -30),
				LeftShoulder = j(-40, 20, 40),
				Waist = j(6, -46, 0),
				Neck = j(0, -26, 0),
				Root = j(0, 0, 0, 0, 0, -0.4),
			},
		},
		{ t = 1, joints = { RightShoulder = j(-44, 8, -38), Waist = j(0, -10, 0) } },
	},
}

Clips.HitReactLight = {
	duration = 0.28,
	blendIn = 0.03,
	keys = {
		{ t = 0, joints = {} },
		{
			t = 0.3,
			joints = {
				Waist = j(-18, 8, 0),
				Neck = j(-14, 0, 8),
				RightShoulder = j(10, 0, -14),
				LeftShoulder = j(10, 0, 14),
				Root = j(0, 0, 0, 0, 0, 0.3),
			},
		},
		{ t = 1, joints = {} },
	},
}

Clips.HitReactHeavy = {
	duration = 0.52,
	blendIn = 0.02,
	keys = {
		{ t = 0, joints = {} },
		{
			t = 0.22,
			joints = {
				Waist = j(-38, 16, 0),
				Neck = j(-28, 0, 16),
				RightShoulder = j(26, 0, -30),
				LeftShoulder = j(26, 0, 30),
				RightHip = j(-14, 0, 0),
				Root = j(0, 0, 0, 0, -0.3, 0.8),
			},
		},
		{
			t = 0.55,
			joints = {
				Waist = j(-14, 6, 0),
				Neck = j(-8, 0, 6),
				Root = j(0, 0, 0, 0, 0, 0.3),
			},
		},
		{ t = 1, joints = {} },
	},
}

Clips.Stagger = {
	duration = 1.1,
	blendIn = 0.04,
	keys = {
		{ t = 0, joints = {} },
		{
			t = 0.18,
			joints = {
				Waist = j(-46, 20, 0),
				Neck = j(-34, 0, 22),
				RightShoulder = j(34, 0, -40),
				LeftShoulder = j(34, 0, 40),
				RightHip = j(-22, 0, 0),
				LeftHip = j(8, 0, 0),
				Root = j(0, 0, 0, 0, -0.6, 1.1),
			},
		},
		{
			t = 0.6,
			joints = {
				Waist = j(-30, 10, 0),
				Neck = j(-24, 0, 12),
				RightShoulder = j(20, 0, -34),
				LeftShoulder = j(20, 0, 34),
				Root = j(0, 0, 0, 0, -0.4, 0.6),
			},
		},
		{ t = 1, joints = {} },
	},
}

Clips.Death = {
	duration = 1.3,
	blendIn = 0.05,
	keys = {
		{ t = 0, joints = {} },
		{
			t = 0.24,
			joints = {
				Waist = j(-30, 0, 0),
				Neck = j(-20, 0, 0),
				RightShoulder = j(40, 0, -60),
				LeftShoulder = j(40, 0, 60),
				RightHip = j(-30, 0, 0),
				Root = j(0, 0, 0, 0, -1.2, 0),
			},
		},
		{
			t = 1,
			joints = {
				Waist = j(-84, 0, 0),
				Neck = j(-40, 0, 0),
				RightShoulder = j(64, 0, -90),
				LeftShoulder = j(64, 0, 90),
				RightHip = j(-70, 0, 0),
				LeftHip = j(-60, 0, 0),
				Root = j(-70, 0, 0, 0, -2.6, 0),
			},
		},
	},
}

--- Non-combat expression, used by hub NPCs and idle poses.
Clips.Talk = {
	duration = 2.6,
	loop = true,
	blendIn = 0.3,
	keys = {
		{ t = 0, joints = { RightShoulder = j(-24, 0, -22), Neck = j(0, 6, 0) } },
		{ t = 0.3, joints = { RightShoulder = j(-52, 10, -34), Neck = j(-6, -8, 0), Waist = j(2, 6, 0) } },
		{ t = 0.62, joints = { RightShoulder = j(-30, -4, -18), Neck = j(4, 10, 0) } },
		{ t = 1, joints = { RightShoulder = j(-24, 0, -22), Neck = j(0, 6, 0) } },
	},
}

Clips.Work = {
	duration = 1.5,
	loop = true,
	blendIn = 0.3,
	keys = {
		{ t = 0, joints = { RightShoulder = j(-70, 0, -20), Waist = j(16, 0, 0), Neck = j(18, 0, 0) } },
		{
			t = 0.28,
			joints = {
				RightShoulder = j(-130, 0, -14),
				Waist = j(10, 0, 0),
				Neck = j(14, 0, 0),
			},
		},
		{
			t = 0.44,
			joints = {
				RightShoulder = j(-34, 0, -24),
				Waist = j(22, 0, 0),
				Neck = j(22, 0, 0),
				Root = j(0, 0, 0, 0, -0.2, 0),
			},
		},
		{ t = 1, joints = { RightShoulder = j(-70, 0, -20), Waist = j(16, 0, 0), Neck = j(18, 0, 0) } },
	},
}

--------------------------------------------------------------------------------
-- Weapon movesets, built from the archetypes.
--------------------------------------------------------------------------------

-- VIGIL (longsword): clean alternating diagonals, ending on a committed overhead.
Clips.Vigil_Light1 = sweep(0.44, 0.9, 1)
Clips.Vigil_Light2 = sweep(0.42, 0.95, -1)
Clips.Vigil_Light3 = overhead(0.52, 0.9, 1)
Clips.Vigil_Light4 = spin(0.66, 1)
Clips.Vigil_Heavy = overhead(0.86, 1.15, 1)
Clips.Vigil_Ability = thrust(0.5, 1.1)
Clips.Vigil_Ultimate = spin(1.15, 2)
Clips.Vigil_Finisher = thrust(0.85, 1.2)

-- GRUDGE (great axe): everything is slower and travels further.
Clips.Grudge_Light1 = sweep(0.62, 1.2, 1)
Clips.Grudge_Light2 = overhead(0.72, 1.2, 1)
Clips.Grudge_Light3 = sweep(0.78, 1.35, -1)
Clips.Grudge_Heavy = overhead(1.12, 1.4, 1)
Clips.Grudge_Ability = spin(0.95, 1)
Clips.Grudge_Ultimate = overhead(1.4, 1.6, 1)
Clips.Grudge_Finisher = overhead(1.0, 1.5, 1)

-- QUARREL (twin blades): short, fast, never quite stopping.
Clips.Quarrel_Light1 = sweep(0.26, 0.7, 1)
Clips.Quarrel_Light2 = sweep(0.24, 0.7, -1)
Clips.Quarrel_Light3 = thrust(0.26, 0.85)
Clips.Quarrel_Light4 = sweep(0.26, 0.8, 1)
Clips.Quarrel_Light5 = spin(0.44, 1)
Clips.Quarrel_Heavy = uppercut(0.56)
Clips.Quarrel_Ability = spin(0.5, 1)
Clips.Quarrel_Ultimate = spin(1.0, 3)
Clips.Quarrel_Finisher = sweep(0.7, 1.0, 1)

-- THRESH (spear): thrusts at range, with sweeps to create space.
Clips.Thresh_Light1 = thrust(0.36, 1.15)
Clips.Thresh_Light2 = thrust(0.34, 1.2)
Clips.Thresh_Light3 = sweep(0.5, 1.1, -1)
Clips.Thresh_Heavy = thrust(0.72, 1.35)
Clips.Thresh_Ability = thrust(0.42, 1.25)
Clips.Thresh_Ultimate = spin(0.9, 2)
Clips.Thresh_Finisher = thrust(0.9, 1.4)

--------------------------------------------------------------------------------
-- Enemy and boss movesets.
--------------------------------------------------------------------------------

Clips.Enemy_Swing = sweep(0.72, 0.9, 1)
Clips.Enemy_Overhead = overhead(0.92, 1.0, 1)
Clips.Enemy_Thrust = thrust(0.62, 1.0)
Clips.Enemy_DoubleSlash = sweep(0.5, 0.8, -1)
Clips.Enemy_ShieldBash = thrust(0.66, 0.7)
Clips.Enemy_Spin = spin(1.0, 1)
Clips.Enemy_Lunge = thrust(0.54, 1.3)

Clips.Enemy_Shoot = {
	duration = 0.9,
	blendIn = 0.12,
	keys = {
		{ t = 0, joints = { RightShoulder = j(-30, 0, -30), LeftShoulder = j(-40, 0, 30) } },
		{
			t = 0.35,
			joints = {
				RightShoulder = j(-100, 30, -20),
				LeftShoulder = j(-96, -10, 14),
				Waist = j(0, 26, 0),
				Neck = j(0, 14, 0),
			},
		},
		{
			t = 0.58,
			joints = {
				RightShoulder = j(-60, 50, -30),
				LeftShoulder = j(-96, -10, 14),
				Waist = j(0, 20, 0),
			},
		},
		{ t = 1, joints = { RightShoulder = j(-30, 0, -30), LeftShoulder = j(-40, 0, 30) } },
	},
}

Clips.Enemy_Cast = {
	duration = 1.4,
	blendIn = 0.2,
	keys = {
		{ t = 0, joints = { RightShoulder = j(-30, 0, -30), LeftShoulder = j(-30, 0, 30) } },
		{
			t = 0.5,
			joints = {
				RightShoulder = j(-172, 0, -24),
				LeftShoulder = j(-172, 0, 24),
				Waist = j(-18, 0, 0),
				Neck = j(-26, 0, 0),
				Root = j(0, 0, 0, 0, 0.5, 0),
			},
		},
		{
			t = 0.72,
			joints = {
				RightShoulder = j(-40, 0, -70),
				LeftShoulder = j(-40, 0, 70),
				Waist = j(24, 0, 0),
				Neck = j(16, 0, 0),
				Root = j(0, 0, 0, 0, -0.6, 0),
			},
		},
		{ t = 1, joints = { RightShoulder = j(-30, 0, -30), LeftShoulder = j(-30, 0, 30) } },
	},
}

--- Boss-scale attacks. Longer windups: a boss telegraph must survive being read
--- across a whole arena.
Clips.Boss_Stomp = {
	duration = 1.5,
	blendIn = 0.14,
	keys = {
		{ t = 0, joints = {} },
		{
			t = 0.42,
			joints = {
				RightHip = j(-72, 0, 0),
				Waist = j(-16, 0, 0),
				RightShoulder = j(-150, 0, -20),
				LeftShoulder = j(-150, 0, 20),
				Root = j(0, 0, 0, 0, 0.9, 0),
			},
		},
		{
			t = 0.56,
			joints = {
				RightHip = j(6, 0, 0),
				Waist = j(28, 0, 0),
				RightShoulder = j(-20, 0, -40),
				LeftShoulder = j(-20, 0, 40),
				Root = j(0, 0, 0, 0, -1.4, 0),
			},
		},
		{ t = 1, joints = {} },
	},
}

Clips.Boss_Sweep = sweep(1.35, 1.4, 1)
Clips.Boss_Overhead = overhead(1.55, 1.5, 1)
Clips.Boss_Charge = thrust(1.1, 1.0)

Clips.Boss_Roar = {
	duration = 2.0,
	blendIn = 0.2,
	keys = {
		{ t = 0, joints = {} },
		{
			t = 0.3,
			joints = {
				Waist = j(-34, 0, 0),
				Neck = j(-46, 0, 0),
				RightShoulder = j(-40, 0, -110),
				LeftShoulder = j(-40, 0, 110),
				Root = j(0, 0, 0, 0, 0.6, 0),
			},
		},
		{
			t = 0.7,
			joints = {
				Waist = j(-28, 0, 0),
				Neck = j(-40, 0, 0),
				RightShoulder = j(-30, 0, -120),
				LeftShoulder = j(-30, 0, 120),
			},
		},
		{ t = 1, joints = {} },
	},
}

--- Boss-scale cast: both hands raised and held, so the arena telegraph has
--- something to be attached to for a full beat before anything happens.
Clips.Boss_Cast = {
	duration = 1.4,
	blendIn = 0.18,
	keys = {
		{ t = 0, joints = {} },
		{
			t = 0.28,
			joints = {
				RightShoulder = j(-120, -20, -50),
				LeftShoulder = j(-120, 20, 50),
				Waist = j(-14, 0, 0),
				Neck = j(-20, 0, 0),
				Root = j(0, 0, 0, 0, 0.4, 0),
			},
		},
		{
			t = 0.52,
			joints = {
				RightShoulder = j(-176, -8, -30),
				LeftShoulder = j(-176, 8, 30),
				Waist = j(-22, 0, 0),
				Neck = j(-30, 0, 0),
				Root = j(0, 0, 0, 0, 0.8, 0),
			},
		},
		{
			t = 0.62,
			joints = {
				RightShoulder = j(-30, 0, -90),
				LeftShoulder = j(-30, 0, 90),
				Waist = j(26, 0, 0),
				Neck = j(18, 0, 0),
				Root = j(0, 0, 0, 0, -0.7, 0),
			},
		},
		{ t = 1, joints = {} },
	},
}

--- Vulnerable pose held while a boss is broken open between phases.
Clips.Boss_Exposed = {
	duration = 3.0,
	loop = true,
	blendIn = 0.3,
	keys = {
		{
			t = 0,
			joints = {
				Waist = j(-40, 0, 0),
				Neck = j(-30, 0, 0),
				RightShoulder = j(20, 0, -70),
				LeftShoulder = j(20, 0, 70),
				RightHip = j(-20, 0, 0),
				Root = j(0, 0, 0, 0, -1.0, 0),
			},
		},
		{
			t = 0.5,
			joints = {
				Waist = j(-44, 4, 0),
				Neck = j(-34, 0, 0),
				RightShoulder = j(24, 0, -66),
				LeftShoulder = j(16, 0, 74),
				RightHip = j(-22, 0, 0),
				Root = j(0, 0, 0, 0, -1.15, 0),
			},
		},
		{
			t = 1,
			joints = {
				Waist = j(-40, 0, 0),
				Neck = j(-30, 0, 0),
				RightShoulder = j(20, 0, -70),
				LeftShoulder = j(20, 0, 70),
				RightHip = j(-20, 0, 0),
				Root = j(0, 0, 0, 0, -1.0, 0),
			},
		},
	},
}

function PoseLibrary.Get(name: string): Clip?
	return Clips[name]
end

--- Total clip length in seconds, used to line hitbox windows up with the visuals.
function PoseLibrary.Duration(name: string): number
	local clip = Clips[name]
	return clip and clip.duration or 0.4
end

return PoseLibrary
