local door = Action()

function door.onUse(player, item, fromPosition, target, toPosition, isHotkey)

	if item.itemid == 5113 then
		player:teleportTo(toPosition, true)
		item:transform(item.itemid + 1)
	elseif item.itemid == 5114 then
		if Creature.checkCreatureInsideDoor(player, toPosition) then
			return true
		end
		if item.itemid == 5114 then
			item:transform(item.itemid - 1)
			return true
		end
	end
	return true
end

door:aid(10102)
door:register()
