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
	* A 3D vector and a rotation, which are what a point carries besides its
	  position, and so what the nodes that set either of those read at both ends
	  of their range.

	Mostly they are not interchangeable -- a filter has nothing to say about a
	placed model, and the Output registry has nothing to place a bare point with
	-- so a port says which of them it is, in the one colour that means that
	everywhere it is drawn.

	Where one kind of thing does have an obvious reading as another, though,
	wiring it across is allowed and the reading is made on the way in: a number
	dropped on a slot that takes a texture is that value everywhere, an image of
	one flat shade. Those conversions are listed in CASTS below, and a wire making
	one is drawn as a sweep from the colour of what it comes out of to the colour
	of what it goes into, so the canvas says where a reading is being made.

	Reroute is the exception, and the reason a type is worked out here rather
	than looked up: it carries whichever of them is wired into it, so what it
	produces has to be followed back up its own wire -- through any number of
	further reroutes -- rather than read off its node type. Until something is
	wired to one it carries nothing, which is what lets it take anything.

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

export type DataType =
	"Points"
	| "Instances"
	| "SDFGrid2D"
	| "Texture2D"
	| "Number"
	| "Vector3"
	| "Rotation"

local POINTS: DataType = "Points"
local INSTANCES: DataType = "Instances"
local SDF_GRID_2D: DataType = "SDFGrid2D"
local TEXTURE_2D: DataType = "Texture2D"
local NUMBER: DataType = "Number"
local VECTOR3: DataType = "Vector3"
local ROTATION: DataType = "Rotation"

DataTypes.POINTS = POINTS
DataTypes.INSTANCES = INSTANCES
DataTypes.SDF_GRID_2D = SDF_GRID_2D
DataTypes.TEXTURE_2D = TEXTURE_2D
DataTypes.NUMBER = NUMBER
DataTypes.VECTOR3 = VECTOR3
DataTypes.ROTATION = ROTATION

-- One slot down the left of a node's card, and the wire dropped on it.
export type Slot = {
	-- The child ObjectValue a wire into this slot is held as. A repeated slot has
	-- no name of its own: each of its wires is named after what it registers.
	name: string?,
	-- What the canvas writes beside the port, where the wire's name reads poorly.
	label: string?,
	-- What the slot takes, or nil for a slot that takes anything: a Reroute's,
	-- before it carries something and so before it is anything in particular.
	dataType: DataType?,
	-- The NodeType stamped on the wire. Usually the data type it carries, but the
	-- Output registry's entries were named for the node they point at before any
	-- of this was typed, and every graph in existence still has them that way.
	-- Nil where the slot takes anything, and the wire is stamped with whatever
	-- turned out to be wired to it.
	wireNodeType: string?,
	-- One slot per wire already there, plus an empty one to add another, rather
	-- than the single slot a named entry describes.
	repeated: boolean?,
	-- What that empty one is called on the card, and what it says when pointed
	-- at. Only a repeated slot has one, and what it should say depends on what
	-- adding a wire to it means: another rule registered, or another thing
	-- merged in.
	newLabel: string?,
	newTooltip: string?,
}

-- The node that carries whatever is wired into it, and the slot it does that on.
-- Named here because working out what one is carrying means finding that wire.
local REROUTE = "Reroute"
local REROUTE_INPUT = "Input"

DataTypes.REROUTE_INPUT = REROUTE_INPUT

-- What a node hands downstream, by NodeType. The scattering and filtering nodes
-- make points; the terminal node turns them into geometry, and so passes
-- instances on to the Output registry. A merge produces whichever of the two it
-- merges, being several chains of that thing read as one. Output produces
-- nothing -- it is where the graph ends -- and so has no port to colour, and
-- Reroute produces whatever reaches it rather than anything of its own.
local PRODUCES: { [string]: DataType } = {
	ScatterPoints = POINTS,
	ScatterPointsAroundPoints = POINTS,
	SnapPointsToTerrain = POINTS,
	MergePoints = POINTS,
	PlaceGeometryOnPoints = INSTANCES,
	ParentInstancesTo = INSTANCES,
	MergeInstances = INSTANCES,
	MaterialSDF2D = SDF_GRID_2D,
	SDFThreshold2D = TEXTURE_2D,
	NoiseTexture2D = TEXTURE_2D,
	-- The four that read the ground itself. Nothing is wired into one: what they
	-- measure is the terrain under the volumes, which the run knows before the
	-- graph is walked, so they start a chain the way the noise texture does.
	TerrainHeight = TEXTURE_2D,
	TerrainSlope = TEXTURE_2D,
	TerrainAspect = TEXTURE_2D,
	TerrainCurvature = TEXTURE_2D,
	-- The four that do arithmetic on two of them, and so hand on the same kind of
	-- thing they read.
	TextureAdd = TEXTURE_2D,
	TextureSubtract = TEXTURE_2D,
	TextureMultiply = TEXTURE_2D,
	TextureDivide = TEXTURE_2D,
	Number = NUMBER,
	Vector3 = VECTOR3,
	Rotation = ROTATION,
	-- The three that vary a point between two ends hand the cloud straight on,
	-- with one part of every point in it settled.
	SetRotationRange = POINTS,
	SetScaleRange = POINTS,
	SetTranslationOffsetRange = POINTS,
}

-- The density every point-producing node takes: a texture saying how much of a
-- scatter survives where. Declared once, since they all read it the same way and
-- their slots have to be named the same for it.
local DENSITY_SLOT: Slot = { name = "Density", dataType = TEXTURE_2D, wireNodeType = TEXTURE_2D }

-- The two sides every texture operation reads, in the order A then B -- which for
-- the two that do not commute is the order the arithmetic is written in.
local TEXTURE_SIDES: { Slot } = {
	{ name = "A", dataType = TEXTURE_2D, wireNodeType = TEXTURE_2D },
	{ name = "B", dataType = TEXTURE_2D, wireNodeType = TEXTURE_2D },
}

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

	-- A cloud and the two ends to vary it between. Either end may be typed on the
	-- node instead of wired -- see AttributeSchema, where those rows are declared
	-- -- and the port wins where it is used, so that several rules can lean or
	-- shrink by the same amounts by being wired to one Rotation or one Number.
	SetRotationRange = {
		{ name = "Points", dataType = POINTS, wireNodeType = POINTS },
		{ name = "A", dataType = ROTATION, wireNodeType = ROTATION },
		{ name = "B", dataType = ROTATION, wireNodeType = ROTATION },
	},

	-- A number at either end rather than a vector: a model is scaled evenly or not
	-- at all, so two thirds of a vector could never be honoured.
	SetScaleRange = {
		{ name = "Points", dataType = POINTS, wireNodeType = POINTS },
		{ name = "A", dataType = NUMBER, wireNodeType = NUMBER },
		{ name = "B", dataType = NUMBER, wireNodeType = NUMBER },
	},

	SetTranslationOffsetRange = {
		{ name = "Points", dataType = POINTS, wireNodeType = POINTS },
		{ name = "A", dataType = VECTOR3, wireNodeType = VECTOR3 },
		{ name = "B", dataType = VECTOR3, wireNodeType = VECTOR3 },
	},

	-- The two sides of an arithmetic node, declared once because all four take
	-- them the same way. A Number may be wired to either, being read as a texture
	-- of that one shade -- which is how a mask is scaled by a figure several rules
	-- share.
	TextureAdd = TEXTURE_SIDES,
	TextureSubtract = TEXTURE_SIDES,
	TextureMultiply = TEXTURE_SIDES,
	TextureDivide = TEXTURE_SIDES,

	PlaceGeometryOnPoints = {
		{ name = "Points", dataType = POINTS, wireNodeType = POINTS },
	},

	-- Where it puts them is a reference into the place rather than a wire from
	-- another node, so it is declared as a parameter in AttributeSchema and is not
	-- a port here.
	ParentInstancesTo = {
		{ name = "Instances", dataType = INSTANCES, wireNodeType = INSTANCES },
	},

	-- The registry holds one entry per rule, so its slots are made as rules are
	-- registered rather than declared here.
	Output = {
		{
			dataType = INSTANCES,
			wireNodeType = "OutputNode",
			repeated = true,
			newLabel = "(new rule)",
			newTooltip = "An empty slot. Drop a wire here to register another rule with this Output.",
		},
	},

	-- However many chains are wired in, which is not for this to say: a merge is
	-- one slot per input and an empty one to add another, the way the registry is.
	MergePoints = {
		{
			dataType = POINTS,
			wireNodeType = POINTS,
			repeated = true,
			newLabel = "(add points)",
			newTooltip = "An empty slot. Drop a wire here to merge another node's points in.",
		},
	},

	MergeInstances = {
		{
			dataType = INSTANCES,
			wireNodeType = INSTANCES,
			repeated = true,
			newLabel = "(add instances)",
			newTooltip = "An empty slot. Drop a wire here to merge another node's instances in.",
		},
	},
}

--[[
	What may be wired into a slot that takes something else, by what the slot
	takes: the conversions with one obvious reading, made where the thing is read
	rather than here.

	A number becomes a texture of that one shade, which is how a density is set to
	a flat value -- half a chance over the whole biome -- and how one Number can
	set that for several rules at once.

	Nothing converts the other way. A texture read as a single number would have to
	choose which of its cells to believe, and the choice would be the node's rather
	than the wire's.
]]
local CASTS: { [DataType]: { [DataType]: boolean } } = {
	[NUMBER] = { [TEXTURE_2D] = true },
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
	Vector3 = Color3.fromRGB(84, 194, 188),
	Rotation = Color3.fromRGB(214, 124, 182),
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
	Vector3 = "3D vector",
	Rotation = "rotation",
}

function DataTypes.color(dataType: DataType?): Color3
	return if dataType ~= nil then COLORS[dataType] or UNTYPED else UNTYPED
end

function DataTypes.label(dataType: DataType?): string
	return if dataType ~= nil then LABELS[dataType] or "data" else "data"
end

-- Would a wire from something producing `produced` into a slot taking `wanted` be
-- read on the way in? False for a slot fed exactly what it takes, which is read as
-- itself, and false for a pairing with no reading at all.
function DataTypes.converts(produced: DataType?, wanted: DataType?): boolean
	if produced == nil or wanted == nil or produced == wanted then
		return false
	end

	local readings = CASTS[produced]
	return readings ~= nil and readings[wanted] == true
end

-- What else a slot taking `wanted` will read, for the tooltip that offers it.
-- Sorted, since a table's own order is not one and a tooltip that reorders itself
-- between two openings reads as two different tooltips.
function DataTypes.readInto(wanted: DataType?): { DataType }
	local found = {}

	if wanted ~= nil then
		for produced, readings in CASTS do
			if readings[wanted] then
				table.insert(found, produced)
			end
		end

		table.sort(found)
	end

	return found
end

-- May a wire be drawn at all: the slot takes exactly this, or takes something this
-- converts into. A nil at either end is one that says nothing about what it is --
-- an empty reroute's slot, or a node type this module has never heard of -- and
-- what cannot be told apart is not turned down.
function DataTypes.accepts(produced: DataType?, wanted: DataType?): boolean
	if produced == nil or wanted == nil then
		return true
	end

	return produced == wanted or DataTypes.converts(produced, wanted)
end

-- A node's type as this module reads it: the NodeType attribute, when it is
-- there and is a string. Nodes are edited in the Explorer as readily as in
-- either window, so it may be neither.
local function nodeTypeOf(node: Instance): string?
	local nodeType = node:GetAttribute("NodeType")
	return if typeof(nodeType) == "string" then nodeType else nil
end

-- What the given node's input wire points at, or nil where that slot is empty.
local function wiredTo(node: Instance, name: string): Instance?
	for _, child in node:GetChildren() do
		if child:IsA("ObjectValue") and child.Name == name then
			return child.Value
		end
	end

	return nil
end

--[[
	What comes out of a node, following a Reroute back up its wire to whatever
	actually produced the thing it is passing on.

	`seen` is the reroutes already walked through. A graph can only be wired into a
	loop by hand -- the canvas refuses to draw one -- but a loop reached from here
	would hang the window that is the means of unpicking it, so a reroute already
	visited is treated as carrying nothing rather than followed round again.
]]
local function producedWith(node: Instance, seen: { [Instance]: boolean }): DataType?
	local nodeType = nodeTypeOf(node)

	if nodeType == nil then
		return nil
	end

	if nodeType == REROUTE then
		if seen[node] then
			return nil
		end

		seen[node] = true

		local upstream = wiredTo(node, REROUTE_INPUT)
		return if upstream ~= nil then producedWith(upstream, seen) else nil
	end

	return PRODUCES[nodeType]
end

-- What comes out of this node's right-hand port, or nil if it has none -- which
-- is also a Reroute with nothing wired into it yet.
function DataTypes.producedBy(node: Instance): DataType?
	return producedWith(node, {})
end

-- What a node type makes, by declaration, before anything is wired to anything.
-- Nil for a type that has no answer of its own: a Reroute, which produces
-- whatever reaches it, or a type this module has never heard of. Asked by the
-- evaluation, which has a NodeType in hand rather than a node, and which wants
-- what the node itself makes rather than what it is passing on.
function DataTypes.producedByType(nodeType: string?): DataType?
	return if nodeType ~= nil then PRODUCES[nodeType] else nil
end

-- The slots down the left of this node, in order. Empty for a node that reads
-- nothing, and for one this module has never heard of.
function DataTypes.inputsOf(node: Instance): { Slot }
	local nodeType = nodeTypeOf(node)

	if nodeType == REROUTE then
		-- Its one slot is whatever it is carrying: untyped while it carries
		-- nothing, so anything may be dropped on it, and that type from then on,
		-- so what it feeds cannot be pulled out from under by re-aiming it at
		-- another kind of thing. Built here rather than declared, since the answer
		-- is different every time it is asked.
		local carried = DataTypes.producedBy(node)
		return { { name = REROUTE_INPUT, dataType = carried, wireNodeType = carried } }
	end

	return (if nodeType ~= nil then INPUTS[nodeType] else nil) or {}
end

return DataTypes
