--!strict
--[[
	DataService — profile persistence.

	Roguelites live or die on their meta-progression surviving, so this is written
	defensively:

	SESSION LOCKING
	A profile records which JobId holds it and when it last checked in. A second
	server refuses to load a profile that is actively locked, and steals a lock
	that has gone stale (the holding server crashed). Without this, a player
	teleporting between servers can end up with two servers writing their profile
	and the loser's progress vanishes.

	UPDATEASYNC, NOT GET-THEN-SET
	Every write is a transform inside UpdateAsync. Read-modify-write across two
	calls loses data whenever two writes race, and they do race.

	RETRIES WITH BACKOFF
	DataStore calls fail. A failed load must never be treated as "new player",
	because that hands someone an empty profile and then saves it over their real
	one. A load that exhausts its retries puts the player in a read-only session
	instead, and says so.

	STUDIO
	Studio uses an in-memory store by default so playtesting cannot touch live
	data, and so the game works with API access to Studio switched off.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local GameConfig = require(Shared.Config.GameConfig)
local TableUtil = require(Shared.Util.TableUtil)
local Signal = require(Shared.Util.Signal)

local ProfileTemplate = require(script.Parent.ProfileTemplate)

local DataService = {}

DataService.ProfileLoaded = Signal.new()
DataService.ProfileReleased = Signal.new()

local profiles: { [Player]: any } = {}
local store: any = nil
local mockStore: { [string]: any } = {}
local useMock = false

--------------------------------------------------------------------------------
-- Store abstraction
--------------------------------------------------------------------------------

local function keyFor(userId: number): string
	return ("player_%d"):format(userId)
end

--- Mirrors the subset of DataStore we use, so the mock is a drop-in.
local function updateAsync(key: string, transform: (any) -> any): (boolean, any)
	if useMock then
		local ok, result = pcall(transform, mockStore[key])
		if not ok then
			return false, result
		end
		if result ~= nil then
			mockStore[key] = result
		end
		return true, result ~= nil and result or mockStore[key]
	end

	return pcall(function()
		return store:UpdateAsync(key, transform)
	end)
end

--------------------------------------------------------------------------------
-- Session locks
--------------------------------------------------------------------------------

local function lockIsStale(lock: any): boolean
	if not lock then
		return true
	end
	if lock.jobId == game.JobId then
		-- Our own lock from a previous session on this same server. Reclaim it.
		return true
	end
	return (os.time() - (lock.timestamp or 0)) > GameConfig.Save.SessionLockTimeout
end

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

export type Profile = {
	player: Player,
	data: any,
	-- False when the load failed; the session runs but never writes.
	canSave: boolean,
	loadedAt: number,
	dirty: boolean,
	saving: boolean,
}

--[[
	Attempts one load. Returns (profileData, reason).
	`reason` is "loaded", "created", "locked", or an error string.
]]
local function attemptLoad(userId: number): (any?, string)
	local key = keyFor(userId)
	local outcome = "loaded"

	local ok, result = updateAsync(key, function(existing)
		if existing == nil then
			outcome = "created"
			local fresh = TableUtil.DeepCopy(ProfileTemplate.Default)
			fresh.meta.createdAt = os.time()
			fresh.meta.userId = userId
			fresh.meta.lock = { jobId = game.JobId, timestamp = os.time() }
			return fresh
		end

		if not lockIsStale(existing.meta and existing.meta.lock) then
			outcome = "locked"
			-- Returning nil cancels the write, leaving the other server's lock alone.
			return nil
		end

		existing.meta = existing.meta or {}
		existing.meta.lock = { jobId = game.JobId, timestamp = os.time() }
		return existing
	end)

	if not ok then
		return nil, tostring(result)
	end
	if outcome == "locked" then
		return nil, "locked"
	end
	return result, outcome
end

--[[
	Loads with backoff. A "locked" result is retried too: the usual cause is the
	player's previous server not having released yet, which resolves in seconds.
]]
local function loadProfile(player: Player): (any?, boolean)
	local attempts = GameConfig.Save.MaxLoadRetries
	local lastReason = "unknown"

	for attempt = 1, attempts do
		if not player.Parent then
			return nil, false
		end

		local data, reason = attemptLoad(player.UserId)
		if data then
			return data, true
		end
		lastReason = reason

		local delay = GameConfig.Save.RetryBackoffBase ^ (attempt - 1)
		warn(("[DataService] load attempt %d for %s failed (%s); retrying in %.0fs")
			:format(attempt, player.Name, reason, delay))
		task.wait(delay)
	end

	warn(("[DataService] giving up on %s after %d attempts (%s)"):format(player.Name, attempts, lastReason))
	return nil, false
end

--------------------------------------------------------------------------------
-- Saving
--------------------------------------------------------------------------------

local function saveProfile(profile: Profile, releaseLock: boolean): boolean
	if not profile.canSave then
		return false
	end
	if profile.saving then
		return false
	end
	profile.saving = true

	local data = profile.data
	data.meta.lastSaved = os.time()
	data.meta.schemaVersion = GameConfig.Save.SchemaVersion

	local key = keyFor(profile.player.UserId)
	local ok, err = updateAsync(key, function(existing)
		-- Refuse to write over a profile another server has since claimed. This is
		-- the second half of session locking and the half people forget.
		if existing and existing.meta and existing.meta.lock then
			local lock = existing.meta.lock
			if lock.jobId ~= game.JobId and not lockIsStale(lock) then
				warn(("[DataService] refusing to overwrite %s; lock held by %s")
					:format(profile.player.Name, tostring(lock.jobId)))
				return nil
			end
		end

		local payload = TableUtil.DeepCopy(data)
		payload.meta.lock = if releaseLock then nil else { jobId = game.JobId, timestamp = os.time() }
		return payload
	end)

	profile.saving = false

	if not ok then
		warn(("[DataService] save failed for %s: %s"):format(profile.player.Name, tostring(err)))
		return false
	end

	profile.dirty = false
	return true
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function DataService.Get(player: Player): any?
	local profile = profiles[player]
	return profile and profile.data or nil
end

function DataService.GetProfile(player: Player): Profile?
	return profiles[player]
end

--- Marks a profile as needing a write. Cheap; call it freely.
function DataService.MarkDirty(player: Player)
	local profile = profiles[player]
	if profile then
		profile.dirty = true
	end
end

--[[
	The only supported way to change persistent data. Taking a mutator keeps every
	write in one place, so autosave marking and change notification cannot be
	forgotten at a call site.
]]
function DataService.Update(player: Player, mutator: (any) -> ()): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	local ok, err = pcall(mutator, profile.data)
	if not ok then
		warn(("[DataService] mutator error for %s: %s"):format(player.Name, tostring(err)))
		return false
	end
	profile.dirty = true
	return true
end

function DataService.Save(player: Player): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	return saveProfile(profile, false)
end

function DataService.FlushAll()
	for player, profile in profiles do
		if profile.dirty then
			saveProfile(profile, true)
		end
	end
	-- BindToClose gets a limited window; a short wait lets in-flight writes land.
	if not useMock then
		task.wait(2)
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	local data, ok = loadProfile(player)

	if not player.Parent then
		return
	end

	if not data then
		-- Read-only session. The player can still play; nothing will be written,
		-- and they are told rather than silently losing a run's worth of progress.
		data = TableUtil.DeepCopy(ProfileTemplate.Default)
		data.meta.userId = player.UserId
	end

	-- Reconcile brings a profile saved before a feature existed up to the current
	-- template, filling in only what is missing.
	TableUtil.Reconcile(data, ProfileTemplate.Default)
	ProfileTemplate.Migrate(data)

	local profile: Profile = {
		player = player,
		data = data,
		canSave = ok,
		loadedAt = os.clock(),
		dirty = false,
		saving = false,
	}
	profiles[player] = profile

	DataService.ProfileLoaded:Fire(player, profile)
end

local function onPlayerRemoving(player: Player)
	local profile = profiles[player]
	if not profile then
		return
	end
	profiles[player] = nil
	DataService.ProfileReleased:Fire(player, profile)
	saveProfile(profile, true)
end

function DataService.Init()
	useMock = RunService:IsStudio() and GameConfig.Save.UseMockStoreInStudio
	if useMock then
		print("[DataService] Studio detected; using in-memory profiles")
	else
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(GameConfig.Save.DataStoreName)
		end)
		if ok then
			store = result
		else
			warn("[DataService] DataStore unavailable; falling back to in-memory profiles")
			useMock = true
		end
	end
end

function DataService.Start()
	Players.PlayerAdded:Connect(function(player)
		task.spawn(onPlayerAdded, player)
	end)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- Anyone who joined before this ran (possible on a fast Studio start).
	for _, player in Players:GetPlayers() do
		if not profiles[player] then
			task.spawn(onPlayerAdded, player)
		end
	end

	task.spawn(function()
		while true do
			task.wait(GameConfig.Save.AutosaveInterval)
			for _, profile in profiles do
				if profile.dirty then
					saveProfile(profile, false)
				end
			end
		end
	end)
end

return DataService
