local GraphNode = require(script.Parent:WaitForChild("GraphNode"))
local Helpers = require(script.Parent.Parent:WaitForChild("ScatterGraphHelpers"))

local PlaceGeometryOnPointsNode = GraphNode:new()
PlaceGeometryOnPointsNode.name = "PlaceGeometryOnPointsNode"
PlaceGeometryOnPointsNode._type = "PlaceGeometryOnPointsNode"

function PlaceGeometryOnPointsNode:evaluate(volume, terrain, ctx)
	local n = ctx.node
	local insertService = ctx.insertService

	local geo = nil
	local assetWire = n:FindFirstChild("Asset")
	if assetWire and assetWire:IsA("ObjectValue") and assetWire.Value ~= nil then
		geo = assetWire.Value
	else
		local geoAssetID = n:GetAttribute("GeometryAssetID")
		if geoAssetID ~= nil then
			geo = insertService:LoadAsset(geoAssetID):GetChildren()[1]
		else
			warn("PlaceGeometryOnPoints node " .. n.Name .. ": set ObjectValue Asset or GeometryAssetID")
		end
	end

	if geo ~= nil then
		local points = {}

		for _, wire in pairs(n:GetChildren()) do
			if wire:IsA("ObjectValue") and wire.Name == "Points" then
				if wire.Value == nil then
					warn("Missing Value in ObjectValue wire " .. wire.Name)
				end
				local newPoints = ctx.evaluateNode(wire.Value, volume, terrain, ctx.debugString)
				for _, p in newPoints do
					table.insert(points, p)
				end
			end
		end

		local scaleRange = n:GetAttribute("ScaleRange")
		local rotationType = n:GetAttribute("RotationType")
		local colorRange = n:GetAttribute("ColorRange")
		local avoidIntersections = n:GetAttribute("AvoidIntersections") == true
		local radius = n:GetAttribute("Radius") or 5
		local priority = n:GetAttribute("Priority") or 0

		points = Helpers.excludePoints(points, ctx.exclusionFunctions)
		-- The terminal node uniquely identifies this branch, so its own
		-- placements never reject one another during resolution.
		Helpers.placeGeoOnPoints(
			geo,
			points,
			scaleRange,
			colorRange,
			rotationType,
			ctx.instanceFolder,
			ctx.occupancy,
			avoidIntersections,
			radius,
			priority,
			n
		)
	end
end

return PlaceGeometryOnPointsNode
