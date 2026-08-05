local GraphNode = require(script.Parent:WaitForChild("GraphNode"))
local Helpers = require(script.Parent.Parent:WaitForChild("ScatterGraphHelpers"))

local ScatterPointsAroundPointsNode = GraphNode:new()
ScatterPointsAroundPointsNode.name = "ScatterPointsAroundPointsNode"
ScatterPointsAroundPointsNode._type = "ScatterPointsAroundPointsNode"

function ScatterPointsAroundPointsNode:evaluate(volumes, terrain, ctx)
	local n = ctx.node

	local seed = n:GetAttribute("Seed")
	local innerRadius = n:GetAttribute("InnerRadius")
	local outerRadius = n:GetAttribute("OuterRadius")
	local count = n:GetAttribute("Count")
	if innerRadius == nil or outerRadius == nil or count == nil then
		warn("Missing Parameters on node " .. n.Name)
	end

	local points = {}
	for _, wire in pairs(n:GetChildren()) do
		if wire:IsA("ObjectValue") and wire.Name == "Points" then
			if wire.Value == nil then
				warn("missing Value in ObjectValue wire " .. wire.Name)
			end
			local newPoints = ctx.evaluateNode(wire.Value, volumes, terrain, ctx.debugString)
			for _, p in newPoints do
				table.insert(points, p)
			end
		end
	end

	points = Helpers.excludePoints(points, ctx.exclusionFunctions)
	return Helpers.scatterPointsAroundPoints(volumes, terrain, seed, points, count, innerRadius, outerRadius)
end

return ScatterPointsAroundPointsNode
