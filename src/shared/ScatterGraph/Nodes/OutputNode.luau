local GraphNode = require(script.Parent:WaitForChild("GraphNode"))
local PlacementLedger = require(script.Parent.Parent:WaitForChild("PlacementLedger"))

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
			-- This is where a rule gets its name: the entry naming the chain is
			-- the one thing that knows it. The identity is threaded down so the
			-- terminal can stamp and record every placement under it.
			local ruleKey, ruleName = PlacementLedger.ruleKey(wire)
			ctx.evaluateNode(wire.Value, volumes, terrain, debugString, ruleKey, ruleName)
		end
	end
	return nil
end

return OutputNode
