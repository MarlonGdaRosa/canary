local config = {
	{
		position = Position(33268, 31833, 10),
		itemid = 946,
		toPosition = Position(33268, 31833, 12),
		vocationId = VOCATION.BASE_ID.SORCERER,
	},
	{
		position = Position(33268, 31838, 10),
		itemid = 947,
		toPosition = Position(33267, 31838, 12),
		vocationId = VOCATION.BASE_ID.DRUID,
	},
	{
		position = Position(33266, 31835, 10),
		itemid = 948,
		toPosition = Position(33265, 31835, 12),
		vocationId = VOCATION.BASE_ID.KNIGHT,
	},
	{
		position = Position(33270, 31835, 10),
		itemid = 942,
		toPosition = Position(33270, 31835, 12),
		vocationId = VOCATION.BASE_ID.PALADIN,
	},
}

local elementalSpheresLever = Action()
function elementalSpheresLever.onUse(player, item, fromPosition, target, toPosition, isHotkey)
	if item.itemid ~= 2772 then
		item:transform(2772)
		return true
	end
	local spectators = Game.getSpectators(Position(33268, 31836, 12), false, true, 30, 30, 30, 30)
	if #spectators > 0 or Game.getStorageValue(Storage.Quest.U8_2.ElementalSpheres.BossRoom) > 0 then
		player:say("Wait for the current team to exit.", TALKTYPE_MONSTER_SAY, false, 0, Position(33268, 31835, 10))
		return true
	end

	local players = {}
	for i = 1, #config do
		local creature = Tile(config[i].position):getTopCreature()
		if creature and creature:isPlayer() then
			local vocationId = creature:getVocation():getBaseId()
			if vocationId ~= config[i].vocationId then
				player:say("A player on the tile has the wrong vocation.", TALKTYPE_MONSTER_SAY, false, 0, Position(33268, 31835, 10))
				return true
			end
			players[#players + 1] = { player = creature, toPosition = config[i].toPosition, position = config[i].position }
		end
	end

	if #players == 0 then
		local vocationId = player:getVocation():getBaseId()
		for i = 1, #config do
			if vocationId == config[i].vocationId then
				players[#players + 1] = { player = player, toPosition = config[i].toPosition, position = player:getPosition() }
				break
			end
		end
		if #players == 0 then
			player:say("You need at least one player on the vocation tiles.", TALKTYPE_MONSTER_SAY, false, 0, Position(33268, 31835, 10))
			return true
		end
	end

	for i = 1, #players do
		players[i].player:teleportTo(players[i].toPosition)
		players[i].position:sendMagicEffect(CONST_ME_TELEPORT)
		players[i].toPosition:sendMagicEffect(CONST_ME_TELEPORT)
	end

	item:transform(item.itemid + 1)
	return true
end

elementalSpheresLever:uid(1010)
elementalSpheresLever:register()
