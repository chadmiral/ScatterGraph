--[[
	DataTypes

	What travels along a wire, and what colour that is on the canvas.

	A graph carries more than one kind of thing between its nodes:

	* Points, a cloud of positions, which is what the scattering and filtering
	  nodes pass between themselves.
	* Instances, the geometry a rule has placed in the world, which is what a
	  terminal node hands to the Output registry.
	* A 2D SDF grid, a shape on the ground measured onto a rectangle of cells as
	  the distance to its edge, seen from above. Material SDF 2D makes one, and
	  SDF Threshold cuts one into a texture.
	* A 2D texture, a greyscale image laid over the ground. The scattering nodes
	  read one as a density: the chance a candidate point survives where it
	  stands.
	* A number, a single value one node settles and another reads -- a threshold
	  distance being the first of them. A number port left unwired stands at its
	  own default rather than at nothing.

	None of them are interchangeable -- a filter has nothing to say about a
	placed model, and the Output registry has nothing to place a bare point with
	-- so a port says which of them it is, in the one colour that means that
	everywhere it is drawn.

	This is also where a node's ports themselves are declared: which slots it
	reads, in the order they are drawn down the left of its card, and what each
	one takes. The view builds its ports from these and the runtime reads the
	wires they make by name, so a node gaining an input is a line here rather
	than an edit in both.

	A node type this module has never heard of has no type and no slots rather
	than wrong ones: it is drawn as a card with a grey port and nothing wires
	into it.
]]

local DataTypes = {}

export type DataType = "Points" | "Instances" | "SDFGrid2D" | "Texture2D" | "Number"

local POINTS: DataType = "Points"
local INSTANCES: DataType = "Instances"
local SDF_GRID_2D: DataType = "SDFGrid2D"
local TEXTURE_2D: DataType = "Texture2D"
local NUMBER: DataType = "Number"

DataTypes.POINTS = POINTS
DataTypes.INSTANCES = INSTANCES
DataTypes.SDF_GRID_2D = SDF_GRID_2D
DataTypes.TEXTURE_2D = TEXTURE_2D
DataTypes.NUMBER = NUMBER

-- One slot down the left of a node's card, and the wire dropped on it.
export type Slot = {
	-- The child ObjectValue a wire into this slot is held as. A repeated slot has
	-- no name of its own: each of its wires is named after what it registers.
	name: string?,
	-- What the canvas writes beside the port, where the wire's name reads poorly.
	label: string?,
	dataType: DataType,
	-- The NodeType stamped on the wire. Usually the data type it carries, but the
	-- Output registry's entries were named for the node they point at before any
	-- of this was typed, and every graph in existence still has them that way.
	wireNodeType: string,
	-- One slot per wire already there, plus an empty one to add another, rather
	-- than the single slot a named entry describes.
	repeated: boolean?,
}

-- What a node hands downstream, by NodeType. The scattering and filtering nodes
-- make points; the terminal node turns them into geometry, and so passes
-- instances on to the Output registry. Output produces nothing -- it is where
-- the graph ends -- and so has no port to colour.
local PRODUCES: { [string]: DataType } = {
	ScatterPoints = POINTS,
	ScatterPointsAroundPoints = POINTS,
	SnapPointsToTerrain = POINTS,
	PlaceGeometryOnPoints = INSTANCES,
	MaterialSDF2D = SDF_GRID_2D,
	SDFThreshold2D = TEXTURE_2D,
	NoiseTexture2D = TEXTURE_2D,
	Number = NUMBER,
}

-- The density every point-producing node takes: a texture saying how much of a
-- scatter survives where. Declared once, since they all read it the same way and
-- their slots have to be named the same for it.
local DENSITY_SLOT: Slot = { name = "Density", dataType = TEXTURE_2D, wireNodeType = TEXTURE_2D }

-- What a node reads, by NodeType, in the order the slots are drawn. A node with
-- no entry here reads nothing: a note is not a working node at all.
local INPUTS: { [string]: { Slot } } = {
	-- Where a chain starts, and so the only node here that reads no points.
	ScatterPoints = {
		DENSITY_SLOT,
	},

	ScatterPointsAroundPoints = {
		{ name = "Points", dataType = POINTS, wireNodeType = POINTS },
		DENSITY_SLOT,
	},

	SnapPointsToTerrain = {
		{ name = "Points", dataType = POINTS, wireNodeType = POINTS },
		DENSITY_SLOT,
	},

	-- A field and where to cut it. The distance is a slot rather than a number on
	-- the node so that several rules can be cut at one distance by wiring them all
	-- to the same Number.
	SDFThreshold2D = {
		{ name = "SDF", label = "SDF", dataType = SDF_GRID_2D, wireNodeType = SDF_GRID_2D },
		{ name = "Distance", dataType = NUMBER, wireNodeType = NUMBER },
	},

	PlaceGeometryOnPoints = {
		{ name = "Points", dataType = POINTS, wireNodeType = POINTS },
	},

	-- The registry holds one entry per rule, so its slots are made as rules are
	-- registered rather than declared here.
	Output = {
		{ dataType = INSTANCES, wireNodeType = "OutputNode", repeated = true },
	},
}

-- Fixed rather than theme colours, for the same reason the title bars are: they
-- say what kind of data this is, not which part of the window it is. Bright
-- enough to read at ten pixels against either Studio theme's card.
local COLORS: { [string]: Color3 } = {
	Points = Color3.fromRGB(82, 152, 236),
	Instances = Color3.fromRGB(92, 184, 108),
	SDFGrid2D = Color3.fromRGB(226, 192, 68),
	Texture2D = Color3.fromRGB(232, 110, 96),
	Number = Color3.fromRGB(176, 138, 220),
}

-- A port whose type is not known: grey, so it reads as unlabelled rather than
-- as one of the types it is not.
local UNTYPED = Color3.fromRGB(150, 150, 150)

-- How a type is named in prose, for the tooltips that say what a port carries.
local LABELS: { [string]: string } = {
	Points = "points",
	Instances = "instances",
	SDFGrid2D = "2D SDF grid",
	Texture2D = "2D texture",
	Number = "number",
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

-- The slots down the left of this node, in order. Empty for a node that reads
-- nothing, and for one this module has never heard of.
function DataTypes.inputsOf(node: Instance): { Slot }
	local nodeType = nodeTypeOf(node)
	return (if nodeType ~= nil then INPUTS[nodeType] else nil) or {}
end

return DataTypes
