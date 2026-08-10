local GraphNode = require(script.Parent:WaitForChild("GraphNode"))

local OutputNode = GraphNode:new()
OutputNode.name = "OutputNode"
OutputNode._type = "OutputNode"

function OutputNode:evaluate(volumes, terrain, ctx)
	local n = ctx.node
	local debugString = ctx.debugString
	-- Branch order does not affect placement results: intersection avoidance is
	-- resolved globally after all branches run (see OccupancyStore). Priority is
	-- set per rule on the PlaceGeometryOnPoints node.
	for _, wire in pairs(n:GetChildren()) do
		if wire:IsA("ObjectValue") then
			if wire.Value == nil then
				warn("missing value in OutputNode wire " .. wire.Name)
			end
			-- This is where a rule gets its identity: the entry naming the chain
			-- is the one thing that knows which rule this is. It goes down with
			-- the call, so the terminal can stamp and record every placement
			-- under it and every node in the chain is excluded from the volumes
			-- aimed at this rule.
			ctx.evaluateNode(wire.Value, volumes, terrain, debugString, wire)
		end
	end
	return nil
end

return OutputNode
