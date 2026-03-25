local GraphNode = require(script.Parent:WaitForChild("GraphNode"))
local Helpers = require(script.Parent.Parent:WaitForChild("ScatterGraphHelpers"))

local SnapPointsToTerrainNode = GraphNode:new()
SnapPointsToTerrainNode.name = "SnapPointsToTerrainNode"
SnapPointsToTerrainNode._type = "SnapPointsToTerrainNode"

function SnapPointsToTerrainNode:evaluate(volume, terrain, ctx)
	local n = ctx.node

	local materialFilter = n:GetAttribute("MaterialFilter")
	local slopeDensityCurve = n:GetAttribute("SlopeFilter")
	if materialFilter == nil or slopeDensityCurve == nil then
		warn("Missing parameters on node " .. n.Name)
	end

	local points = {}
	for _, wire in pairs(n:GetChildren()) do
		if wire:IsA("ObjectValue") and wire.Name == "Points" then
			points = ctx.evaluateNode(wire.Value, volume, terrain, ctx.debugString)
		end
	end

	points = Helpers.excludePoints(points, ctx.exclusionFunctions)
	return Helpers.snapPointsToTerrain(volume, terrain, points, materialFilter, slopeDensityCurve)
end

return SnapPointsToTerrainNode
