local inServiceYalaharWest = Action()
function inServiceYalaharWest.onUse(player, item, fromPosition, target, toPosition, isHotkey)
	if item.uid == 3081 then
		if item.itemid == 5287 then
			player:teleportTo(toPosition, true)
			item:transform(5288)
			player:setStorageValue(Storage.Quest.U8_4.InServiceOfYalahar.MrWestDoor, 1)
		end
	elseif item.uid == 3082 then
		if item.itemid == 6260 then
			player:teleportTo(toPosition, true)
			item:transform(6261)
			player:setStorageValue(Storage.Quest.U8_4.InServiceOfYalahar.MrWestDoor, 2)
		end
	end
	return true
end

inServiceYalaharWest:uid(3081, 3082)
inServiceYalaharWest:register()
