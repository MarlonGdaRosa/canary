local sacrifices = {
	[3723] = Tile(Position(31918, 32598, 10)), -- top left
	[3725] = Tile(Position(31918, 32599, 10)), -- bottom left
	[3732] = Tile(Position(31920, 32598, 10)), -- top right
	[3728] = Tile(Position(31920, 32599, 10)), -- bottom right
}

local teleport = MoveEvent()

function teleport.onStepIn(creature, item, position, fromPosition)
	local player = creature:getPlayer()
	if not player then
		return true
	end

	local successDestination = Position(31916, 32607, 10)
	player:teleportTo(successDestination)
	position:sendMagicEffect(CONST_ME_HITBYFIRE)
	successDestination:sendMagicEffect(CONST_ME_HITBYFIRE)
	return true
end

teleport:type("stepin")
teleport:aid(12585)
teleport:register()
