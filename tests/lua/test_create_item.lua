-- Regression test for the God /i command.
-- Run from the repository root with: luajit tests/lua/test_create_item.lua

local registeredAction
local addedItem

function TalkAction()
	registeredAction = {}
	function registeredAction:separator() end
	function registeredAction:groupType() end
	function registeredAction:register() end
	return registeredAction
end

function logCommand() end

function string:split(separator)
	local values = {}
	for value in (self .. separator):gmatch("(.-)" .. separator) do
		table.insert(values, value)
	end
	return values
end

local trainingRod = {
	getId = function()
		return 28544
	end,
	getCharges = function()
		return 50
	end,
	isStackable = function()
		return false
	end,
	isFluidContainer = function()
		return false
	end,
}

function ItemType(identifier)
	if identifier == "training rod" or identifier == 28544 then
		return trainingRod
	end
	return {
		getId = function()
			return 0
		end,
	}
end

local player = {
	addItem = function(_, itemId, count)
		addedItem = {
			itemId = itemId,
			charges = count == 0 and 50 or count,
		}
		return {
			decay = function() end,
		}
	end,
	getPosition = function()
		return {
			sendMagicEffect = function() end,
		}
	end,
}

CONST_ME_MAGIC_GREEN = 1

dofile("data/scripts/talkactions/god/create_item.lua")

registeredAction.onSay(player, "/i", "training rod")

assert(addedItem.itemId == 28544)
assert(addedItem.charges == 50, "expected /i training rod to use its default 50 charges")

print("1 passed, 0 failed")
