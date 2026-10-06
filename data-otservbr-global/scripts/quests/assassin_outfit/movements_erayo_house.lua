local erayoHouse = MoveEvent()

function erayoHouse.onStepIn(creature, item, position, fromPosition)
	local player = creature:getPlayer()
	if not player then
		return true
	end

	return true
end

erayoHouse:position({ x = 32517, y = 32909, z = 7 })
erayoHouse:register()
