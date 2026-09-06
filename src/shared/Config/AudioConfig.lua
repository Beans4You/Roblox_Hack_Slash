--!strict
--[[
	AudioConfig — every sound the game asks for, and how it should behave.

	IMPORTANT: `assetId` is empty for every entry. This project ships no uploaded
	audio, because audio assets cannot live in a git repository as reviewable text
	and an asset id that points at somebody else's upload is not something to hide
	in a config file.

	What *is* here is the part that matters and that is tedious to redo: which
	sounds exist, what each one is for, and how it is mixed -- volume, pitch
	variance, rolloff, and which bus it belongs to. Drop ids in and the game is
	tuned. Until then AudioController silently no-ops on empty ids, so the game is
	fully playable without them.

	PITCH VARIANCE
	Every repeated sound gets a random pitch inside `pitchRange`. Combat sounds
	that play dozens of times a minute become fatiguing without it; this is the
	cheapest possible fix and it is why swing sounds have wider ranges than
	one-shot ability sounds.
]]

export type Sound = {
	id: string,
	assetId: string,
	description: string,
	bus: "SFX" | "Music" | "UI" | "Ambience" | "Voice",
	volume: number,
	pitchRange: { number }?,
	rollOffMin: number?,
	rollOffMax: number?,
	looped: boolean?,
	-- Sounds sharing a throttle key cannot play more than once per `throttle` seconds.
	throttleKey: string?,
	throttle: number?,
}

local AudioConfig = {}

AudioConfig.Buses = {
	SFX = { default = 0.85 },
	Music = { default = 0.5 },
	UI = { default = 0.7 },
	Ambience = { default = 0.45 },
	Voice = { default = 1.0 },
}

local function sfx(id: string, description: string, volume: number, pitchLow: number, pitchHigh: number): Sound
	return {
		id = id,
		assetId = "",
		description = description,
		bus = "SFX",
		volume = volume,
		pitchRange = { pitchLow, pitchHigh },
		rollOffMin = 12,
		rollOffMax = 160,
	}
end

AudioConfig.Sounds = {} :: { [string]: Sound }
local S = AudioConfig.Sounds

--- Weapon swings. One per weapon weight class, pitched per swing index by the
--- controller so a combo rises in pitch as it accelerates.
S.SwingFast = sfx("SwingFast", "Short blade cutting air. Quarrel.", 0.5, 1.05, 1.3)
S.SwingLight = sfx("SwingLight", "Sword swing, medium weight. Vigil.", 0.6, 0.95, 1.12)
S.SwingMedium = sfx("SwingMedium", "Heavier committed swing.", 0.7, 0.88, 1.02)
S.SwingHeavy = sfx("SwingHeavy", "Two-handed swing with real mass behind it. Grudge.", 0.85, 0.78, 0.92)
S.SwingSpin = sfx("SwingSpin", "Full rotation, sustained whoosh.", 0.8, 0.9, 1.05)
S.SwingPierce = sfx("SwingPierce", "Spear thrust. Sharp, short, directional.", 0.55, 1.0, 1.15)
S.SwingLunge = sfx("SwingLunge", "Long lunging thrust with a step behind it.", 0.75, 0.9, 1.0)
S.SwingUppercut = sfx("SwingUppercut", "Rising cut. Should sound like it goes up.", 0.65, 1.0, 1.15)

--- Impacts. Distinct from swings so a whiff and a hit never sound alike -- this
--- is the single most important readability cue in melee.
S.Slash = sfx("Slash", "Blade into flesh. Wet, short.", 0.8, 0.94, 1.1)
S.SlashHeavy = sfx("SlashHeavy", "Heavy blade impact with a crunch under it.", 0.95, 0.85, 0.98)
S.SlashSpin = sfx("SlashSpin", "Multiple impacts inside one rotation.", 0.85, 0.92, 1.08)
S.Cleave = sfx("Cleave", "Axe impact. Low, blunt, with a splinter.", 0.9, 0.82, 0.96)
S.CleaveHeavy = sfx("CleaveHeavy", "The big one. Should make people flinch.", 1.0, 0.76, 0.9)
S.Nick = sfx("Nick", "Small, fast dagger hit. Plays a lot; keep it thin.", 0.4, 1.05, 1.35)
S.Pierce = sfx("Pierce", "Point going in.", 0.7, 0.96, 1.12)
S.PierceHeavy = sfx("PierceHeavy", "Point going all the way through.", 0.85, 0.88, 1.0)
S.Launch = sfx("Launch", "Upward hit that sends a body into the air.", 0.8, 0.98, 1.1)
S.Shockwave = sfx("Shockwave", "Ground shock spreading outward.", 1.0, 0.85, 1.0)
S.Crater = sfx("Crater", "Ultimate-scale ground impact.", 1.0, 0.7, 0.82)
S.Vortex = sfx("Vortex", "Sustained pull, rising.", 0.8, 0.95, 1.05)
S.PhaseCut = sfx("PhaseCut", "Dash-through cut, delayed and simultaneous.", 0.85, 1.0, 1.12)
S.Rain = sfx("Rain", "Many impacts falling from above.", 0.8, 0.94, 1.06)
S.BlockHit = sfx("BlockHit", "Attack turned by a guard.", 0.7, 0.9, 1.1)
S.ParryPerfect = sfx("ParryPerfect", "The perfect-parry ring. Must be unmistakable.", 1.0, 1.0, 1.0)
S.Whiff = sfx("Whiff", "Attack that hit nothing. Quiet; absence is the cue.", 0.3, 0.95, 1.1)

--- Player states.
S.Dodge = sfx("Dodge", "Roll or dash. Cloth and a footfall.", 0.5, 0.95, 1.12)
S.DodgePerfect = sfx("DodgePerfect", "Dodge that beat a hitbox by a hair.", 0.7, 1.0, 1.0)
S.PlayerHurt = sfx("PlayerHurt", "Taking a hit.", 0.8, 0.92, 1.08)
S.PlayerDeath = sfx("PlayerDeath", "The end of a run.", 1.0, 1.0, 1.0)
S.Heal = sfx("Heal", "Health restored.", 0.6, 0.98, 1.04)
S.UltimateReady = sfx("UltimateReady", "Ultimate meter filling. Should feel like an offer.", 0.8, 1.0, 1.0)

--- Weapon abilities and ultimates.
S.AbilityVigil = sfx("AbilityVigil", "Planted guard-thrust.", 0.8, 1.0, 1.0)
S.AbilityGrudge = sfx("AbilityGrudge", "Reap: a rising pull.", 0.85, 1.0, 1.0)
S.AbilityQuarrel = sfx("AbilityQuarrel", "Split Second: absence, then arrival.", 0.8, 1.0, 1.0)
S.AbilityThresh = sfx("AbilityThresh", "Spear leaving the hand.", 0.75, 1.0, 1.0)
S.UltimateVigil = sfx("UltimateVigil", "Unbroken.", 1.0, 1.0, 1.0)
S.UltimateGrudge = sfx("UltimateGrudge", "Settled.", 1.0, 1.0, 1.0)
S.UltimateQuarrel = sfx("UltimateQuarrel", "The Argument Ends.", 1.0, 1.0, 1.0)
S.UltimateThresh = sfx("UltimateThresh", "Harvest.", 1.0, 1.0, 1.0)

--- Enemies.
S.EnemySwing = sfx("EnemySwing", "Generic enemy swing.", 0.6, 0.9, 1.1)
S.EnemySwingFast = sfx("EnemySwingFast", "Fast enemy swing.", 0.5, 1.0, 1.25)
S.EnemyThrust = sfx("EnemyThrust", "Enemy thrust.", 0.55, 0.95, 1.12)
S.EnemyHeavy = sfx("EnemyHeavy", "Enemy heavy attack. Long tell.", 0.8, 0.82, 0.96)
S.EnemyLunge = sfx("EnemyLunge", "Enemy closing fast.", 0.7, 0.95, 1.08)
S.ShieldBash = sfx("ShieldBash", "Shield forward. Metal and weight.", 0.8, 0.9, 1.0)
S.BruteSlam = sfx("BruteSlam", "Brute overhead into ground.", 0.95, 0.78, 0.9)
S.BruteSweep = sfx("BruteSweep", "Brute rotation.", 0.9, 0.82, 0.94)
S.BowRelease = sfx("BowRelease", "Arrow loosed.", 0.5, 0.98, 1.1)
S.BowVolley = sfx("BowVolley", "Three arrows at once.", 0.6, 0.96, 1.06)
S.VesperDive = sfx("VesperDive", "Something falling at you.", 0.7, 0.95, 1.1)
S.VesperShriek = sfx("VesperShriek", "The Vesper's scream. Unpleasant on purpose.", 0.8, 0.94, 1.08)
S.CenserPrime = sfx("CenserPrime", "Rising whine. The most important warning in the game.", 0.9, 1.0, 1.0)
S.EnemyDeath = sfx("EnemyDeath", "Enemy dying.", 0.65, 0.9, 1.15)
S.EnemyStagger = sfx("EnemyStagger", "Poise broken. Should sound like a reward.", 0.75, 0.95, 1.08)
S.Telegraph = sfx("Telegraph", "Attack warning tick. Quiet, but always audible.", 0.45, 1.0, 1.0)

--- Bosses. Louder, less variance: a boss attack should sound identical every
--- time so it can be learned by ear.
S.BossSweep = sfx("BossSweep", "Warden-scale horizontal.", 1.0, 1.0, 1.0)
S.BossOverhead = sfx("BossOverhead", "Warden-scale overhead.", 1.0, 1.0, 1.0)
S.BossStomp = sfx("BossStomp", "Warden foot into floor.", 1.0, 1.0, 1.0)
S.BossCharge = sfx("BossCharge", "Warden crossing the arena.", 1.0, 1.0, 1.0)
S.BossRoar = sfx("BossRoar", "Phase transition.", 1.0, 1.0, 1.0)
S.BossCast = sfx("BossCast", "Arena-wide attack being prepared.", 1.0, 1.0, 1.0)
S.BossThrow = sfx("BossThrow", "Debris thrown.", 0.9, 0.94, 1.06)
S.BossFlamethrower = sfx("BossFlamethrower", "Sustained fire cone.", 1.0, 1.0, 1.0)
S.BossExhale = sfx("BossExhale", "The Anchorite breathing out.", 1.0, 1.0, 1.0)
S.BossSettlement = sfx("BossSettlement", "Vhalric's undodgeable. Must read as final.", 1.0, 1.0, 1.0)
S.BossPhase = sfx("BossPhase", "Phase threshold crossed.", 1.0, 1.0, 1.0)
S.BossBreak = sfx("BossBreak", "Break meter filled; boss is open.", 1.0, 1.0, 1.0)
S.BossDeath = sfx("BossDeath", "A Warden going down.", 1.0, 1.0, 1.0)

--- UI. Quieter than everything else by default; UI should never mask a telegraph.
local function ui(id: string, description: string, volume: number): Sound
	return { id = id, assetId = "", description = description, bus = "UI", volume = volume }
end

S.UiHover = ui("UiHover", "Cursor over a selectable.", 0.3)
S.UiSelect = ui("UiSelect", "Confirm.", 0.5)
S.UiBack = ui("UiBack", "Cancel.", 0.4)
S.UiOpen = ui("UiOpen", "Panel opening.", 0.45)
S.UiClose = ui("UiClose", "Panel closing.", 0.4)
S.BoonOffer = ui("BoonOffer", "Grace shrine presenting its three.", 0.7)
S.BoonTake = ui("BoonTake", "Grace accepted.", 0.8)
S.BoonLegendary = ui("BoonLegendary", "A Legendary rolled. Should stop the room.", 1.0)
S.SynergyFound = ui("SynergyFound", "Two Graces fusing. The best sound in the game.", 1.0)
S.DoorChoice = ui("DoorChoice", "Doors revealed.", 0.5)
S.RelicFound = ui("RelicFound", "A Keepsake.", 0.8)
S.MasteryUp = ui("MasteryUp", "Weapon mastery level gained.", 0.8)
S.UnlockEarned = ui("UnlockEarned", "Something permanent unlocked.", 0.9)
S.RunSummary = ui("RunSummary", "Summary screen appearing.", 0.6)
S.DialogueBeat = ui("DialogueBeat", "One line of dialogue advancing.", 0.25)

--- Music. Each track declares intensity layers the mixer crossfades between, so a
--- boss phase change is a mix change rather than a new track starting.
export type Track = {
	id: string,
	assetId: string,
	description: string,
	layers: { { name: string, assetId: string, intensity: number } },
	loopPoint: number?,
	volume: number,
}

AudioConfig.Music = {
	HubTheme = {
		id = "HubTheme",
		assetId = "",
		description = "Emberhold. Sparse, warm, unresolved. Should feel like a place that "
			.. "is being rebuilt rather than one that is finished.",
		volume = 0.4,
		layers = {
			{ name = "base", assetId = "", intensity = 0 },
			{ name = "strings", assetId = "", intensity = 0.5 },
		},
	},
	MarchTheme = {
		id = "MarchTheme",
		assetId = "",
		description = "The Sunken March. Low drone, distant bells, water.",
		volume = 0.35,
		layers = {
			{ name = "explore", assetId = "", intensity = 0 },
			{ name = "combat", assetId = "", intensity = 0.5 },
			{ name = "elite", assetId = "", intensity = 0.85 },
		},
	},
	ReachTheme = {
		id = "ReachTheme",
		assetId = "",
		description = "The Cinder Reach. Percussion-led, industrial, always slightly too fast.",
		volume = 0.35,
		layers = {
			{ name = "explore", assetId = "", intensity = 0 },
			{ name = "combat", assetId = "", intensity = 0.5 },
			{ name = "elite", assetId = "", intensity = 0.85 },
		},
	},
	SanctumTheme = {
		id = "SanctumTheme",
		assetId = "",
		description = "The Rimefast Sanctum. Choral, very slow, almost no percussion.",
		volume = 0.35,
		layers = {
			{ name = "explore", assetId = "", intensity = 0 },
			{ name = "combat", assetId = "", intensity = 0.5 },
			{ name = "elite", assetId = "", intensity = 0.85 },
		},
	},
	-- Boss tracks layer by phase: phase two adds percussion, phase three adds voice.
	BossVhalric = {
		id = "BossVhalric",
		assetId = "",
		description = "Vhalric. A ticking figure that speeds up across the phases.",
		volume = 0.5,
		layers = {
			{ name = "phase1", assetId = "", intensity = 0 },
			{ name = "phase2", assetId = "", intensity = 0.5 },
			{ name = "phase3", assetId = "", intensity = 0.9 },
		},
	},
	BossKessara = {
		id = "BossKessara",
		assetId = "",
		description = "Kessara. Warm and sad underneath something very loud.",
		volume = 0.5,
		layers = {
			{ name = "phase1", assetId = "", intensity = 0 },
			{ name = "phase2", assetId = "", intensity = 0.5 },
			{ name = "phase3", assetId = "", intensity = 0.9 },
		},
	},
	BossAnchorite = {
		id = "BossAnchorite",
		assetId = "",
		description = "The Anchorite. Near-silence, then everything at once in phase three.",
		volume = 0.5,
		layers = {
			{ name = "phase1", assetId = "", intensity = 0 },
			{ name = "phase2", assetId = "", intensity = 0.5 },
			{ name = "phase3", assetId = "", intensity = 0.9 },
		},
	},
}

AudioConfig.Ambience = {
	HubAmbience = { id = "HubAmbience", assetId = "", description = "Forge, wind, distant voices.", volume = 0.3 },
	MarchAmbience = { id = "MarchAmbience", assetId = "", description = "Dripping, lapping water, far-off armour.", volume = 0.3 },
	ReachAmbience = { id = "ReachAmbience", assetId = "", description = "Roaring furnace, settling ash.", volume = 0.3 },
	SanctumAmbience = { id = "SanctumAmbience", assetId = "", description = "Ice under pressure. Almost nothing else.", volume = 0.25 },
}

function AudioConfig.Get(soundId: string): Sound?
	return S[soundId]
end

--- True once someone has actually filled in asset ids. Used to decide whether to
--- warn about a missing sound or stay quiet about a whole missing library.
function AudioConfig.HasAnyAssets(): boolean
	for _, sound in S do
		if sound.assetId ~= "" then
			return true
		end
	end
	return false
end

function AudioConfig.Validate(): { string }
	local problems = {}
	for id, sound in S do
		if sound.id ~= id then
			table.insert(problems, ("%s has mismatched id %q"):format(id, sound.id))
		end
		if sound.pitchRange and sound.pitchRange[1] > sound.pitchRange[2] then
			table.insert(problems, ("%s has an inverted pitch range"):format(id))
		end
		if not AudioConfig.Buses[sound.bus] then
			table.insert(problems, ("%s is on unknown bus %q"):format(id, sound.bus))
		end
	end
	return problems
end

return AudioConfig
