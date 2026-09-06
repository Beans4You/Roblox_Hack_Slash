--!strict
--[[
	Net — remote definitions and access.

	One list, one place. The server creates the instances at boot; the client waits
	for them. Nothing in this game creates a RemoteEvent anywhere else, which means
	the complete client/server attack surface is the table below and can be audited
	by reading one screen.

	DIRECTION IS DOCUMENTED AND ENFORCED
	Each entry declares who is allowed to fire it. `Net.OnServerEvent` refuses to
	bind a handler to a server-to-client remote and vice versa, so a mistake that
	would otherwise be a subtle security hole is a loud error at boot.

	THE CLIENT NEVER SENDS AUTHORITY
	Look at what crosses the wire from the client: intent (which button, which
	direction), and choices (which door, which Grace). No damage numbers, no
	positions that are trusted without validation, no currency, no unlocks. Every
	consequence is computed on the server. This is not a style preference; it is
	the reason an exploiter cannot hand themselves a Legendary Grace.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = {}

export type Direction = "ClientToServer" | "ServerToClient" | "Bidirectional"

export type Definition = {
	name: string,
	kind: "Event" | "Function",
	direction: Direction,
	description: string,
	-- Server-side rate limit for client-fired remotes, in calls per second.
	rateLimit: number?,
}

--------------------------------------------------------------------------------
-- Definitions
--------------------------------------------------------------------------------

Net.Definitions = {
	--- Combat intent. The client says "I pressed light attack, facing this way";
	--- the server decides whether that is legal and what it does.
	CombatIntent = {
		name = "CombatIntent",
		kind = "Event",
		direction = "ClientToServer",
		description = "{ action, facing: Vector3, moveDirection: Vector3?, targetId: number? }",
		rateLimit = 24,
	},

	--- Authoritative combat state for the local player: current action, phase,
	--- stamina, cooldowns. The client predicts animation from this, never damage.
	CombatState = {
		name = "CombatState",
		kind = "Event",
		direction = "ServerToClient",
		description = "{ action, swingIndex, phase, endsAt, stamina, cooldowns, ultimate }",
	},

	--- One entry per resolved hit, for damage numbers, hit sparks and screen shake.
	CombatFeedback = {
		name = "CombatFeedback",
		kind = "Event",
		direction = "ServerToClient",
		description = "{ kind, position, amount, crit, element, targetId, hitStop, shake }",
	},

	--- Fires an animation clip on a character for every nearby client.
	PlayClip = {
		name = "PlayClip",
		kind = "Event",
		direction = "ServerToClient",
		description = "{ characterId, clip, speed, fadeTime }",
	},

	--- Attack warnings: the shape, where, and how long until it lands.
	Telegraph = {
		name = "Telegraph",
		kind = "Event",
		direction = "ServerToClient",
		description = "{ id, shape, cframe, size, duration, color, undodgeable }",
	},

	--- Status effect added, refreshed or removed on any character.
	StatusSync = {
		name = "StatusSync",
		kind = "Event",
		direction = "ServerToClient",
		description = "{ characterId, statuses: { [id] = { stacks, expiresAt } } }",
	},

	--- Full profile snapshot, sent on join and after any permanent change.
	ProfileSync = {
		name = "ProfileSync",
		kind = "Event",
		direction = "ServerToClient",
		description = "The player's whole persistent profile.",
	},

	--- Live run state: room index, route, currency, held Graces, heat.
	RunSync = {
		name = "RunSync",
		kind = "Event",
		direction = "ServerToClient",
		description = "{ active, region, roomIndex, route, motes, boons, heat, stats }",
	},

	--- Start / abandon a run.
	RunRequest = {
		name = "RunRequest",
		kind = "Function",
		direction = "ClientToServer",
		description = "(action: 'Start'|'Abandon', weaponId, regionId, heat) -> ok, reason",
		rateLimit = 2,
	},

	--- Player picked a door.
	ChooseDoor = {
		name = "ChooseDoor",
		kind = "Event",
		direction = "ClientToServer",
		description = "{ doorIndex }",
		rateLimit = 4,
	},

	--- Shrine offer presented to the client.
	BoonOffer = {
		name = "BoonOffer",
		kind = "Event",
		direction = "ServerToClient",
		description = "{ offers: { { boonId, rarity, faded, description } }, rerolls }",
	},

	--- Player took a Grace, or spent a reroll.
	BoonChoose = {
		name = "BoonChoose",
		kind = "Event",
		direction = "ClientToServer",
		description = "{ index } or { reroll = true }",
		rateLimit = 6,
	},

	--- A synergy fired. Separate from BoonOffer because it is a moment, not a menu.
	SynergyFound = {
		name = "SynergyFound",
		kind = "Event",
		direction = "ServerToClient",
		description = "{ synergyId, name, description }",
	},

	--- Generic world interaction: NPCs, pedestals, chests, doors, the run gate.
	Interact = {
		name = "Interact",
		kind = "Event",
		direction = "ClientToServer",
		description = "{ targetId }",
		rateLimit = 8,
	},

	--- Dialogue beats, pushed one line at a time.
	Dialogue = {
		name = "Dialogue",
		kind = "Event",
		direction = "ServerToClient",
		description = "{ npcId, npcName, lines, opens }",
	},

	--- Hub services: buy a weapon, buy a temper, equip a relic, equip a cosmetic.
	HubAction = {
		name = "HubAction",
		kind = "Function",
		direction = "ClientToServer",
		description = "(action, payload) -> ok, reason",
		rateLimit = 8,
	},

	--- End-of-run summary.
	RunSummary = {
		name = "RunSummary",
		kind = "Event",
		direction = "ServerToClient",
		description = "Everything the run produced, for the summary screen.",
	},

	--- Client settings the server needs to know about (camera shake off, etc. are
	--- client-only; this carries the ones that affect gameplay presentation).
	SettingsSync = {
		name = "SettingsSync",
		kind = "Event",
		direction = "ClientToServer",
		description = "{ [settingName] = value }",
		rateLimit = 4,
	},

	--- Boss-specific UI: name card, phase, health, break meter.
	BossSync = {
		name = "BossSync",
		kind = "Event",
		direction = "ServerToClient",
		description = "{ active, bossId, name, subtitle, health, maxHealth, phase, break }",
	},

	--- Notifications: unlocks, mastery levels, relics found.
	Notify = {
		name = "Notify",
		kind = "Event",
		direction = "ServerToClient",
		description = "{ kind, title, body, icon, color }",
	},
} :: { [string]: Definition }

--------------------------------------------------------------------------------
-- Instance management
--------------------------------------------------------------------------------

local FOLDER_NAME = "HollowVergeRemotes"
local folder: Folder? = nil

--- Server only. Creates every remote instance declared above.
function Net.Init()
	assert(RunService:IsServer(), "Net.Init must run on the server")

	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if existing then
		existing:Destroy()
	end

	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME

	for name, definition in Net.Definitions do
		local instance: Instance
		if definition.kind == "Function" then
			instance = Instance.new("RemoteFunction")
		else
			instance = Instance.new("RemoteEvent")
		end
		instance.Name = name
		instance:SetAttribute("Direction", definition.direction)
		instance.Parent = created
	end

	created.Parent = ReplicatedStorage
	folder = created
end

local function getFolder(): Folder
	if folder then
		return folder
	end
	local found = ReplicatedStorage:WaitForChild(FOLDER_NAME, 30)
	assert(found, "HollowVerge remotes never appeared; is the server bootstrap running?")
	folder = found :: Folder
	return folder :: Folder
end

local function get(name: string): Instance
	local definition = Net.Definitions[name]
	assert(definition, ("unknown remote %q"):format(name))
	local instance = getFolder():WaitForChild(name, 30)
	assert(instance, ("remote %q never replicated"):format(name))
	return instance
end

function Net.Event(name: string): RemoteEvent
	return get(name) :: RemoteEvent
end

function Net.Function(name: string): RemoteFunction
	return get(name) :: RemoteFunction
end

--------------------------------------------------------------------------------
-- Direction enforcement + rate limiting
--------------------------------------------------------------------------------

local function assertDirection(name: string, expected: Direction, context: string)
	local definition = Net.Definitions[name]
	assert(definition, ("unknown remote %q"):format(name))
	if definition.direction ~= expected and definition.direction ~= "Bidirectional" then
		error(
			("%s is %s, so %s is the wrong way to use it"):format(name, definition.direction, context),
			2
		)
	end
end

--[[
	Server-side handler binding with the declared rate limit already applied.

	The limiter is per-player and per-remote, and it drops rather than queues:
	a client firing faster than a human can is either lagging or lying, and in
	both cases the correct response is to ignore the extra input, not to buffer
	it into a burst that happens later.
]]
function Net.OnServerEvent(name: string, handler: (Player, ...any) -> ()): RBXScriptConnection
	assert(RunService:IsServer(), "Net.OnServerEvent must run on the server")
	assertDirection(name, "ClientToServer", "listening on the server")

	local definition = Net.Definitions[name]
	local limit = definition.rateLimit
	local buckets: { [Player]: { tokens: number, last: number } } = {}

	return Net.Event(name).OnServerEvent:Connect(function(player, ...)
		if limit then
			local now = os.clock()
			local bucket = buckets[player]
			if not bucket then
				bucket = { tokens = limit, last = now }
				buckets[player] = bucket
			end
			bucket.tokens = math.min(limit, bucket.tokens + (now - bucket.last) * limit)
			bucket.last = now
			if bucket.tokens < 1 then
				return
			end
			bucket.tokens -= 1
		end

		local ok, err = pcall(handler, player, ...)
		if not ok then
			warn(("[Net] %s handler error: %s"):format(name, tostring(err)))
		end
	end)
end

function Net.OnClientEvent(name: string, handler: (...any) -> ()): RBXScriptConnection
	assert(RunService:IsClient(), "Net.OnClientEvent must run on the client")
	assertDirection(name, "ServerToClient", "listening on the client")

	return Net.Event(name).OnClientEvent:Connect(function(...)
		local ok, err = pcall(handler, ...)
		if not ok then
			warn(("[Net] %s handler error: %s"):format(name, tostring(err)))
		end
	end)
end

function Net.FireClient(name: string, player: Player, ...)
	assertDirection(name, "ServerToClient", "firing at a client")
	Net.Event(name):FireClient(player, ...)
end

function Net.FireAllClients(name: string, ...)
	assertDirection(name, "ServerToClient", "firing at all clients")
	Net.Event(name):FireAllClients(...)
end

function Net.FireServer(name: string, ...)
	assertDirection(name, "ClientToServer", "firing at the server")
	Net.Event(name):FireServer(...)
end

--- Binds a RemoteFunction handler with the same rate limiting and error trapping.
function Net.OnServerInvoke(name: string, handler: (Player, ...any) -> ...any)
	assert(RunService:IsServer(), "Net.OnServerInvoke must run on the server")
	local definition = Net.Definitions[name]
	assert(definition and definition.kind == "Function", ("%s is not a RemoteFunction"):format(name))

	local limit = definition.rateLimit
	local buckets: { [Player]: { tokens: number, last: number } } = {}

	Net.Function(name).OnServerInvoke = function(player, ...)
		if limit then
			local now = os.clock()
			local bucket = buckets[player]
			if not bucket then
				bucket = { tokens = limit, last = now }
				buckets[player] = bucket
			end
			bucket.tokens = math.min(limit, bucket.tokens + (now - bucket.last) * limit)
			bucket.last = now
			if bucket.tokens < 1 then
				return false, "too many requests"
			end
			bucket.tokens -= 1
		end

		local results = table.pack(pcall(handler, player, ...))
		if not results[1] then
			warn(("[Net] %s invoke error: %s"):format(name, tostring(results[2])))
			return false, "internal error"
		end
		return table.unpack(results, 2, results.n)
	end
end

return Net
