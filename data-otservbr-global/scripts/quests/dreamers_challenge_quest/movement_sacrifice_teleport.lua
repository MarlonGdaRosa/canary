local sacrificeTeleport = MoveEvent()

function sacrificeTeleport.onStepIn(creature, item, position, fromPosition)
	local player = creature:getPlayer()
	if not player then
		return true
	end
	if item.actionid == 50149 then
		player:teleportTo(Position(32835, 32225, 14)) --Sacrifice 2
		doSendMagicEffect(Position(32835, 32225, 14), CONST_ME_POFF)
	elseif item.actionid == 50150 then
		player:teleportTo(Position(32784, 32226, 14)) --Sacrifice 4
		doSendMagicEffect(Position(32784, 32226, 14), CONST_ME_POFF)
	end
	return true
end

sacrificeTeleport:type("stepin")
sacrificeTeleport:aid(50149, 50150)
sacrificeTeleport:register()
