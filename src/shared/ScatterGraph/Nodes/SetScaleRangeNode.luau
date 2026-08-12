--[[
	SetScaleRangeNode

	Sizes every point in a cloud somewhere between the two numbers at A and B.

	One number rather than three because a model can only be scaled evenly: Roblox
	scales it about its pivot, and there is no such thing as a model stretched
	along one axis. A range in three axes would be a range in two axes nothing
	could honour.

	What each point had before is replaced rather than multiplied by. Whatever a
	point carries when it reaches the terminal is the size it is placed at, and
	this is the only node that sets it.
]]

local PointRangeNode = require(script.Parent:WaitForChild("PointRangeNode"))
local Point = require(script.Parent.Parent:WaitForChild("Point"))

local SetScaleRangeNode = PointRangeNode:new()
SetScaleRangeNode.name = "SetScaleRangeNode"
SetScaleRangeNode._type = "SetScaleRangeNode"

SetScaleRangeNode.sets = "scale"
SetScaleRangeNode.valueName = "number"
-- Full size: an end with nothing at it is a range against the point's own size.
SetScaleRangeNode.neutral = 1

SetScaleRangeNode.takes = function(value)
	return typeof(value) == "number"
end

SetScaleRangeNode.fromAttribute = function(raw)
	return if typeof(raw) == "number" then raw else nil
end

SetScaleRangeNode.between = function(a, b)
	return a + (b - a) * math.random()
end

SetScaleRangeNode.settle = function(point, scale)
	return Point.sizedTo(point, scale)
end

return SetScaleRangeNode
