--[[
	RotationNode

	A turn, set on the node and read over a wire.

	Typed as three angles in degrees -- about X, then Y, then Z, the order
	Studio's own Orientation box reads in -- because nobody writes a quaternion by
	hand. It is a quaternion by the time it leaves this node, which is what lets
	the range between two of them mean one thing (see Rotation).

	The pair of these at the two ends of a Set Rotation Range is the usual way to
	use one: identity at A and a lean at B gives a scatter that tips further and
	further off vertical across the cloud.
]]

local GraphNode = require(script.Parent:WaitForChild("GraphNode"))
local Rotation = require(script.Parent.Parent:WaitForChild("Rotation"))

local RotationNode = GraphNode:new()
RotationNode.name = "RotationNode"
RotationNode._type = "RotationNode"

function RotationNode:evaluate(volumes, terrain, ctx)
	local n = ctx.node
	local angles = n:GetAttribute("Angles")

	if typeof(angles) ~= "Vector3" then
		warn("Missing parameters on node " .. n.Name)
		return nil
	end

	return Rotation.fromEulerDegrees(angles)
end

return RotationNode
