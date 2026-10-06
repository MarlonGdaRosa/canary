local teleports = {
	{ teleportPosition = { x = 33013, y = 31880, z = 9 }, teleportDestination = Position(32996, 31922, 10), storage = Storage.Quest.U9_60.BigfootsBurden.Warzone1Access, value = 1 },
	{ teleportPosition = { x = 33019, y = 31886, z = 9 }, teleportDestination = Position(33011, 31943, 11), storage = Storage.Quest.U9_60.BigfootsBurden.Warzone2Access, value = 2 },
	{ teleportPosition = { x = 33022, y = 31902, z = 9 }, teleportDestination = Position(32989, 31909, 12), storage = Storage.Quest.U9_60.BigfootsBurden.Warzone3Access, value = 3 },
}

local warzoneTeleport = MoveEvent()
function warzoneTeleport.onStepIn(creature, item, position, fromPosition)
	local player = creature:getPlayer()
	if not player then
		return true
	end

	for a = 1, #teleports do
		if player:getPosition() == Position(teleports[a].teleportPosition) then
			player:teleportTo(teleports[a].teleportDestination)
			player:getPosition():sendMagicEffect(CONST_ME_TELEPORT)
		end
	end
	return true
end

for b = 1, #teleports do
	warzoneTeleport:position(teleports[b].teleportPosition)
end
warzoneTeleport:register()
