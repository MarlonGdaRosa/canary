local TheNewFrontier = Storage.Quest.U8_54.TheNewFrontier

local childrenZalamon = Action()

function childrenZalamon.onUse(player, item, fromPosition, target, toPosition, isHotkey)
	if item.itemid == 9874 then
		player:teleportTo(toPosition, true)
		item:transform(item.itemid + 1)
	end
	return true
end

childrenZalamon:uid(3170)
childrenZalamon:register()
