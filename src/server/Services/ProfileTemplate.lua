--!strict
--[[
	ProfileTemplate — the shape of a saved profile, and how old ones catch up.

	Two rules for anything added here:

	  1. New fields must have a sensible default, because TableUtil.Reconcile will
	     add them to every existing profile the next time it loads. A default of
	     nil is not a default.
	  2. Anything that could grow without bound gets a cap. DataStore entries have
	     a hard size limit, and the way roguelites hit it is by keeping a list of
	     every run ever played. Recent history is capped; the aggregate totals it
	     rolls into are not.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local GameConfig = require(Shared.Config.GameConfig)
local CosmeticConfig = require(Shared.Config.CosmeticConfig)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local ProfileTemplate = {}

--- How many finished runs to keep in detail. Everything older survives only as
--- totals in `stats`.
ProfileTemplate.RunHistoryLimit = 25

local function defaultWeapons(): { [string]: any }
	local weapons = {}
	for id, weapon in WeaponConfig.Weapons do
		weapons[id] = {
			unlocked = weapon.unlockedByDefault,
			experience = 0,
			level = 1,
			tempers = {},        -- set of purchased temper ids
			equippedTemper = "", -- "" means the base weapon
			kills = 0,
			runsUsed = 0,
		}
	end
	return weapons
end

local function defaultCosmetics(): { [string]: boolean }
	local owned = {}
	for _, id in CosmeticConfig.Defaults() do
		owned[id] = true
	end
	return owned
end

ProfileTemplate.Default = {
	meta = {
		schemaVersion = GameConfig.Save.SchemaVersion,
		userId = 0,
		createdAt = 0,
		lastSaved = 0,
		lock = nil,
	},

	currency = {
		sable = 0,
		-- Lifetime total, never spent. Used for milestone unlocks.
		sableEarned = 0,
	},

	weapons = defaultWeapons(),

	--- Set of owned Keepsake ids, plus which are equipped.
	relics = {
		owned = {},
		equipped = {},
	},

	cosmetics = {
		owned = defaultCosmetics(),
		equipped = {
			Head = "Wanderer_Hood",
			Face = "",
			Back = "Wanderer_Cloak",
			Shoulders = "",
			Hands = "",
			Feet = "",
			Aura = "",
			Trail = "",
			Trophy = "",
		},
	},

	progress = {
		--- Set of region ids the player may travel to.
		regionsUnlocked = { SunkenMarch = true },
		--- Boss id -> { kills, deaths, firstClearAt, flawless, challenges = {} }
		bosses = {},
		--- Grace ids the player has ever held. Feeds Ilka's dialogue and the codex.
		boonsDiscovered = {},
		--- Synergy ids the player has ever triggered.
		synergiesFound = {},
		--- Story flags set by dialogue.
		storyFlags = {},
		--- Dialogue line ids already shown, so `once` lines stay once.
		seenLines = {},
		--- Highest heat cleared per region.
		heatCleared = {},
		--- Codex entries unlocked by events and environmental storytelling.
		loreUnlocked = {},
	},

	stats = {
		runs = 0,
		runsCompleted = 0,
		deaths = 0,
		roomsCleared = 0,
		enemiesKilled = 0,
		elitesKilled = 0,
		bossesKilled = 0,
		damageDealt = 0,
		damageTaken = 0,
		perfectParries = 0,
		finishers = 0,
		flawlessRooms = 0,
		motesEarned = 0,
		deepestRoom = 0,
		longestFlawlessStreak = 0,
		--- enemyId -> kill count, for cosmetic unlocks and the codex.
		killsByEnemy = {},
		--- enemyId -> how many times it has killed the player. Feeds A SECOND KNIFE.
		deathsByEnemy = {},
		playTime = 0,
	},

	--- Most recent finished runs, newest first, capped.
	history = {},

	settings = {
		cameraShake = 1.0,
		screenFlash = true,
		damageNumbers = true,
		lockOnEnabled = true,
		hudScale = 1.0,
		masterVolume = 1.0,
		musicVolume = 0.5,
		sfxVolume = 0.85,
	},
}

--------------------------------------------------------------------------------
-- Migration
--
-- Reconcile handles added fields. This handles anything that changed *meaning*:
-- a renamed id, a value that needs recomputing, a cap that got tighter.
--------------------------------------------------------------------------------

local MIGRATIONS: { [number]: (any) -> () } = {
	--- v1 -> v2: mastery moved from a flat level to experience-with-derived-level,
	--- so old profiles get experience backfilled from the level they had.
	[1] = function(data)
		local MasteryConfig = require(Shared.Config.MasteryConfig)
		for _, weapon in data.weapons do
			if weapon.experience == nil and weapon.level then
				weapon.experience = MasteryConfig.ExperienceForLevel(weapon.level)
			end
		end
	end,

	--- v2 -> v3: boss records became a table per boss rather than a kill count,
	--- so a bare number is promoted into the new shape.
	[2] = function(data)
		for bossId, record in data.progress.bosses do
			if type(record) == "number" then
				data.progress.bosses[bossId] = {
					kills = record,
					deaths = 0,
					firstClearAt = 0,
					flawless = false,
					challenges = {},
				}
			end
		end
	end,
}

--- Brings `data` up to the current schema version, one step at a time.
function ProfileTemplate.Migrate(data: any)
	local version = (data.meta and data.meta.schemaVersion) or 1

	while version < GameConfig.Save.SchemaVersion do
		local migration = MIGRATIONS[version]
		if migration then
			local ok, err = pcall(migration, data)
			if not ok then
				warn(("[ProfileTemplate] migration %d failed: %s"):format(version, tostring(err)))
				break
			end
		end
		version += 1
	end

	data.meta.schemaVersion = GameConfig.Save.SchemaVersion

	-- Enforce the history cap on every load, not just on write, so a profile that
	-- grew under an older cap gets trimmed rather than staying oversized forever.
	local history = data.history
	if #history > ProfileTemplate.RunHistoryLimit then
		for index = #history, ProfileTemplate.RunHistoryLimit + 1, -1 do
			history[index] = nil
		end
	end
end

--- Records a finished run, trimming history to the cap.
function ProfileTemplate.PushRun(data: any, summary: any)
	table.insert(data.history, 1, summary)
	for index = #data.history, ProfileTemplate.RunHistoryLimit + 1, -1 do
		data.history[index] = nil
	end
end

--- Ensures a boss record exists and returns it.
function ProfileTemplate.BossRecord(data: any, bossId: string): any
	local record = data.progress.bosses[bossId]
	if not record then
		record = { kills = 0, deaths = 0, firstClearAt = 0, flawless = false, challenges = {} }
		data.progress.bosses[bossId] = record
	end
	return record
end

return ProfileTemplate
