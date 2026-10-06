local theThievesDoor = Action()
function theThievesDoor.onUse(player, item, fromPosition, target, toPosition, isHotkey)
	player:say("You slip through the door", TALKTYPE_MONSTER_SAY)
	player:teleportTo(Position(32359, 32786, 6))
	return true
end

theThievesDoor:aid(51394)
theThievesDoor:register()
