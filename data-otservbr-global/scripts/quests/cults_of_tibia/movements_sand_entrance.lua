local sandEntrance = MoveEvent()

function sandEntrance.onStepIn(creature, item, position, fromPosition)
	local player = creature:getPlayer()
	if not player then
		return true
	end

	return true
end

sandEntrance:type("stepin")
sandEntrance:position({ x = 33296, y = 32291, z = 11 })
sandEntrance:register()
