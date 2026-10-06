local Count = Storage.Quest.U12_00.TheDreamCourts.TheSevenKeys.Count
local Storage = Storage.Quest.U12_00.TheDreamCourts.TheSevenKeys.DoorInvisible
local lanternId = 23738

local actions_doorInvisible = Action()

function actions_doorInvisible.onUse(player, item, fromPosition, target, toPosition, isHotkey)
	local iPos = item:getPosition()

	if iPos.x < player:getPosition().x then
		player:teleportTo(Position(iPos.x - 3, iPos.y, iPos.z))
	else
		player:teleportTo(Position(iPos.x + 3, iPos.y, iPos.z))
	end
	player:getPosition():sendMagicEffect(CONST_ME_TELEPORT)

	return true
end

actions_doorInvisible:aid(23111)
actions_doorInvisible:register()
