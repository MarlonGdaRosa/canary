local storagesTable = {
	{ storage = Storage.Quest.U12_30.FeasterOfSouls.FearFeasterKilled, bossName = "The Fear Feaster" },
	{ storage = Storage.Quest.U12_30.FeasterOfSouls.DreadMaidenKilled, bossName = "The Dread Maiden" },
	{ storage = Storage.Quest.U12_30.FeasterOfSouls.UnwelcomeKilled, bossName = "The Unwelcome" },
}

local portalPaleWorm = MoveEvent()
function portalPaleWorm.onStepIn(creature, item, position, fromPosition)
	local player = creature:getPlayer()
	if not player then
		return false
	end
	return true
end

portalPaleWorm:type("stepin")
portalPaleWorm:position({ x = 33570, y = 31444, z = 10 })
portalPaleWorm:register()
