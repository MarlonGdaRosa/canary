local quaraVortex = MoveEvent()

function quaraVortex.onStepIn(creature, item, position, fromPosition)
	local player = creature:getPlayer()
	if not player then
		return true
	end

	player:teleportTo(Position(32950, 31181, 9))
	player:getPosition():sendMagicEffect(CONST_ME_LOSEENERGY)
	player:say("The vortex throws you out in this vicious place.", TALKTYPE_MONSTER_SAY)
	return true
end

quaraVortex:type("stepin")
quaraVortex:aid(7812)
quaraVortex:register()
