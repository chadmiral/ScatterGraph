local GraphNode = require(script.Parent:WaitForChild("GraphNode"))
local Helpers = require(script.Parent.Parent:WaitForChild("ScatterGraphHelpers"))

local SnapPointsToTerrainNode = GraphNode:new()
SnapPointsToTerrainNode.name = "SnapPointsToTerrainNode"
SnapPointsToTerrainNode._type = "SnapPointsToTerrainNode"

function SnapPointsToTerrainNode:evaluate(volumes, terrain, ctx)
	local n = ctx.node

	local materialFilter = n:GetAttribute("MaterialFilter")
	local slopeDensityCurve = n:GetAttribute("SlopeFilter")
	if materialFilter == nil or slopeDensityCurve == nil then
		warn("Missing parameters on node " .. n.Name)
	end

	local points = {}
	for _, wire in pairs(n:GetChildren()) do
		if wire:IsA("ObjectValue") and wire.Name == "Points" then
			points = ctx.evaluateNode(wire.Value, volumes, terrain, ctx.debugString)
		end
	end

	points = Helpers.excludePoints(points, ctx.exclusionFunctions)

	-- Thinned after the snap, though the texture being flat means it would come to
	-- the same thing before it: what changes is that the snap has already dropped
	-- whatever missed the terrain or failed its filters.
	local snapped = Helpers.snapPointsToTerrain(volumes, terrain, points, materialFilter, slopeDensityCurve)
	return Helpers.filterByDensity(snapped, Helpers.readDensity(n, volumes, terrain, ctx))
end

return SnapPointsToTerrainNode
