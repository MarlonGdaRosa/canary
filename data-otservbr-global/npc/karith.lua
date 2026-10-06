local internalNpcName = "Karith"
local npcType = Game.createNpcType(internalNpcName)
local npcConfig = {}

npcConfig.name = internalNpcName
npcConfig.description = internalNpcName

npcConfig.health = 100
npcConfig.maxHealth = npcConfig.health
npcConfig.walkInterval = 2000
npcConfig.walkRadius = 2

npcConfig.outfit = {
	lookType = 159,
	lookHead = 79,
	lookBody = 3,
	lookLegs = 93,
	lookFeet = 12,
	lookAddons = 0,
}

npcConfig.flags = {
	floorchange = false,
	profession = "sailor",
}
npcConfig.speechBubble = SPEECHBUBBLE_SAILOR

npcConfig.voices = {
	interval = 15000,
	chance = 50,
	{ text = "This weather is killing me. If I only had enough money to retire." },
}

local keywordHandler = KeywordHandler:new()
local npcHandler = NpcHandler:new(keywordHandler)

npcType.onThink = function(npc, interval)
	npcHandler:onThink(npc, interval)
end

npcType.onAppear = function(npc, creature)
	npcHandler:onAppear(npc, creature)
end

npcType.onDisappear = function(npc, creature)
	npcHandler:onDisappear(npc, creature)
end

npcType.onMove = function(npc, creature, fromPosition, toPosition)
	npcHandler:onMove(npc, creature, fromPosition, toPosition)
end

npcType.onSay = function(npc, creature, type, message)
	npcHandler:onSay(npc, creature, type, message)
end

npcType.onCloseChannel = function(npc, creature)
	npcHandler:onCloseChannel(npc, creature)
end

-- Travel
local function addTravelKeyword(keyword, cost, destination, text)
	local travelKeyword = keywordHandler:addKeyword({ keyword }, StdModule.say, {
		npcHandler = npcHandler,
		text = text or ("Do you want a passage to " .. keyword:titleCase() .. " for |TRAVELCOST|?"),
		cost = cost,
		discount = "postman",
	})
	travelKeyword:addChildKeyword({ "yes" }, StdModule.travel, {
		npcHandler = npcHandler,
		premium = false,
		cost = cost,
		discount = "postman",
		destination = destination,
	})
	travelKeyword:addChildKeyword({ "no" }, StdModule.say, {
		npcHandler = npcHandler,
		text = "Then no.",
		reset = true,
	})
end

addTravelKeyword("ab'dendriel", 160, Position(32734, 31668, 6), "Do you want a passage to Ab'Dendriel for |TRAVELCOST|?")
addTravelKeyword("darashia", 210, Position(33289, 32480, 6), "Of course it is merely superstition that the darashian sand wasp honey brings back youth and vitality, but as long people pay a decent price, I couldn't care less. Do you want a passage to Darashia for |TRAVELCOST|?")
addTravelKeyword("venore", 185, Position(32954, 32022, 6), "The swamp spice will turn out very lucrative considering that it helps to make even the most disgusting dish taste good. Do you want a passage to Venore for |TRAVELCOST|?")
addTravelKeyword("ankrahmun", 230, Position(33092, 32883, 6), "The Yalahari seem to be obsessed with conserving their dead, so I guess the embalming fluid will be a great success in Yalahar. Do you want a passage to Ankrahmun for |TRAVELCOST|?")
addTravelKeyword("port hope", 260, Position(32527, 32784, 6), "Ivory is highly prized by the artisans of the Yalahari. Do you want a passage to Port Hope for |TRAVELCOST|?")
addTravelKeyword("thais", 200, Position(32310, 32210, 6), "Astonishing enough the royal satin seems to suit the exquisite taste of the Yalahari. Do you want a passage to Thais for |TRAVELCOST|?")
addTravelKeyword("liberty bay", 275, Position(32285, 32892, 6), "Do you want a passage to Liberty Bay for |TRAVELCOST|?")
addTravelKeyword("carlin", 185, Position(32387, 31820, 6), "The evergreen flower pots are an amusing item that might find some customers here. Do you want a passage to Carlin for |TRAVELCOST|?")

-- Routes info
local routeMsg = "For the sake of profit, we established ship routes to {Ab'Dendriel}, {Darashia}, {Venore}, {Ankrahmun}, {Port Hope}, {Thais}, {Liberty Bay} and {Carlin}."
keywordHandler:addKeyword({ "passage" }, StdModule.say, { npcHandler = npcHandler, text = routeMsg })
keywordHandler:addKeyword({ "sail" }, StdModule.say, { npcHandler = npcHandler, text = routeMsg })
keywordHandler:addKeyword({ "route" }, StdModule.say, { npcHandler = npcHandler, text = routeMsg })
keywordHandler:addKeyword({ "trip" }, StdModule.say, { npcHandler = npcHandler, text = routeMsg })
keywordHandler:addKeyword({ "destination" }, StdModule.say, { npcHandler = npcHandler, text = routeMsg })
keywordHandler:addKeyword({ "town" }, StdModule.say, { npcHandler = npcHandler, text = routeMsg })
keywordHandler:addKeyword({ "go" }, StdModule.say, { npcHandler = npcHandler, text = routeMsg })

-- Kick
keywordHandler:addKeyword({ "kick" }, StdModule.kick, { npcHandler = npcHandler, destination = { Position(32811, 31267, 6), Position(32811, 31270, 6), Position(32811, 31273, 6) } })

-- Basic
keywordHandler:addKeyword({ "job" }, StdModule.say, { npcHandler = npcHandler, text = "I am the captain of this ship." })
keywordHandler:addKeyword({ "captain" }, StdModule.say, { npcHandler = npcHandler, text = "I am the captain of this ship." })
keywordHandler:addKeyword({ "name" }, StdModule.say, { npcHandler = npcHandler, text = "I'm Karith. I don't belong to a caste any longer, and only serve the Yalahari." })
keywordHandler:addKeyword({ "yalahar" }, StdModule.say, { npcHandler = npcHandler, text = "The city was a marvel to behold. It is certain that it have been the many foreigners that ruined it." })

-- Greeting message
keywordHandler:addGreetKeyword({ "ashari" }, { npcHandler = npcHandler, text = "Hello! Tell me what's on your mind. Time is money." })
-- Farewell message
keywordHandler:addFarewellKeyword({ "asgha thrazi" }, { npcHandler = npcHandler, text = "Goodbye, |PLAYERNAME|." })

npcHandler:setMessage(MESSAGE_GREET, "Hello! Tell me what's on your mind. Time is money.")
npcHandler:setMessage(MESSAGE_FAREWELL, "Good bye.")
npcHandler:setMessage(MESSAGE_WALKAWAY, "Good bye.")

npcHandler:addModule(FocusModule:new(), npcConfig.name, true, true, true)

-- npcType registering the npcConfig table
npcType:register(npcConfig)
