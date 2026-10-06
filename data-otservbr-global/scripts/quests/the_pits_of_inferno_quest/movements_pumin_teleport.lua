local puminTeleport = MoveEvent()

function puminTeleport.onStepIn(creature, item, position, fromPosition)
	local player = creature:getPlayer()
	if not player then
		return true
	end

	player:teleportTo(Position(32786, 32308, 15))
	player:getPosition():sendMagicEffect(CONST_ME_TELEPORT)
	return true
end

puminTeleport:type("stepin")
puminTeleport:aid(50087)
puminTeleport:register()
