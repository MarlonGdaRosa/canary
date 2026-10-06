local destination = {
	[26668] = {
		position = Position(33411, 31082, 10),
		storage = Storage.Quest.U11_02.ForgottenKnowledge.AccessLavaTeleport,
	},
}

local lavaTeleport = MoveEvent()

function lavaTeleport.onStepIn(creature, item, position, fromPosition)
	local player = creature:getPlayer()
	if not player then
		return
	end

	local teleport = destination[item.actionid]
	if not teleport then
		return
	end

	player:getPosition():sendMagicEffect(CONST_ME_TELEPORT)
	player:teleportTo(teleport.position)
	player:getPosition():sendMagicEffect(CONST_ME_FIREAREA)
	return true
end

lavaTeleport:type("stepin")
lavaTeleport:aid(26668)
lavaTeleport:register()
