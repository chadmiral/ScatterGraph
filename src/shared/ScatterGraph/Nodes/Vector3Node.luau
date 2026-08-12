--[[
	Vector3Node

	Three numbers, set on the node and read over a wire. The Number node for
	anything with an X, a Y and a Z: a size, an offset, a lift off the ground.

	There is nothing to work out. It exists so that a vector several rules depend
	on can be one thing in one place -- the smallest a boulder is allowed to be,
	the height everything in a biome floats at -- rather than the same three
	figures typed into each of them.
]]

local GraphNode = require(script.Parent:WaitForChild("GraphNode"))

local Vector3Node = GraphNode:new()
Vector3Node.name = "Vector3Node"
Vector3Node._type = "Vector3Node"

function Vector3Node:evaluate(volumes, terrain, ctx)
	local n = ctx.node
	local value = n:GetAttribute("Value")

	if typeof(value) ~= "Vector3" then
		warn("Missing parameters on node " .. n.Name)
		return nil
	end

	return value
end

return Vector3Node
