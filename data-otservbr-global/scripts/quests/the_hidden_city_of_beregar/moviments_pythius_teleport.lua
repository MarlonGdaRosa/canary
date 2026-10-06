local pythiusTeleport = MoveEvent()

function pythiusTeleport.onStepIn(creature, item, position, fromPosition)
	local player = creature:getPlayer()
	if not player then
		return true
	end


	local destination = Position(32601, 31397, 14)
	player:teleportTo(destination)
	position:sendMagicEffect(CONST_ME_TELEPORT)
	destination:sendMagicEffect(CONST_ME_TELEPORT)
	return true
end

pythiusTeleport:type("stepin")
pythiusTeleport:uid(50127)
pythiusTeleport:register()
