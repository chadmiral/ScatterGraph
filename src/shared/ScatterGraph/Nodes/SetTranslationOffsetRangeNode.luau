--[[
	SetTranslationOffsetRangeNode

	Moves every point in a cloud by a random offset between the two vectors wired
	to A and B.

	Each axis is drawn on its own here, unlike the scale, because an offset
	between (-2, 0, -2) and (2, 0, 2) plainly means anywhere in that square. One
	draw for all three would put every point on the diagonal of it, which is a
	line rather than a range.

	This adds to where a point already is rather than replacing it, which is what
	makes it worth having after a snap: a scatter dropped onto the terrain and
	then lifted a stud or two stands just clear of the ground it was measured
	against. Where it sits in a chain is the whole of when it happens -- everything
	after it sees the moved point -- so a snap placed after one puts the point
	back on the ground and only the horizontal part of the offset survives.

	Moving a point moves what the plugin knows it by: hand edits are remembered
	against where a point stood (see PlacementLedger), so changing an offset
	rehouses the props of that rule rather than editing them in place, and any
	edits kept against the old positions are let go.
]]

local PointRangeNode = require(script.Parent:WaitForChild("PointRangeNode"))
local Point = require(script.Parent.Parent:WaitForChild("Point"))

local SetTranslationOffsetRangeNode = PointRangeNode:new()
SetTranslationOffsetRangeNode.name = "SetTranslationOffsetRangeNode"
SetTranslationOffsetRangeNode._type = "SetTranslationOffsetRangeNode"

SetTranslationOffsetRangeNode.sets = "position"
SetTranslationOffsetRangeNode.valueName = "3D vector"
-- Nowhere: an end left unwired is a range against no movement at all.
SetTranslationOffsetRangeNode.neutral = Vector3.zero

SetTranslationOffsetRangeNode.takes = function(value)
	return typeof(value) == "Vector3"
end

SetTranslationOffsetRangeNode.fromAttribute = function(raw)
	return if typeof(raw) == "Vector3" then raw else nil
end

SetTranslationOffsetRangeNode.between = function(a, b)
	return Vector3.new(
		a.X + (b.X - a.X) * math.random(),
		a.Y + (b.Y - a.Y) * math.random(),
		a.Z + (b.Z - a.Z) * math.random()
	)
end

SetTranslationOffsetRangeNode.settle = function(point, offset)
	return Point.movedTo(point, point.position + offset)
end

return SetTranslationOffsetRangeNode
