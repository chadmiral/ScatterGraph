--[[
	NumberNode

	A single number, set on the node and read over a wire. There is nothing to
	work out: the node exists so that a number a graph depends on can be one thing
	in one place, wired to every slot that should agree with it, rather than the
	same figure typed into each of them.

	A mask distance shared by several rules is what it is for. Change the node and
	every rule that reads it changes together.
]]

local GraphNode = require(script.Parent:WaitForChild("GraphNode"))

local NumberNode = GraphNode:new()
NumberNode.name = "NumberNode"
NumberNode._type = "NumberNode"

function NumberNode:evaluate(volumes, terrain, ctx)
	local n = ctx.node
	local value = n:GetAttribute("Value")

	if typeof(value) ~= "number" then
		warn("Missing parameters on node " .. n.Name)
		return nil
	end

	return value
end

return NumberNode
