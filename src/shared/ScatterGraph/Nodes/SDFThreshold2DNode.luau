--[[
	SDFThreshold2DNode

	Cuts a distance field at a distance and hands back what is left as a
	[Texture2D]: white where the field reads at or beyond that distance, black where
	it reads short of it.

	This is what turns "how far is this spot from water" into "may anything grow
	here": a field measures the ground, and a density decides what happens on it.
	Wire a field in and a Distance beside it, and the texture is the ground far
	enough from the material -- keep the distance at zero for everywhere off it, put
	it up to hold a clearing around it, or take it negative to allow a little way
	onto it.

	The texture keeps the field's own cells, so nothing is resampled on the way
	through and the edge lands exactly where the field puts it. Reading between
	cells then leaves that edge soft by about a cell, which dithers the boundary
	rather than drawing a line across the scatter.
]]

local GraphNode = require(script.Parent:WaitForChild("GraphNode"))
local Helpers = require(script.Parent.Parent:WaitForChild("ScatterGraphHelpers"))
local SDFGrid2D = require(script.Parent.Parent:WaitForChild("SDFGrid2D"))
local Texture2D = require(script.Parent.Parent:WaitForChild("Texture2D"))

local SDFThreshold2DNode = GraphNode:new()
SDFThreshold2DNode.name = "SDFThreshold2DNode"
SDFThreshold2DNode._type = "SDFThreshold2DNode"

-- The slots this node reads, named as DataTypes declares them.
local FIELD_WIRE = "SDF"
local DISTANCE_WIRE = "Distance"

-- Where the cut falls while nothing is wired to it: on the boundary itself, which
-- keeps the ground off the material and nothing more.
local DEFAULT_DISTANCE = 0

function SDFThreshold2DNode:evaluate(volumes, terrain, ctx)
	local n = ctx.node

	-- Every rule reading this node asks it for the same texture.
	local cache = ctx.fieldCache
	if cache ~= nil and cache[n] ~= nil then
		return cache[n]
	end

	local fieldWire = Helpers.wireNamed(n, FIELD_WIRE)
	if fieldWire == nil or fieldWire.Value == nil then
		warn(
			"ScatterGraph " .. n.Name .. ": nothing is wired to its SDF slot, so there is no field to cut and "
				.. "no texture to hand on."
		)
		return nil
	end

	local grid = ctx.evaluateNode(fieldWire.Value, volumes, terrain, ctx.debugString)
	if not SDFGrid2D.is(grid) then
		warn(
			"ScatterGraph " .. n.Name .. ": its SDF slot points at " .. fieldWire.Value.Name
				.. ", which does not produce a distance field, so there is no texture to hand on."
		)
		return nil
	end

	local distance = DEFAULT_DISTANCE
	local distanceWire = Helpers.wireNamed(n, DISTANCE_WIRE)
	if distanceWire ~= nil and distanceWire.Value ~= nil then
		local value = ctx.evaluateNode(distanceWire.Value, volumes, terrain, ctx.debugString)

		if typeof(value) == "number" then
			distance = value
		else
			warn(
				"ScatterGraph " .. n.Name .. ": its Distance slot points at " .. distanceWire.Value.Name
					.. ", which does not produce a number, so the cut falls at " .. DEFAULT_DISTANCE .. "."
			)
		end
	end

	local distances = grid.distances
	local values = table.create(#distances)

	for i = 1, #distances do
		values[i] = if distances[i] >= distance then 1 else 0
	end

	-- The field doubles as the layout: it is what says where these cells are.
	local texture = Texture2D.fromCells(grid, values)

	if cache ~= nil then
		cache[n] = texture
	end

	return texture
end

return SDFThreshold2DNode
