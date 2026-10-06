local destination = {
	[25018] = { position = Position(32498, 31622, 6) },
	[25019] = { position = Position(32665, 32735, 6) },
}

local carvingTeleportPortHope = MoveEvent()

function carvingTeleportPortHope.onStepIn(creature, item, position, fromPosition)
	local player = creature:getPlayer()
	if not player then
		return
	end

	local carvingTP = destination[item.uid]
	if not carvingTP then
		return
	end

	player:getPosition():sendMagicEffect(CONST_ME_TELEPORT)
	player:teleportTo(carvingTP.position)
	player:getPosition():sendMagicEffect(CONST_ME_TELEPORT)
	return true
end

carvingTeleportPortHope:type("stepin")

for index, value in pairs(destination) do
	carvingTeleportPortHope:uid(index)
end

carvingTeleportPortHope:register()
