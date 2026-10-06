local outlawCamp = Action()
function outlawCamp.onUse(player, item, fromPosition, target, toPosition, isHotkey)
	if item.itemid == 1642 then
		player:teleportTo(toPosition, true)
		item:transform(item.itemid + 1)
	end
	return true
end

outlawCamp:aid(1108)
outlawCamp:register()
