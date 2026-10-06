local servantTeleport = MoveEvent()

function servantTeleport.onStepIn(creature, item, position, fromPosition)
	local player = creature:getPlayer()
	if not player then
		return
	end

	if not player:canFightBoss("LLoyd") then
		player:teleportTo(Position(32815, 32872, 13))
		player:getPosition():sendMagicEffect(CONST_ME_TELEPORT)
		position:sendMagicEffect(CONST_ME_TELEPORT)
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "You have to wait to challenge this enemy again!")
		return true
	end
	player:teleportTo(Position(32760, 32876, 14))
	player:getPosition():sendMagicEffect(CONST_ME_ENERGYHIT)
	return true
end

servantTeleport:type("stepin")
servantTeleport:aid(26665)
servantTeleport:register()
