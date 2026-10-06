local custodian_door = Action()

function custodian_door.onUse(player, item, isHotkey)

	local pos = player:getPosition()

	if pos.x == 33365 then
		player:teleportTo(Position(pos.x + 2, pos.y, pos.z))
	elseif pos.x == 33367 then
		player:teleportTo(Position(pos.x - 2, pos.y, pos.z))
	end

	return true
end

custodian_door:aid(36569)
custodian_door:register()
