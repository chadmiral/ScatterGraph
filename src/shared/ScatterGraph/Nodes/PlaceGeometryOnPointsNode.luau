local GraphNode = require(script.Parent:WaitForChild("GraphNode"))
local Helpers = require(script.Parent.Parent:WaitForChild("ScatterGraphHelpers"))

local PlaceGeometryOnPointsNode = GraphNode:new()
PlaceGeometryOnPointsNode.name = "PlaceGeometryOnPointsNode"
PlaceGeometryOnPointsNode._type = "PlaceGeometryOnPointsNode"

-- Attributes this node used to place by, which a point now carries instead, and
-- the node that sets each of them.
local RETIRED = {
	{ name = "ScaleRange", instead = "Set Scale Range" },
	{ name = "RotationType", instead = "Set Rotation Range" },
}

function PlaceGeometryOnPointsNode:evaluate(volumes, terrain, ctx)
	local n = ctx.node
	local insertService = ctx.insertService

	-- What this node placed, which is what the instances it produces actually
	-- are. The Output registry does nothing with them -- reaching them is what
	-- makes the placement happen -- but a node between the two, ParentInstancesTo
	-- today, has them to work on.
	local placed = {}

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
				local newPoints = ctx.evaluateNode(wire.Value, volumes, terrain, ctx.debugString)
				for _, p in newPoints do
					table.insert(points, p)
				end
			end
		end

		local colorRange = n:GetAttribute("ColorRange")
		local avoidIntersections = n:GetAttribute("AvoidIntersections") == true
		local radius = n:GetAttribute("Radius") or 5
		local priority = n:GetAttribute("Priority") or 0

		-- How a placement is turned and sized is the point's to say, and used to
		-- be this node's. A graph written before that still carries the old
		-- attributes, and they are no longer read: worth saying once a run, since
		-- the alternative is a scatter that quietly stops varying.
		for _, retired in RETIRED do
			if n:GetAttribute(retired.name) ~= nil then
				warn(
					"ScatterGraph " .. n.Name .. ": its " .. retired.name .. " is no longer read. Use a "
						.. retired.instead .. " node upstream of it, and delete the attribute to stop this "
						.. "being said."
				)
			end
		end

		points = Helpers.excludePoints(points, ctx.exclusionFunctions)
		-- The rule identity threaded down from the Output entry lets each
		-- placement be stamped and recorded, and stands in for the branch id so
		-- a rule never rejects its own placements during resolution.
		placed = Helpers.placeGeoOnPoints(
			geo,
			points,
			colorRange,
			ctx.instanceFolder,
			ctx.occupancy,
			avoidIntersections,
			radius,
			priority,
			ctx.run,
			ctx.graphKey,
			ctx.ruleKey,
			ctx.ruleName
		)
	end

	return placed
end

return PlaceGeometryOnPointsNode
