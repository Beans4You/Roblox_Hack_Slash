--!strict
--- Shared vocabulary for the combat state machine. Strings rather than numbers so
--- that a state showing up in a log or a network payload is readable.

local CombatEnums = {}

--- What a character is currently doing. Exactly one at a time.
CombatEnums.Action = {
	Idle = "Idle",
	Light = "Light",
	Heavy = "Heavy",
	Ability = "Ability",
	Ultimate = "Ultimate",
	Dodge = "Dodge",
	Parry = "Parry",
	Finisher = "Finisher",
	Staggered = "Staggered",
	Dead = "Dead",
	-- Locked out entirely: cutscene, phase transition, run transition.
	Locked = "Locked",
}

--- Where inside an action we are. Drives hitbox activation and cancel legality.
CombatEnums.Phase = {
	Windup = "Windup",
	Active = "Active",
	Recovery = "Recovery",
	Done = "Done",
}

--- What the client is asking to do. Maps onto Action after validation.
CombatEnums.Intent = {
	Light = "Light",
	Heavy = "Heavy",
	Dodge = "Dodge",
	Parry = "Parry",
	Ability = "Ability",
	Ultimate = "Ultimate",
	Finisher = "Finisher",
	Interact = "Interact",
	LockOn = "LockOn",
}

--- Why a hit did nothing. Reported back so feedback can differ per reason --
--- a parry and a miss should never look the same.
CombatEnums.HitResult = {
	Hit = "Hit",
	Critical = "Critical",
	Blocked = "Blocked",
	Parried = "Parried",
	Dodged = "Dodged",
	Immune = "Immune",
	OutOfRange = "OutOfRange",
	AlreadyHit = "AlreadyHit",
	Dead = "Dead",
}

--- Faction. Enemies mostly cannot hurt each other, with deliberate exceptions
--- (Censer detonations, Volatile elites) that are the funniest thing in the game.
CombatEnums.Team = {
	Player = "Player",
	Enemy = "Enemy",
	Neutral = "Neutral",
}

--- Actions that may be interrupted by taking damage, absent super armour.
CombatEnums.Interruptible = {
	Light = true,
	Heavy = true,
	Ability = true,
	Parry = true,
	Idle = true,
}

--- Actions during which the character cannot start anything new.
CombatEnums.Committed = {
	Ultimate = true,
	Finisher = true,
	Staggered = true,
	Dead = true,
	Locked = true,
}

return CombatEnums
