local goPos = Position(32814, 32754, 9)

local actions_asura_mirror = Action()

function actions_asura_mirror.onUse(player, item, fromPosition, itemEx, toPosition)
	if player:getLevel() >= 250 then
		player:teleportTo(goPos)
		player:getPosition():sendMagicEffect(CONST_ME_TELEPORT)
	else
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "You do not have enough level.")
	end
end

actions_asura_mirror:aid(4910)
actions_asura_mirror:register()
