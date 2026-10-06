local doorId = {}
local keyLockedDoor = {}
local keyUnlockedDoor = {}
for index, value in ipairs(KeyDoorTable) do
	if not table.contains(doorId, value.closedDoor) then
		table.insert(doorId, value.closedDoor)
	end
	if not table.contains(doorId, value.lockedDoor) then
		table.insert(doorId, value.lockedDoor)
	end
	if not table.contains(doorId, value.openDoor) then
		table.insert(doorId, value.openDoor)
	end
	if not table.contains(keyLockedDoor, value.lockedDoor) then
		table.insert(keyLockedDoor, value.lockedDoor)
	end
	if not table.contains(keyUnlockedDoor, value.closedDoor) then
		table.insert(keyUnlockedDoor, value.closedDoor)
	end
end

for index, value in pairs(keysID) do
	if not table.contains(doorId, value) then
		table.insert(doorId, value)
	end
end

local keyDoor = Action()
function keyDoor.onUse(player, item, fromPosition, target, toPosition, isHotkey)
	-- onUse locked key door
	for index, value in ipairs(KeyDoorTable) do
		if value.lockedDoor == item.itemid then
			item:transform(value.openDoor)
			item:getPosition():sendSingleSoundEffect(SOUND_EFFECT_TYPE_ACTION_OPEN_DOOR)
			return true
		end
	end

	-- onUse unlocked key door
	for index, value in ipairs(KeyDoorTable) do
		if value.closedDoor == item.itemid then
			item:transform(value.openDoor)
			item:getPosition():sendSingleSoundEffect(SOUND_EFFECT_TYPE_ACTION_OPEN_DOOR)
			return true
		end
	end
	for index, value in ipairs(KeyDoorTable) do
		if value.openDoor == item.itemid then
			if Creature.checkCreatureInsideDoor(player, toPosition) then
				return false
			end
			item:transform(value.closedDoor)
			item:getPosition():sendSingleSoundEffect(SOUND_EFFECT_TYPE_ACTION_CLOSE_DOOR)
			return true
		end
	end

	-- Key use on door (locked key door)
	if target and target:isItem() then
		for index, value in ipairs(KeyDoorTable) do
			if value.lockedDoor == target.itemid then
				target:transform(value.openDoor)
				item:getPosition():sendSingleSoundEffect(SOUND_EFFECT_TYPE_ACTION_OPEN_DOOR)
				return true
			elseif table.contains({ value.openDoor, value.closedDoor }, target.itemid) then
				if value.openDoor == target.itemid then
					item:getPosition():sendSingleSoundEffect(SOUND_EFFECT_TYPE_ACTION_CLOSE_DOOR)
				end
				target:transform(value.lockedDoor)
				return true
			end
		end
	end
	return false
end

for key, value in pairs(doorId) do
	keyDoor:id(value)
end

keyDoor:register()
