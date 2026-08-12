--[[
	SetRotationRangeNode

	Turns every point in a cloud to somewhere between the two rotations wired to
	A and B.

	Each of the three axes is drawn on its own, between the two ends' angle for
	that axis, so a range says what an author means by one: (0,0,0) to (0,360,0)
	is a spin, and (0,0,0) to (20,90,0) is a lean of up to twenty degrees at any
	heading in a quarter turn rather than only the leans that pair with one
	heading. See Rotation, which holds both the turn and the angles it was
	authored from for exactly this.

	What each point had before is replaced rather than added to: this says which
	way these points face, not which way to turn them from wherever they were.

	Three draws per point, one an axis, which is why a range with two of its axes
	fixed still costs the same as one that varies all three -- the alternative is
	a random stream whose length depends on the angles typed into a node.
]]

local PointRangeNode = require(script.Parent:WaitForChild("PointRangeNode"))
local Rotation = require(script.Parent.Parent:WaitForChild("Rotation"))
local Point = require(script.Parent.Parent:WaitForChild("Point"))

local SetRotationRangeNode = PointRangeNode:new()
SetRotationRangeNode.name = "SetRotationRangeNode"
SetRotationRangeNode._type = "SetRotationRangeNode"

SetRotationRangeNode.sets = "rotation"
SetRotationRangeNode.valueName = "rotation"
SetRotationRangeNode.neutral = Rotation.identity
SetRotationRangeNode.takes = Rotation.is

-- Typed on the node as three angles in degrees, exactly as the Rotation node
-- takes them, so that the end wired and the end typed mean the same thing.
SetRotationRangeNode.fromAttribute = function(raw)
	return if typeof(raw) == "Vector3" then Rotation.fromEulerDegrees(raw) else nil
end

SetRotationRangeNode.between = function(a, b)
	return Rotation.mixed(a, b, math.random(), math.random(), math.random())
end

SetRotationRangeNode.settle = function(point, rotation)
	return Point.turnedTo(point, rotation)
end

return SetRotationRangeNode
