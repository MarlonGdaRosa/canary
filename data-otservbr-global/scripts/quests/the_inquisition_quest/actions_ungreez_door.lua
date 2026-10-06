local inquisitionUngreez = Action()

function inquisitionUngreez.onUse(player, item, fromPosition, target, toPosition, isHotkey)
	if item.actionid == 1004 then
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
	end
	return true
end

inquisitionUngreez:aid(1004)
inquisitionUngreez:register()
