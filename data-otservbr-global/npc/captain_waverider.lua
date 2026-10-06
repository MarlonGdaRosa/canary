local internalNpcName = "Captain Waverider"
local npcType = Game.createNpcType(internalNpcName)
local npcConfig = {}

npcConfig.name = internalNpcName
npcConfig.description = internalNpcName

npcConfig.health = 100
npcConfig.maxHealth = npcConfig.health
npcConfig.walkInterval = 2000
npcConfig.walkRadius = 2

npcConfig.outfit = {
	lookType = 96,
	lookHead = 0,
	lookBody = 0,
	lookLegs = 0,
	lookFeet = 0,
	lookAddons = 0,
}

npcConfig.flags = {
	floorchange = false,
	profession = "sailor",
}
npcConfig.speechBubble = SPEECHBUBBLE_SAILOR

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
		text = text or ("Do you seek a passage to " .. keyword:titleCase() .. " for |TRAVELCOST|?"),
		cost = cost,
		discount = "postman",
	})
	travelKeyword:addChildKeyword({ "yes" }, StdModule.travel, {
		npcHandler = npcHandler,
		premium = false,
		text = "And there we go!",
		cost = cost,
		discount = "postman",
		destination = destination,
	})
	travelKeyword:addChildKeyword({ "no" }, StdModule.say, {
		npcHandler = npcHandler,
		text = "I have to admit this leaves me a bit puzzled.",
		reset = true,
	})
end

addTravelKeyword("peg leg", 50, Position(32346, 32625, 7), "Ohhhh. So... <lowers his voice> you know who sent you so I sail you to you know where. <wink> <wink> It will cost |TRAVELCOST| to cover my expenses. Is it that what you wish?")
keywordHandler:addAliasKeyword({ "meriana" })

addTravelKeyword("passage", 200, Position(32131, 32913, 7), "<sigh> I knew someone else would claim all the treasure someday. But at least it will be you and not some greedy and selfish person. For |TRAVELCOST| I will sail you to your rendezvous with fate. Do we have a deal?")
keywordHandler:addAliasKeyword({ "treasure island" })

-- Basic
keywordHandler:addKeyword({ "job" }, StdModule.say, { npcHandler = npcHandler, text = "I am the captain of this ship." })
keywordHandler:addKeyword({ "captain" }, StdModule.say, { npcHandler = npcHandler, text = "I am the captain of this ship." })

npcHandler:setMessage(MESSAGE_GREET, "Greetings, daring adventurer. If you need a {passage} or a trip to {peg leg}, let me know.")
npcHandler:setMessage(MESSAGE_FAREWELL, "Good bye.")
npcHandler:setMessage(MESSAGE_WALKAWAY, "Oh well.")
npcHandler:addModule(FocusModule:new(), npcConfig.name, true, true, true)

-- npcType registering the npcConfig table
npcType:register(npcConfig)
