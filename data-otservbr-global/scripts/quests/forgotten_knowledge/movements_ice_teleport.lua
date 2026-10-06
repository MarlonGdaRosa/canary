local destination = {
	[26667] = {
		position = Position(32273, 31053, 13),
		storage = Storage.Quest.U11_02.ForgottenKnowledge.AccessMachine,
	},
}

local iceTeleport = MoveEvent()

function iceTeleport.onStepIn(creature, item, position, fromPosition)
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
	player:getPosition():sendMagicEffect(CONST_ME_TELEPORT)
	return true
end

iceTeleport:type("stepin")
iceTeleport:aid(26667)
iceTeleport:register()
