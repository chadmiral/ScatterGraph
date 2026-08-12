--[[
	MergePointsNode

	Hands on every point wired into it, from as many chains as are. See MergeNode
	for how a merge works; this is that with points in it.

	Where this earns its place is between several scatters and one treatment of
	them. Points from two ScatterPoints nodes at different spacings, or a scatter
	and the clusters grown around it, become one cloud that is snapped to the
	ground once, thinned by one density and placed by one terminal -- rather than
	each chain carrying its own copy of that arrangement to be kept in step by
	hand.

	Points are not compared as they are merged. Two clouds over the same ground
	are two points wherever they land in the same spot, and the spacing a scatter
	is built to is its own rather than something the merge enforces across all of
	them: two scatters at forty studs merged into one are forty studs apart within
	each cloud and as close as they like between them. Spacing between merged
	clouds is what AvoidIntersections on the terminal is for.
]]

local MergeNode = require(script.Parent:WaitForChild("MergeNode"))

local MergePointsNode = MergeNode:new()
MergePointsNode.name = "MergePointsNode"
MergePointsNode._type = "MergePointsNode"
MergePointsNode.merges = "points"

return MergePointsNode
