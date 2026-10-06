local calassa = MoveEvent()

function calassa.onStepIn(creature, item, position, fromPosition)
	local player = creature:getPlayer()
	if not player then
		return true
	end

	player:teleportTo(Position(31914, 32713, 12))
	player:getPosition():sendMagicEffect(CONST_ME_WATERSPLASH)
	player:getPosition():sendMagicEffect(CONST_ME_LOSEENERGY)
	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "You enter the realm of Calassa.")
	return true
end

calassa:type("stepin")
calassa:aid(2070)
calassa:register()
