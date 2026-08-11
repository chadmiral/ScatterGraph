--[[
	RerouteNode

	A bend in a wire. It reads one thing and hands that same thing on, whatever
	kind of thing it is, and exists for the canvas rather than the evaluation: a
	field shared by a dozen rules otherwise reaches them as a dozen wires drawn
	straight across everything in between, and a reroute or two lets those run
	where the author wants them to.

	Nothing here is a step in the work. Evaluating a reroute is evaluating what is
	behind it, so a chain with reroutes in it produces exactly what the same chain
	without them would -- including the rule a placement is recorded under, which
	the Output registry passes to whichever node its entry points at and which is
	therefore passed along here too.

	Deliberately not cached: a direct wire evaluated by two nodes evaluates what is
	behind it twice, and a reroute that only did it once would be a reroute that
	changed the answer.
]]

local GraphNode = require(script.Parent:WaitForChild("GraphNode"))
local Helpers = require(script.Parent.Parent:WaitForChild("ScatterGraphHelpers"))
local DataTypes = require(script.Parent.Parent:WaitForChild("DataTypes"))

local RerouteNode = GraphNode:new()
RerouteNode.name = "RerouteNode"
RerouteNode._type = "RerouteNode"

function RerouteNode:evaluate(volumes, terrain, ctx)
	local n = ctx.node

	local wire = Helpers.wireNamed(n, DataTypes.REROUTE_INPUT)
	if wire == nil or wire.Value == nil then
		warn(
			"ScatterGraph " .. n.Name .. ": nothing is wired into this reroute, so there is nothing for it to "
				.. "pass on to what it feeds."
		)
		return nil
	end

	return ctx.evaluateNode(wire.Value, volumes, terrain, ctx.debugString, ctx.rule)
end

return RerouteNode
