local portalReward = MoveEvent()

function portalReward.onStepIn(creature, item, position, fromPosition)
	local player = creature:getPlayer()
	if not player then
		return false
	end

	player:teleportTo(Position(33621, 31411, 10))
	player:getPosition():sendMagicEffect(CONST_ME_TELEPORT)
	return true
end

portalReward:position({ x = 33621, y = 31416, z = 10 })
portalReward:register()
