--!strict
--[[
	AudioController — mixing, throttling and positioning.

	Every sound in the game is requested by name from AudioConfig. Because that
	config ships with empty asset ids (see its header for why), this controller is
	written to be completely silent and completely harmless until ids are filled
	in: an unknown or empty id is a no-op, not a warning storm.

	WHAT IT STILL DOES WITHOUT ASSETS
	The mixing decisions -- per-bus volume, pitch variance, distance rolloff,
	throttling -- are all live. Dropping ids into AudioConfig turns the sound on,
	already balanced, with no further work.

	THROTTLING
	Combat sounds are requested far faster than they should be played. A spin
	through six enemies produces six impact sounds in one frame, which sums into a
	single loud crack rather than six hits. Sounds sharing a throttle key collapse
	to one per window.
]]

local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local AudioConfig = require(Shared.Config.AudioConfig)

local AudioController = {}

local registry: any = nil
local player = Players.LocalPlayer

local buses: { [string]: SoundGroup } = {}
local lastPlayed: { [string]: number } = {}
local volumes = { master = 1, music = 0.5, sfx = 0.85 }

local currentMusic: Sound? = nil
local currentMusicId: string? = nil

--- One throttle window for everything that hits at once.
local IMPACT_THROTTLE = 0.045

--------------------------------------------------------------------------------

local function busFor(name: string): SoundGroup
	local existing = buses[name]
	if existing then
		return existing
	end
	local group = Instance.new("SoundGroup")
	group.Name = name
	group.Volume = AudioConfig.Buses[name] and AudioConfig.Buses[name].default or 1
	group.Parent = SoundService
	buses[name] = group
	return group
end

local function throttled(soundId: string): boolean
	local now = os.clock()
	local last = lastPlayed[soundId]
	if last and now - last < IMPACT_THROTTLE then
		return true
	end
	lastPlayed[soundId] = now
	return false
end

local function buildSound(definition: any): Sound?
	if definition.assetId == "" then
		-- No asset supplied. Silently do nothing; see this file's header.
		return nil
	end

	local sound = Instance.new("Sound")
	sound.SoundId = definition.assetId
	sound.Volume = definition.volume
	sound.SoundGroup = busFor(definition.bus)

	if definition.pitchRange then
		sound.PlaybackSpeed = definition.pitchRange[1]
			+ math.random() * (definition.pitchRange[2] - definition.pitchRange[1])
	end
	if definition.rollOffMin then
		sound.RollOffMinDistance = definition.rollOffMin
		sound.RollOffMaxDistance = definition.rollOffMax or 200
		sound.RollOffMode = Enum.RollOffMode.InverseTapered
	end

	return sound
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- Plays without a position. Used for UI and for things happening to the player.
function AudioController.PlayLocal(soundId: string)
	local definition = AudioConfig.Get(soundId)
	if not definition or throttled(soundId) then
		return
	end
	local sound = buildSound(definition)
	if not sound then
		return
	end
	sound.Parent = SoundService
	sound:Play()
	Debris:AddItem(sound, 8)
end

--- Plays at a world position, with distance rolloff.
function AudioController.PlayAt(soundId: string, position: Vector3)
	local definition = AudioConfig.Get(soundId)
	if not definition or throttled(soundId) then
		return
	end
	local sound = buildSound(definition)
	if not sound then
		return
	end

	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.1
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = workspace:FindFirstChild("Effects") or workspace

	sound.Parent = anchor
	sound:Play()
	Debris:AddItem(anchor, 8)
end

--[[
	Crossfades to a track. Music is one looping Sound per track; layered mixes
	(a boss phase adding percussion) are expressed as separate tracks here until
	real assets exist to layer, at which point the layer list in AudioConfig is
	already authored.
]]
function AudioController.PlayMusic(trackId: string?)
	if currentMusicId == trackId then
		return
	end
	currentMusicId = trackId

	local previous = currentMusic
	if previous then
		task.spawn(function()
			for step = 1, 20 do
				previous.Volume *= 0.8
				task.wait(0.05)
			end
			previous:Destroy()
		end)
	end
	currentMusic = nil

	if not trackId then
		return
	end
	local track = AudioConfig.Music[trackId]
	if not track or track.assetId == "" then
		return
	end

	local sound = Instance.new("Sound")
	sound.SoundId = track.assetId
	sound.Volume = 0
	sound.Looped = true
	sound.SoundGroup = busFor("Music")
	sound.Parent = SoundService
	sound:Play()
	currentMusic = sound

	task.spawn(function()
		for step = 1, 20 do
			if sound.Parent == nil then
				return
			end
			sound.Volume = track.volume * (step / 20)
			task.wait(0.05)
		end
	end)
end

function AudioController.SetVolumes(master: number, music: number, sfx: number)
	volumes.master = math.clamp(master, 0, 1)
	volumes.music = math.clamp(music, 0, 1)
	volumes.sfx = math.clamp(sfx, 0, 1)

	busFor("Music").Volume = volumes.music * volumes.master
	busFor("SFX").Volume = volumes.sfx * volumes.master
	busFor("UI").Volume = volumes.sfx * volumes.master * 0.8
	busFor("Ambience").Volume = volumes.music * volumes.master * 0.6
	busFor("Voice").Volume = volumes.master
end

--------------------------------------------------------------------------------

function AudioController.Init(services: any)
	registry = services
end

function AudioController.Start()
	for name in AudioConfig.Buses do
		busFor(name)
	end
	AudioController.SetVolumes(1, 0.5, 0.85)

	if not AudioConfig.HasAnyAssets() then
		-- One line, once, so a developer knows why the game is silent and does not
		-- go hunting for a bug.
		print("[AudioController] no audio asset ids configured; running silent (see AudioConfig)")
	end
end

return AudioController
