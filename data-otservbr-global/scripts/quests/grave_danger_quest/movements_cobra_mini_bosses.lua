local FireWall = MoveEvent()

function FireWall.onStepIn(creature, item, position, fromPosition)
	if creature:isMonster() then
		return true
	end

	if fromPosition.y == 32691 then
		creature:teleportTo(Position(position.x, position.y + 2, position.z))
	elseif fromPosition.y == 32693 then
		creature:teleportTo(Position(position.x, position.y - 2, position.z))
	elseif fromPosition.x == 33385 then
		creature:teleportTo(Position(position.x + 2, position.y, position.z))
	elseif fromPosition.x == 33387 then
		creature:teleportTo(Position(position.x - 2, position.y, position.z))
	end
	creature:getPosition():sendMagicEffect(CONST_ME_HITBYFIRE)

	return true
end

FireWall:aid(36568)
FireWall:register()
