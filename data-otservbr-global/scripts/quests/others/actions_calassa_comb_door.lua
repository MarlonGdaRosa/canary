local othersCalassa = Action()
function othersCalassa.onUse(player, item, fromPosition, target, toPosition, isHotkey)
	if item.itemid ~= 5745 then
		return false
	end


	item:transform(item.itemid + 1)
	player:teleportTo(toPosition, true)
	return true
end

othersCalassa:aid(50161)
othersCalassa:register()
