--!strict
--[[
	DialogueConfig — Emberhold speaks.

	Every line is gated by run state, and the resolver always picks the
	highest-priority line whose conditions currently hold. That is the whole
	mechanism, and it is enough to make five NPCs feel like they are tracking you:
	Halvic notices which weapon you keep taking, Rannoch notices how far you got,
	the Guest notices everything.

	CONDITIONS
	  minRuns / maxRuns          total runs attempted
	  minDeaths                  total deaths
	  bossDefeated               boss id you have beaten at least once
	  bossNotDefeated            boss id you have never beaten
	  hasWeapon / lacksWeapon    weapon unlock state
	  weaponMastery              { weapon, level }
	  minRelics                  number of Keepsakes owned
	  storyFlag / notStoryFlag   flags set by earlier lines
	  lastRunReached             room index reached on the most recent run
	  once                       consumed after being shown

	Lines are short on purpose. The brief asks for conversations, not cutscenes.
]]

export type Line = {
	id: string,
	priority: number,
	conditions: any?,
	-- Each string is one displayed beat. The player advances between them.
	text: { string },
	-- Story flags this line sets when it finishes.
	sets: { string }?,
	once: boolean?,
	-- Opens a shop or menu after the line.
	opens: string?,
	-- Grants something. Used sparingly, for story payoffs.
	grants: any?,
}

export type NPC = {
	id: string,
	name: string,
	role: string,
	description: string,
	-- Position within the hub, relative to its origin.
	position: Vector3,
	facing: number,
	rig: any,
	idleClip: string,
	services: { string },
	lines: { Line },
}

local DialogueConfig = {}

DialogueConfig.NPCs = {} :: { [string]: NPC }
local N = DialogueConfig.NPCs

--------------------------------------------------------------------------------
-- DURN HALVIC — the smith. Unlocks weapons and Tempers.
--------------------------------------------------------------------------------

N.Halvic = {
	id = "Halvic",
	name = "DURN HALVIC",
	role = "Smith",
	description = "Reforges weapons. Was a Warden's armourer once.",
	position = Vector3.new(-34, 0, -18),
	facing = 120,
	rig = {
		scale = 1.15,
		palette = {
			primary = Color3.fromRGB(86, 62, 48),
			secondary = Color3.fromRGB(54, 40, 34),
			accent = Color3.fromRGB(255, 122, 48),
			eye = Color3.fromRGB(255, 190, 130),
		},
		silhouette = { "pauldrons" },
		material = Enum.Material.Fabric,
	},
	idleClip = "Work",
	services = { "WeaponUnlock", "Temper" },
	lines = {
		{
			id = "Halvic_First",
			priority = 100,
			conditions = { maxRuns = 0 },
			once = true,
			text = {
				"You're the one that keeps coming back up the stair.",
				"I've got one sword worth the name and three that want work. Take the sword.",
				"Bring it back in one piece and I'll believe you're worth the other three.",
			},
			sets = { "MetHalvic" },
			opens = "Smith",
		},
		{
			id = "Halvic_NoUnlocks",
			priority = 60,
			conditions = { storyFlag = "MetHalvic", lacksWeapon = "Grudge", maxRuns = 4 },
			text = {
				"Still the sword. Nothing wrong with the sword.",
				"Axe wants four hundred Sable and a reason. Come back with both.",
			},
			opens = "Smith",
		},
		{
			id = "Halvic_Mastery",
			priority = 70,
			conditions = { weaponMastery = { weapon = "Vigil", level = 10 } },
			text = {
				"You've put real hours into that sword. I can feel it in the balance.",
				"There's a temper I've been saving. It'll cost you. It always costs.",
			},
			opens = "Smith",
		},
		{
			id = "Halvic_Warden",
			priority = 85,
			conditions = { bossDefeated = "Vhalric" },
			once = true,
			text = {
				"You put Vhalric down.",
				"...",
				"I made the plates on his left side. Fifty years, that took. He wore them "
					.. "the whole time and never once said thank you.",
				"Don't ask me anything else about it.",
			},
			sets = { "HalvicWardenTold" },
			opens = "Smith",
		},
		{
			id = "Halvic_Idle",
			priority = 10,
			text = {
				"Bring it here.",
			},
			opens = "Smith",
		},
	},
}

--------------------------------------------------------------------------------
-- ILKA THE UNBLINKING — the mystic. Permanent power spending.
--------------------------------------------------------------------------------

N.Ilka = {
	id = "Ilka",
	name = "ILKA THE UNBLINKING",
	role = "Mystic",
	description = "Binds Graces into something permanent.",
	position = Vector3.new(30, 0, -22),
	facing = -140,
	rig = {
		scale = 0.95,
		palette = {
			primary = Color3.fromRGB(72, 62, 92),
			secondary = Color3.fromRGB(46, 40, 62),
			accent = Color3.fromRGB(150, 118, 220),
			eye = Color3.fromRGB(220, 200, 255),
		},
		silhouette = { "cloak", "halo" },
		material = Enum.Material.Fabric,
		glow = true,
	},
	idleClip = "Idle",
	services = { "PermanentUpgrades" },
	lines = {
		{
			id = "Ilka_First",
			priority = 100,
			conditions = { maxRuns = 1 },
			once = true,
			text = {
				"You met one of them. Down there. One of the Faded.",
				"They gave you something and then you died and it went away. Yes. That is "
					.. "how it works.",
				"I can make a small part of it stay. Bring me Sable and I will show you.",
			},
			sets = { "MetIlka" },
			opens = "Mystic",
		},
		{
			id = "Ilka_Synergy",
			priority = 70,
			conditions = { storyFlag = "FoundSynergy" },
			once = true,
			text = {
				"You held two of them at once and they did something neither one does.",
				"Good. That is not supposed to be possible and I have been waiting three "
					.. "hundred years for someone to do it by accident.",
			},
			opens = "Mystic",
		},
		{
			id = "Ilka_Sleep",
			priority = 40,
			conditions = { minRuns = 15 },
			text = {
				"You look tired.",
				"I have not slept since the second cycle. I do not recommend it, but I do "
					.. "recommend getting used to it.",
			},
			opens = "Mystic",
		},
		{
			id = "Ilka_Idle",
			priority = 10,
			text = { "Sit. Or do not. I will be looking at you either way." },
			opens = "Mystic",
		},
	},
}

--------------------------------------------------------------------------------
-- RANNOCH — the scout. Tells you what changed and refuses to help further.
--------------------------------------------------------------------------------

N.Rannoch = {
	id = "Rannoch",
	name = "RANNOCH",
	role = "Scout",
	description = "Goes out, comes back, tells you what changed.",
	position = Vector3.new(6, 0, 30),
	facing = 0,
	rig = {
		scale = 1.0,
		palette = {
			primary = Color3.fromRGB(60, 72, 58),
			secondary = Color3.fromRGB(40, 48, 40),
			accent = Color3.fromRGB(196, 248, 226),
			eye = Color3.fromRGB(220, 255, 240),
		},
		silhouette = { "cloak", "tatters" },
		material = Enum.Material.Fabric,
	},
	idleClip = "Idle",
	services = { "RegionSelect", "HeatSelect" },
	lines = {
		{
			id = "Rannoch_First",
			priority = 100,
			conditions = { maxRuns = 0 },
			once = true,
			text = {
				"Don't. Whatever you were going to ask -- don't.",
				"I map it. I don't fight it. Those are different jobs and I am very clear "
					.. "on which one is mine.",
				"The March is flooded and the garrison hasn't been told the war ended. "
					.. "That's everything I know. Go on.",
			},
			sets = { "MetRannoch" },
			opens = "Expedition",
		},
		{
			id = "Rannoch_Died",
			priority = 55,
			conditions = { lastRunReached = { max = 3 }, minRuns = 2 },
			text = {
				"Three rooms.",
				"I'm not judging. I'm counting. There's a difference and you'll have to "
					.. "take my word for it.",
			},
			opens = "Expedition",
		},
		{
			id = "Rannoch_Deep",
			priority = 60,
			conditions = { lastRunReached = { min = 9 } },
			text = {
				"You got to the Gate.",
				"I've never seen the Gate. I've drawn it four times from descriptions and "
					.. "all four are wrong.",
				"Tell me what the pillars look like. Please.",
			},
			opens = "Expedition",
		},
		{
			id = "Rannoch_NewRegion",
			priority = 90,
			conditions = { bossDefeated = "Vhalric" },
			once = true,
			text = {
				"The stair past the March goes down. It has always gone down and I have "
					.. "never been able to walk it.",
				"It's open now. That's because of you, which I find annoying.",
				"It's hot. That's all I've got.",
			},
			opens = "Expedition",
		},
		{
			id = "Rannoch_Idle",
			priority = 10,
			text = { "Where to." },
			opens = "Expedition",
		},
	},
}

--------------------------------------------------------------------------------
-- KEEPER MIREN — the collection. Believes the Keepsakes spell something.
--------------------------------------------------------------------------------

N.Miren = {
	id = "Miren",
	name = "KEEPER MIREN",
	role = "Keeper",
	description = "Catalogues the Keepsakes.",
	position = Vector3.new(-8, 0, -38),
	facing = 180,
	rig = {
		scale = 0.9,
		palette = {
			primary = Color3.fromRGB(78, 70, 64),
			secondary = Color3.fromRGB(52, 46, 42),
			accent = Color3.fromRGB(255, 200, 110),
			eye = Color3.fromRGB(255, 230, 180),
		},
		silhouette = { "cloak" },
		material = Enum.Material.Fabric,
	},
	idleClip = "Work",
	services = { "Relics" },
	lines = {
		{
			id = "Miren_First",
			priority = 100,
			conditions = { minRelics = 1 },
			once = true,
			text = {
				"Oh -- oh, you found one. Give it here. Gently.",
				"Everything down there was carried by somebody. Every single object. "
					.. "Somebody picked it up and decided it was worth the weight.",
				"I am going to work out what they were all trying to say. Bring me more.",
			},
			sets = { "MetMiren" },
			opens = "Relics",
		},
		{
			id = "Miren_Set",
			priority = 80,
			conditions = { minRelics = 6 },
			text = {
				"Six. I have them in an order now and the order is starting to hold.",
				"I won't tell you what it says yet. I've been wrong twice and it was "
					.. "embarrassing both times.",
			},
			opens = "Relics",
		},
		{
			id = "Miren_Idle",
			priority = 10,
			text = { "Anything? Anything at all?" },
			opens = "Relics",
		},
	},
}

--------------------------------------------------------------------------------
-- THE GUEST — the story.
--
-- The spine of the game's plot, told in nine beats across roughly fifteen runs.
-- Each beat is gated on something the player did rather than on time passing, so
-- the story tracks the player's actual progress through the Verge.
--------------------------------------------------------------------------------

N.Guest = {
	id = "Guest",
	name = "THE GUEST",
	role = "Stranger",
	description = "Arrived before you did. Nobody remembers letting them in.",
	position = Vector3.new(38, 0, 26),
	facing = -120,
	rig = {
		scale = 1.05,
		palette = {
			primary = Color3.fromRGB(30, 30, 36),
			secondary = Color3.fromRGB(18, 18, 24),
			accent = Color3.fromRGB(226, 222, 214),
			eye = Color3.fromRGB(255, 255, 255),
		},
		silhouette = { "cloak" },
		material = Enum.Material.SmoothPlastic,
	},
	idleClip = "Talk",
	services = {},
	lines = {
		{
			id = "Guest_1",
			priority = 100,
			conditions = { minDeaths = 1, notStoryFlag = "Guest1" },
			once = true,
			text = {
				"That was your first one.",
				"Don't look at me like that. Everyone gets a first one. Most people only "
					.. "get the one.",
			},
			sets = { "Guest1" },
		},
		{
			id = "Guest_2",
			priority = 100,
			conditions = { storyFlag = "Guest1", minDeaths = 3, notStoryFlag = "Guest2" },
			once = true,
			text = {
				"Three. And you came back up the stair each time, and nobody in this hold "
					.. "found that strange.",
				"I find it strange. I want you to know that somebody here finds it strange.",
			},
			sets = { "Guest2" },
		},
		{
			id = "Guest_3",
			priority = 100,
			conditions = { storyFlag = "Guest2", minRuns = 5, notStoryFlag = "Guest3" },
			once = true,
			text = {
				"Ask me how long I've been in Emberhold.",
				"Go on.",
				"Neither do I. That is my point. Nobody remembers letting me in, and I do "
					.. "not remember arriving, and we have all simply agreed not to raise it.",
			},
			sets = { "Guest3" },
		},
		{
			id = "Guest_4",
			priority = 100,
			conditions = { storyFlag = "Guest3", bossDefeated = "Vhalric", notStoryFlag = "Guest4" },
			once = true,
			text = {
				"He counted. Did he tell you what he was counting?",
				"Not deaths. Deaths are easy, there is one each. He was counting *returns*.",
				"There are four hundred years of them in that ledger and not one of them "
					.. "is yours.",
			},
			sets = { "Guest4" },
		},
		{
			id = "Guest_5",
			priority = 100,
			conditions = { storyFlag = "Guest4", minRuns = 9, notStoryFlag = "Guest5" },
			once = true,
			text = {
				"The Reforging does not bring people back. It re-knits the *place*. The "
					.. "walls. The water. The garrison.",
				"People are not part of the place. People are what the place is being "
					.. "rebuilt around.",
				"So. What are you.",
			},
			sets = { "Guest5" },
		},
		{
			id = "Guest_6",
			priority = 100,
			conditions = { storyFlag = "Guest5", minDeaths = 12, notStoryFlag = "Guest6" },
			once = true,
			text = {
				"I have been counting too. I'm sorry. It seemed important to have a second "
					.. "column.",
				"Here is what I have: every time you die, Emberhold gets one thing back. A "
					.. "wall. A door. Once, a person.",
				"You are not surviving the Reforging. You are *feeding* it.",
			},
			sets = { "Guest6", "KnowsTheCost" },
		},
		{
			id = "Guest_7",
			priority = 100,
			conditions = { storyFlag = "Guest6", bossDefeated = "Kessara", notStoryFlag = "Guest7" },
			once = true,
			text = {
				"Kessara knew. That's what the fuel was. That's what she was apologising for.",
				"She had been doing it herself, alone, for as long as she could stand it.",
				"And then you arrived, and you were better at it, and she was so relieved "
					.. "she let you kill her.",
			},
			sets = { "Guest7" },
		},
		{
			id = "Guest_8",
			priority = 100,
			conditions = { storyFlag = "Guest7", minRuns = 15, notStoryFlag = "Guest8" },
			once = true,
			text = {
				"You could stop. I want to be the one who says it out loud, at least once.",
				"Stay up here. Let the walls go. Emberhold falls apart in a season and "
					.. "everyone in it goes with it, and you would be *fine*.",
				"I am not telling you to. I am telling you that it is a choice, and that "
					.. "you have been making it about forty times without noticing.",
			},
			sets = { "Guest8" },
		},
		{
			id = "Guest_9",
			priority = 100,
			conditions = { storyFlag = "Guest8", bossDefeated = "Anchorite", notStoryFlag = "GuestFinal" },
			once = true,
			text = {
				"The Anchorite had the answer written down and froze the room so nobody "
					.. "could correct it.",
				"Here is the correction.",
				"I was the first Unspent. I stopped. I sat down in this hold and I stopped, "
					.. "and everyone here forgot me so completely that they cannot remember "
					.. "letting me in.",
				"That is what stopping costs. Not the walls. This.",
				"So go down again. Or don't. But now you're choosing it, and that is the "
					.. "only thing I ever wanted for you.",
			},
			sets = { "GuestFinal", "StoryComplete" },
			grants = { cosmetic = "Mask_Guest", relic = "GuestsQuestion" },
		},
		{
			id = "Guest_Waiting",
			priority = 10,
			text = { "Not yet. Go and do something and come back." },
		},
		{
			id = "Guest_Done",
			priority = 20,
			conditions = { storyFlag = "StoryComplete" },
			text = {
				"Still going down, then.",
				"Good. I mean that.",
			},
		},
	},
}

--------------------------------------------------------------------------------
-- Resolution
--------------------------------------------------------------------------------

--[[
	`state` is a flat snapshot supplied by the server:
	  runs, deaths, bossesDefeated (set), weaponsUnlocked (set), masteryLevels (map),
	  relicCount, storyFlags (set), seenLines (set), lastRunReached
]]
local function conditionsMet(line: Line, state: any): boolean
	local conditions = line.conditions
	if line.once and state.seenLines[line.id] then
		return false
	end
	if not conditions then
		return true
	end

	if conditions.minRuns and state.runs < conditions.minRuns then
		return false
	end
	if conditions.maxRuns and state.runs > conditions.maxRuns then
		return false
	end
	if conditions.minDeaths and state.deaths < conditions.minDeaths then
		return false
	end
	if conditions.bossDefeated and not state.bossesDefeated[conditions.bossDefeated] then
		return false
	end
	if conditions.bossNotDefeated and state.bossesDefeated[conditions.bossNotDefeated] then
		return false
	end
	if conditions.hasWeapon and not state.weaponsUnlocked[conditions.hasWeapon] then
		return false
	end
	if conditions.lacksWeapon and state.weaponsUnlocked[conditions.lacksWeapon] then
		return false
	end
	if conditions.weaponMastery then
		local level = state.masteryLevels[conditions.weaponMastery.weapon] or 0
		if level < conditions.weaponMastery.level then
			return false
		end
	end
	if conditions.minRelics and state.relicCount < conditions.minRelics then
		return false
	end
	if conditions.storyFlag and not state.storyFlags[conditions.storyFlag] then
		return false
	end
	if conditions.notStoryFlag and state.storyFlags[conditions.notStoryFlag] then
		return false
	end
	if conditions.lastRunReached then
		local reached = state.lastRunReached or 0
		if conditions.lastRunReached.min and reached < conditions.lastRunReached.min then
			return false
		end
		if conditions.lastRunReached.max and reached > conditions.lastRunReached.max then
			return false
		end
	end

	return true
end

--- Highest-priority line this NPC has to say right now. Ties break toward the
--- line declared first, so authoring order is a usable tiebreaker.
function DialogueConfig.Resolve(npcId: string, state: any): Line?
	local npc = N[npcId]
	if not npc then
		return nil
	end

	local best: Line? = nil
	for _, line in npc.lines do
		if conditionsMet(line, state) then
			if not best or line.priority > best.priority then
				best = line
			end
		end
	end
	return best
end

function DialogueConfig.Get(npcId: string): NPC?
	return N[npcId]
end

DialogueConfig.Order = { "Halvic", "Ilka", "Rannoch", "Miren", "Guest" }

function DialogueConfig.Validate(): { string }
	local problems = {}
	local seenIds = {}

	for id, npc in N do
		if npc.id ~= id then
			table.insert(problems, ("%s has mismatched id %q"):format(id, npc.id))
		end
		local hasFallback = false
		for _, line in npc.lines do
			if seenIds[line.id] then
				table.insert(problems, ("duplicate line id %q"):format(line.id))
			end
			seenIds[line.id] = true
			if #line.text == 0 then
				table.insert(problems, ("%s says nothing"):format(line.id))
			end
			-- A line with no conditions and low priority is the NPC's fallback.
			if not line.conditions and line.priority <= 20 then
				hasFallback = true
			end
		end
		if not hasFallback then
			table.insert(problems, ("%s has no unconditional fallback line"):format(id))
		end
	end

	return problems
end

return DialogueConfig
