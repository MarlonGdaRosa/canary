local citizenSvargrond = MoveEvent()

function citizenSvargrond.onStepIn(creature, item, position, fromPosition)
	local player = creature:getPlayer()
	if not player then
		return true
	end

	player:teleportTo(Position(32212, 31131, 5))

	player:setDirection(DIRECTION_EAST)
	player:getPosition():sendMagicEffect(CONST_ME_TELEPORT)
	return true
end

citizenSvargrond:type("stepin")
citizenSvargrond:aid(30032)
citizenSvargrond:register()
