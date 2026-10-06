local energyWall = {
	{ x = 32091, y = 32575, z = 8 },
	{ x = 32091, y = 32576, z = 8 },
	{ x = 32091, y = 32577, z = 8 },
}
local energyBarrier = MoveEvent()

function energyBarrier.onStepIn(creature, item, position, fromPosition)
	return true
end

for a = 1, #energyWall do
	energyBarrier:position(energyWall[a])
end
energyBarrier:register()
