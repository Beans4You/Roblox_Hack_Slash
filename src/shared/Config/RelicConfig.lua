--!strict
--[[
	RelicConfig — Keepsakes.

	Permanent collectibles. Each one is a small, permanent change to how a run
	starts, and they are the main reason to keep playing after the first clear.

	The rule they are written against: a Keepsake should change a decision, not a
	number. "+5 health" is not a Keepsake. "Your first Grace of every run is
	guaranteed Rare" is, because it changes how you value the first shrine.

	SETS
	Keepsakes belong to collections. Completing a set grants a cosmetic and a
	standing bonus, which is what turns "I found a thing" into "I am three away".
]]

export type Relic = {
	id: string,
	name: string,
	set: string,
	description: string,
	flavor: string,
	-- How it is obtained. Shown in the Keeper's catalogue as a hint before you own it.
	source: string,
	rarity: "Common" | "Rare" | "Epic" | "Legendary",
	-- Only one equipped Keepsake per slot.
	slot: "Vigour" | "Craft" | "Fortune" | "Rite",
	effect: any,
	hidden: boolean?,
}

local RelicConfig = {}

RelicConfig.Relics = {} :: { [string]: Relic }
local K = RelicConfig.Relics

--------------------------------------------------------------------------------
-- The Warden's Due — one per boss, plus the set completion.
--------------------------------------------------------------------------------

K.TallymansLedger = {
	id = "TallymansLedger",
	name = "THE TALLYMAN'S LEDGER",
	set = "WardensDue",
	description = "Every death this run makes the next one 6% shorter: enemies take that "
		.. "much more damage, cumulatively, up to 30%.",
	flavor = "Four hundred years of columns. Yours is near the back.",
	source = "Defeat Vhalric.",
	rarity = "Epic",
	slot = "Rite",
	effect = { kind = "DeathStacking", perDeath = 0.06, cap = 0.30 },
}

K.AshmothersCoal = {
	id = "AshmothersCoal",
	name = "THE ASHMOTHER'S COAL",
	set = "WardensDue",
	description = "You start each run with one Cinder Grace already held, at Rare.",
	flavor = "Still warm. It has been still warm for a very long time.",
	source = "Defeat Kessara.",
	rarity = "Epic",
	slot = "Rite",
	effect = { kind = "StartingBoon", element = "Cinder", rarity = "Rare" },
}

K.AnchoritesSilence = {
	id = "AnchoritesSilence",
	name = "THE ANCHORITE'S SILENCE",
	set = "WardensDue",
	description = "Standing still for one second makes you untargetable until you move.",
	flavor = "It is not that it cannot see you. It is that it has stopped bothering.",
	source = "Defeat the Hoarfrost Anchorite.",
	rarity = "Legendary",
	slot = "Rite",
	effect = { kind = "StillnessVeil", stillTime = 1.0, status = "Veiled" },
}

--------------------------------------------------------------------------------
-- The Small Things — Keeper Miren's collection. Earned by playing well, not long.
--------------------------------------------------------------------------------

K.UnspentCoin = {
	id = "UnspentCoin",
	name = "AN UNSPENT COIN",
	set = "SmallThings",
	description = "The first Grace you are offered each run is guaranteed Rare or better.",
	flavor = "Nobody in the Verge has ever needed money. Somebody kept this anyway.",
	source = "Complete a run without visiting a Well.",
	rarity = "Rare",
	slot = "Fortune",
	effect = { kind = "FirstBoonFloor", minimumRarity = "Rare" },
}

K.SecondKnife = {
	id = "SecondKnife",
	name = "A SECOND KNIFE",
	set = "SmallThings",
	description = "Your first death each run costs you 40% of your health instead of the run.",
	flavor = "Carried by someone who expected the first one to be taken.",
	source = "Die to the same enemy type five times.",
	rarity = "Legendary",
	slot = "Vigour",
	effect = { kind = "ExtraLife", uses = 1, healthOnRevive = 0.6 },
}

K.WhetstoneStub = {
	id = "WhetstoneStub",
	name = "A WORN WHETSTONE",
	set = "SmallThings",
	description = "Your first attack on a full-health enemy always critically strikes.",
	flavor = "Used down to nothing by somebody who never stopped sharpening.",
	source = "Land 500 first-hits on undamaged enemies.",
	rarity = "Rare",
	slot = "Craft",
	effect = { kind = "OpenerCrit" },
}

K.EmptyReliquary = {
	id = "EmptyReliquary",
	name = "AN EMPTY RELIQUARY",
	set = "SmallThings",
	description = "Holding no Graces gives you 45% more damage. It stops the moment you take one.",
	flavor = "Whatever was in it, it was not worth keeping.",
	source = "Reach the Warden's Gate holding no Graces.",
	rarity = "Epic",
	slot = "Rite",
	effect = { kind = "AsceticDamage", bonus = 0.45 },
}

K.KnottedCord = {
	id = "KnottedCord",
	name = "A KNOTTED CORD",
	set = "SmallThings",
	description = "Each room cleared without taking damage grants a stack of Emboldened that "
		.. "lasts the whole run.",
	flavor = "One knot per room. Somebody was counting something other than deaths.",
	source = "Clear four rooms in a row without taking damage.",
	rarity = "Epic",
	slot = "Vigour",
	effect = { kind = "FlawlessRoomStacks", status = "Emboldened", persists = true },
}

--------------------------------------------------------------------------------
-- The Trade — smith and mystic rewards, bought or earned at the hub.
--------------------------------------------------------------------------------

K.HalvicsHammer = {
	id = "HalvicsHammer",
	name = "HALVIC'S SPARE HAMMER",
	set = "Trade",
	description = "Forge rooms appear twice as often, and their upgrades cost no Motes.",
	flavor = "He has four. He will tell you at length why he needs four.",
	source = "Buy every Temper for one weapon.",
	rarity = "Rare",
	slot = "Craft",
	effect = { kind = "RoomTypeWeight", roomType = "Forge", multiplier = 2, freeUpgrades = true },
}

K.IlkasNeedle = {
	id = "IlkasNeedle",
	name = "ILKA'S NEEDLE",
	set = "Trade",
	description = "You may reroll a shrine's offer one extra time, and rerolls can upgrade "
		.. "rarity.",
	flavor = "She uses it to hold her eyes open. You should not ask.",
	source = "Discover 20 distinct Graces.",
	rarity = "Rare",
	slot = "Fortune",
	effect = { kind = "ExtraReroll", count = 1, rerollUpgrades = true },
}

K.RannochsMap = {
	id = "RannochsMap",
	name = "RANNOCH'S BAD MAP",
	set = "Trade",
	description = "You can see what is two rooms ahead, not one.",
	flavor = "It is wrong about the distances and right about everything that matters.",
	source = "Clear 15 rooms in a single run.",
	rarity = "Common",
	slot = "Fortune",
	effect = { kind = "RouteVision", depth = 2 },
}

K.GuestsQuestion = {
	id = "GuestsQuestion",
	name = "THE GUEST'S QUESTION",
	set = "Trade",
	description = "Wardens use their next-highest greeting. They notice you sooner.",
	flavor = "\"Ask them why they are still at their posts. Then tell me what they say.\"",
	source = "Speak to the Guest after ten runs.",
	rarity = "Legendary",
	slot = "Rite",
	effect = { kind = "BossRecognitionBonus", tiers = 1 },
	hidden = true,
}

--------------------------------------------------------------------------------
-- Sets
--------------------------------------------------------------------------------

RelicConfig.Sets = {
	WardensDue = {
		id = "WardensDue",
		name = "THE WARDEN'S DUE",
		description = "One from each of them.",
		reward = {
			cosmetic = "WardensMantle",
			-- Standing bonus once the set is complete, regardless of what is equipped.
			passive = { kind = "BossDamage", bonus = 0.1 },
		},
	},
	SmallThings = {
		id = "SmallThings",
		name = "THE SMALL THINGS",
		description = "Miren's catalogue. Things people carried for reasons they did not "
			.. "write down.",
		reward = {
			cosmetic = "KeepersLantern",
			passive = { kind = "ExtraRelicSlot" },
		},
	},
	Trade = {
		id = "Trade",
		name = "THE TRADE",
		description = "What Emberhold makes, and what it asks for.",
		reward = {
			cosmetic = "EmberholdSigil",
			passive = { kind = "SableGain", bonus = 0.15 },
		},
	},
}

--------------------------------------------------------------------------------
-- Accessors
--------------------------------------------------------------------------------

RelicConfig.Slots = { "Vigour", "Craft", "Fortune", "Rite" }
--- How many Keepsakes may be equipped at once, before the Small Things set bonus.
RelicConfig.BaseEquipSlots = 2

function RelicConfig.Get(relicId: string): Relic?
	return K[relicId]
end

function RelicConfig.InSet(setId: string): { Relic }
	local result = {}
	for _, relic in K do
		if relic.set == setId then
			table.insert(result, relic)
		end
	end
	table.sort(result, function(a, b)
		return a.id < b.id
	end)
	return result
end

--- (owned, total) for a set, given the player's owned-relic set.
function RelicConfig.SetProgress(setId: string, owned: { [string]: any }): (number, number)
	local have, total = 0, 0
	for _, relic in K do
		if relic.set == setId then
			total += 1
			if owned[relic.id] then
				have += 1
			end
		end
	end
	return have, total
end

function RelicConfig.CompletedSets(owned: { [string]: any }): { string }
	local completed = {}
	for setId in RelicConfig.Sets do
		local have, total = RelicConfig.SetProgress(setId, owned)
		if total > 0 and have == total then
			table.insert(completed, setId)
		end
	end
	table.sort(completed)
	return completed
end

function RelicConfig.Validate(): { string }
	local problems = {}
	for id, relic in K do
		if relic.id ~= id then
			table.insert(problems, ("%s has mismatched id %q"):format(id, relic.id))
		end
		if not RelicConfig.Sets[relic.set] then
			table.insert(problems, ("%s belongs to unknown set %q"):format(id, relic.set))
		end
		if not table.find(RelicConfig.Slots, relic.slot) then
			table.insert(problems, ("%s uses unknown slot %q"):format(id, relic.slot))
		end
	end
	return problems
end

return RelicConfig
