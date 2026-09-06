--!strict
--[[
	GameConfig — global tuning constants.

	Anything a designer would want to twiddle while playtesting lives here rather
	than being spread through the systems that use it. If a number appears in two
	systems, it belongs in this file.
]]

local GameConfig = {}

GameConfig.Version = "0.1.0-vertical-slice"

--- Set true in Studio to get verbose combat logging and the debug hitbox display.
GameConfig.Debug = {
	Enabled = false,
	ShowHitboxes = false,
	LogDamage = false,
	SkipIntro = false,
	-- Grants every unlock at join. Never ship with this on.
	UnlockEverything = false,
}

GameConfig.Player = {
	BaseMaxHealth = 100,
	BaseMaxStamina = 100,
	-- Stamina is only consumed by dodge and heavy attacks: it gates burst mobility,
	-- it is not a resource you manage on every swing. Regen is generous on purpose.
	StaminaRegenPerSecond = 22,
	StaminaRegenDelay = 0.55,
	BaseWalkSpeed = 20,
	SprintMultiplier = 1.0, -- no sprint: movement speed is a boon/relic axis instead
	JumpPower = 52,
	-- Death is a story beat, not a punishment. Keep the pause short.
	DeathCameraHold = 2.4,
	ReviveInvulnerability = 1.5,
}

GameConfig.Combat = {
	-- Global multiplier applied last in the damage pipeline. A single dial for
	-- "the whole game hits too hard / too soft".
	GlobalDamageScale = 1.0,

	-- How long an input stays queued waiting for the current action to end.
	-- 0.25s is the sweet spot: long enough that combo mashing feels forgiving,
	-- short enough that you never get an attack you stopped wanting.
	InputBufferWindow = 0.25,

	-- Time after a combo's last hit before the chain resets to swing 1.
	ComboResetWindow = 1.1,

	-- Perfect-parry window measured from the start of the parry action.
	PerfectParryWindow = 0.18,
	-- After the perfect window, the parry becomes a plain block for this long.
	ParryBlockDuration = 0.45,
	ParryStaminaCost = 0,
	ParryCooldown = 0.65,
	-- Damage reduction for a late (non-perfect) parry.
	BlockDamageReduction = 0.55,
	-- A perfect parry refunds tempo: it staggers the attacker and charges ultimate.
	PerfectParryStaggerBonus = 55,
	PerfectParryUltimateGain = 12,

	DodgeCost = 22,
	DodgeCooldown = 0.42,
	-- Invulnerability starts slightly after the dodge does, so a dodge cannot be
	-- used as a panic button 0ms before impact and still work.
	DodgeIFrameStart = 0.06,
	DodgeIFrameDuration = 0.34,
	DodgeDistance = 18,
	DodgeDuration = 0.36,

	-- Poise: enemies accumulate stagger from hits and reset it over time. Landing a
	-- stagger is the melee reward loop, so heavier weapons build it much faster.
	StaggerDecayPerSecond = 14,
	StaggerDuration = 1.1,
	StaggerDamageBonus = 1.25,

	-- Finisher offer threshold, as a fraction of max health.
	FinisherHealthThreshold = 0.18,
	FinisherRange = 9,
	FinisherIFrames = true,

	UltimateMax = 100,
	UltimateGainPerDamageDealt = 0.09,
	UltimateGainPerDamageTaken = 0.16,

	-- Server-side sanity limits. The client sends intent, never damage, but we
	-- still refuse intents that arrive faster than any human input could.
	MinIntentInterval = 0.05,
	MaxIntentsPerSecond = 24,
	-- Attacks resolve on the server; this is how far the server will trust a
	-- client-reported facing direction before clamping it.
	MaxFacingDeviationDegrees = 50,
	-- A hit is rejected outright if the target is further than the attack's reach
	-- plus this slack (covers latency and the target moving during the swing).
	HitRangeSlack = 6,
}

GameConfig.Camera = {
	DefaultDistance = 16,
	CombatDistance = 14,
	LockOnDistance = 17,
	MinDistance = 8,
	MaxDistance = 26,
	Height = 2.6,
	ShoulderOffset = 2.2,
	FollowSpeed = 16,
	RotationSpeed = 18,
	DefaultFov = 70,
	HeavyAttackFov = 76,
	LockOnMaxRange = 90,
	-- Camera shake is a comfort setting; players can zero it in Settings.
	ShakeEnabled = true,
	ShakeScale = 1.0,
}

GameConfig.Run = {
	-- Rooms between the start of a region and its boss, excluding the boss room.
	RoomsPerRegion = 11,
	-- The player is offered this many doors at each junction.
	DoorChoices = 2,
	-- ...except at these room indices, where a third door appears to widen builds.
	WideChoiceRooms = { 4, 8 },
	-- Mini-boss slot, as an index into the room sequence.
	MiniBossRoom = 6,
	StartingHealthFraction = 1.0,
	-- Motes are the in-run currency. They do not persist.
	BaseMotesPerRoom = 12,
	MotesPerElite = 20,
	-- Sable is the meta currency, awarded from run performance.
	SablePerRoomCleared = 3,
	SablePerBossKill = 60,
	SableFirstClearBonus = 150,
	-- Enemy scaling across a run, applied per room index.
	HealthScalePerRoom = 0.055,
	DamageScalePerRoom = 0.035,
	-- Heat: optional difficulty modifiers stack a reward multiplier.
	MaxHeat = 12,
	RewardPerHeat = 0.12,
}

GameConfig.Boons = {
	-- Choices offered at a Grace shrine.
	OffersPerShrine = 3,
	-- Rerolls the player starts a run with (extended by relics).
	BaseRerolls = 1,
	-- Rarity weights before any luck modifiers. Legendary is deliberately rare:
	-- it should be the story of the run, not a Tuesday.
	RarityWeights = {
		Common = 100,
		Rare = 34,
		Epic = 11,
		Legendary = 2.5,
	},
	RarityMultipliers = {
		Common = 1.0,
		Rare = 1.45,
		Epic = 2.0,
		Legendary = 2.9,
	},
	RarityColors = {
		Common = Color3.fromRGB(196, 200, 208),
		Rare = Color3.fromRGB(96, 168, 255),
		Epic = Color3.fromRGB(178, 112, 255),
		Legendary = Color3.fromRGB(255, 186, 74),
	},
	-- A Faded that has already given you something is likelier to come back --
	-- this is what makes a run cohere into a build instead of a grab bag.
	RepeatFadedWeightBonus = 1.6,
	-- Maximum Graces one run can hold before shrines start offering upgrades only.
	MaxActiveBoons = 14,
}

GameConfig.Enemies = {
	-- Detection is generous, but enemies only commit once you are inside their
	-- engage band. This is what stops the "twelve things sprinting at you" feel.
	DefaultDetectionRange = 60,
	MaxSimultaneousAttackers = 3,
	-- Attack tokens: only this many enemies may be in an attack at once, per room.
	-- Everyone else circles. It is the single biggest readability lever in the game.
	AttackTokens = 2,
	CircleRadius = 12,
	RepathInterval = 0.45,
	-- Enemies delete themselves this long after death, once VFX has played.
	CorpseLifetime = 4,
	-- Elites roll this many modifiers.
	EliteModifierCount = 1,
	EliteHealthMultiplier = 2.6,
	EliteDamageMultiplier = 1.35,
	EliteScale = 1.18,
}

GameConfig.Save = {
	DataStoreName = "HollowVerge_Profiles",
	-- Bump when the profile schema changes in a way migration must notice.
	SchemaVersion = 3,
	AutosaveInterval = 120,
	-- Session locking: a profile records which server holds it so two servers
	-- cannot both write. Locks older than this are considered abandoned.
	SessionLockTimeout = 1800,
	MaxLoadRetries = 5,
	RetryBackoffBase = 2,
	-- Studio play-tests use an in-memory store so you never poison live data.
	UseMockStoreInStudio = true,
}

GameConfig.Performance = {
	-- Hard caps. Exceeding these is a content bug, and we would rather drop the
	-- extra than drop frames.
	MaxActiveEnemies = 22,
	MaxActiveProjectiles = 40,
	MaxHitVfxPerSecond = 30,
	MaxDamageNumbers = 24,
	-- Rooms behind the player are stripped of enemies and dimmed rather than kept live.
	KeepPreviousRooms = 1,
	-- Distance past which enemy rigs stop running their procedural animator.
	AnimationCullDistance = 140,
	VfxCullDistance = 180,
}

GameConfig.Collision = {
	Player = "HV_Player",
	Enemy = "HV_Enemy",
	-- Hitboxes never collide with anything; they exist only for spatial queries.
	Hitbox = "HV_Hitbox",
	Debris = "HV_Debris",
}

return GameConfig
