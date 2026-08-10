--[[
	DataTypes

	What travels along a wire, and what colour that is on the canvas.

	A graph carries more than one kind of thing between its nodes. Points are a
	cloud of positions, which is what the scattering and filtering nodes pass
	between themselves. Instances are the geometry a rule has placed in the
	world, which is what a terminal node hands to the Output registry. The two
	are not interchangeable -- a filter has nothing to say about a placed model,
	and the Output registry has nothing to place a bare point with -- so a port
	says which of them it is, in the one colour that means that everywhere it
	is drawn.

	This is the one place that knows which node produces or reads which type.
	The nodes themselves read their input by wire name and the evaluator passes
	whatever the upstream node returned, so nothing downstream of here has to
	agree; what a type buys is a canvas that can be read, and the ground for
	checking a connection before it is made.

	A node type this module has never heard of has no type rather than a wrong
	one: its ports are drawn untyped and keep working as they did.
]]

local DataTypes = {}

export type DataType = "Points" | "Instances"

local POINTS: DataType = "Points"
local INSTANCES: DataType = "Instances"

DataTypes.POINTS = POINTS
DataTypes.INSTANCES = INSTANCES

-- What a node hands downstream, by NodeType. Only the scattering and filtering
-- nodes make points; the terminal node turns them into geometry, and so passes
-- instances on to the Output registry. Output produces nothing -- it is where
-- the graph ends -- and so has no port to colour.
local PRODUCES: { [string]: DataType } = {
	ScatterPoints = POINTS,
	ScatterPointsAroundPoints = POINTS,
	SnapPointsToTerrain = POINTS,
	PlaceGeometryOnPoints = INSTANCES,
}

-- What a node's input slots take, by NodeType. One type per node rather than
-- one per slot, because the only node with more than one slot is the Output
-- registry and every slot on it registers a rule. A node that comes to take two
-- different types will want this keyed by slot as well.
local ACCEPTS: { [string]: DataType } = {
	ScatterPointsAroundPoints = POINTS,
	SnapPointsToTerrain = POINTS,
	PlaceGeometryOnPoints = POINTS,
	Output = INSTANCES,
}

-- Fixed rather than theme colours, for the same reason the title bars are: they
-- say what kind of data this is, not which part of the window it is. Bright
-- enough to read at ten pixels against either Studio theme's card.
local COLORS: { [string]: Color3 } = {
	Points = Color3.fromRGB(82, 152, 236),
	Instances = Color3.fromRGB(92, 184, 108),
}

-- A port whose type is not known: grey, so it reads as unlabelled rather than
-- as one of the types it is not.
local UNTYPED = Color3.fromRGB(150, 150, 150)

-- How a type is named in prose, for the tooltips that say what a port carries.
local LABELS: { [string]: string } = {
	Points = "points",
	Instances = "instances",
}

function DataTypes.color(dataType: DataType?): Color3
	return if dataType ~= nil then COLORS[dataType] or UNTYPED else UNTYPED
end

function DataTypes.label(dataType: DataType?): string
	return if dataType ~= nil then LABELS[dataType] or "data" else "data"
end

-- A node's type as this module reads it: the NodeType attribute, when it is
-- there and is a string. Nodes are edited in the Explorer as readily as in
-- either window, so it may be neither.
local function nodeTypeOf(node: Instance): string?
	local nodeType = node:GetAttribute("NodeType")
	return if typeof(nodeType) == "string" then nodeType else nil
end

-- What comes out of this node's right-hand port, or nil if it has none.
function DataTypes.producedBy(node: Instance): DataType?
	local nodeType = nodeTypeOf(node)
	return if nodeType ~= nil then PRODUCES[nodeType] else nil
end

-- What this node's input slots take, or nil if it reads nothing.
function DataTypes.acceptedBy(node: Instance): DataType?
	local nodeType = nodeTypeOf(node)
	return if nodeType ~= nil then ACCEPTS[nodeType] else nil
end

return DataTypes
