local teleportTree = MoveEvent()

function teleportTree.onStepIn(creature, item, position, fromPosition)
	local player = creature:getPlayer()
	if not player then
		return
	end

	player:teleportTo(Position(32720, 32927, 14))
	player:getPosition():sendMagicEffect(CONST_ME_SMALLPLANTS)
	return true
end

teleportTree:type("stepin")
teleportTree:aid(27830)
teleportTree:register()
