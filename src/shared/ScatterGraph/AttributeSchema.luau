--[[
	AttributeSchema

	Which values each node type takes, in the order the panels show them,
	and what kind of editor each one needs. This is the one place that knows
	SlopeFilter wants a curve rather than a number, or that Radius may be cleared
	because the runtime defaults it.

	A value is usually an attribute of the node. It can instead be a wire -- a
	child ObjectValue of the same name -- which is how a node refers to an
	instance. PlaceGeometryOnPoints takes its geometry either way. A wire named
	here is a reference into the scene and is edited as a row; the wires between
	two nodes are ports on the canvas instead, and are declared in DataTypes.

	A value and a port can be two ways of saying one thing, and where they are the
	range nodes' A and B they share a name: the port wins, and supersededBy is how
	the row knows to say it is being ignored.

	Attributes a node carries that are not listed here still appear -- their
	editor is inferred from the value's type -- so an unrecognised node type, or
	an attribute added by hand, stays editable. The exceptions are the few
	attributes that are bookkeeping rather than parameters, which are hidden.

	Required attributes cannot be cleared. The nodes only warn when one is
	missing and then carry on into an error or an empty result, which is a poor
	thing to be one stray keystroke away from.
]]

local AttributeSchema = {}

export type Descriptor = {
	name: string,
	-- What the panel row is titled, when the attribute's own name reads poorly
	-- there. The name is still what the value is read and written as.
	label: string?,
	-- number | string | choice | boolean | vector2 | vector3 | numberSequence |
	-- colorSequence | instance | readOnly
	kind: string,
	-- Set to "packages" to edit this value through the palette browser rather
	-- than a caret.
	browser: string?,
	-- Where the value lives. Attributes are the usual case; a wire is a child
	-- ObjectValue of the same name, which is how a node points at an instance.
	source: ("attribute" | "wire")?,
	-- NodeType to stamp on a wire this window creates.
	wireNodeType: string?,
	optional: boolean?,
	integer: boolean?,
	choices: { string }?,
	-- Component labels for vector2 and vector3, in axis order.
	components: { string }?,
	-- What a cleared or missing attribute starts at when the editor needs a
	-- value to work from.
	default: any?,
	-- Name of a wire that takes precedence over this attribute at evaluation
	-- time, so the row can say when it is being ignored.
	supersededBy: string?,
	-- What a panel row shows on hover. Condensed from the node reference in
	-- ScatterGraph-Rules.md, which stays the fuller account of the two.
	description: string?,
}

-- The two ends of a range node's range, which may be typed here or wired as
-- ports. The wire outranks the value, which is what supersededBy says: the row
-- greys itself out and marks itself unused while a wire is attached. Both are
-- optional -- an end with neither set stands at no change -- and the three nodes
-- differ only in what kind of value an end is.
local function rangeEnds(kind: string, default: any, what: string): { Descriptor }
	local ends = {}

	for _, slot in { "A", "B" } do
		table.insert(ends, {
			name = slot,
			kind = kind,
			optional = true,
			default = default,
			supersededBy = slot,
			description = what .. " Ignored while something is wired to the " .. slot .. " port, which says "
				.. "the same thing in a way several nodes can share.",
		})
	end

	return ends
end

local SCHEMA: { [string]: { Descriptor } } = {
	ScatterPoints = {
		{
			name = "Seed",
			kind = "number",
			integer = true,
			default = 1,
			description = "Random seed. Sets the jitter within each grid cell, and seeds the stream that "
				.. "downstream nodes draw from for scale, rotation and the slope filter.",
		},
		{
			name = "Spacing",
			kind = "number",
			default = 40,
			description = "Target minimum distance between points, in studs. One point is generated per "
				.. "grid cell, and the cell is Spacing / sqrt(2) across.",
		},
	},

	ScatterPointsAroundPoints = {
		{
			name = "Seed",
			kind = "number",
			integer = true,
			default = 1,
			description = "Random seed for the cluster offsets.",
		},
		{
			name = "InnerRadius",
			kind = "number",
			default = 0,
			description = "Minimum horizontal distance from the seed point, in studs. Zero fills the disc "
				.. "rather than leaving a hole in the middle of the cluster.",
		},
		{
			name = "OuterRadius",
			kind = "number",
			default = 8,
			description = "Maximum horizontal distance from the seed point, in studs. Must be at least "
				.. "InnerRadius.",
		},
		{
			name = "Count",
			kind = "number",
			integer = true,
			default = 10,
			description = "How many points to generate around each upstream point. Offsets that land "
				.. "outside the volume are dropped, so clusters near an edge come out smaller.",
		},
	},

	SnapPointsToTerrain = {
		{
			name = "MaterialFilter",
			kind = "string",
			default = "Water",
			description = "Comma-separated list of terrain materials to reject, such as Water,Ice,Snow. "
				.. "A point landing on one of them is discarded.",
		},
		{
			name = "SlopeFilter",
			kind = "numberSequence",
			default = NumberSequence.new(1, 0),
			description = "Maps terrain slope to the chance of keeping a point: time 0 is flat ground and "
				.. "1 is vertical. NumberSequence.new(1, 0) is full density on the flat and none on a wall.",
		},
	},

	Number = {
		{
			name = "Value",
			kind = "number",
			default = 0,
			description = "The number this node hands to everything wired to it, such as the Mask Distance "
				.. "of one or more rules.",
		},
	},

	Vector3 = {
		{
			name = "Value",
			kind = "vector3",
			default = Vector3.zero,
			description = "The three numbers this node hands to everything wired to it, such as one end of "
				.. "a scale or an offset range.",
		},
	},

	Rotation = {
		{
			name = "Angles",
			kind = "vector3",
			default = Vector3.zero,
			components = { "X", "Y", "Z" },
			description = "The turn this node hands on, in degrees about X, then Y, then Z -- the order "
				.. "Studio's own Orientation box reads in. A range between two rotations is drawn axis by "
				.. "axis between the angles typed here, so 0 to 360 about Y is a full random spin.",
		},
	},

	SetRotationRange = rangeEnds(
		"vector3",
		Vector3.zero,
		"One end of the turn, in degrees about X, then Y, then Z. Each axis is drawn between the two ends "
			.. "on its own, so 0 to 360 about Y is a full random spin."
	),

	SetScaleRange = rangeEnds(
		"number",
		1,
		"One end of the size. One number rather than three, since a model can only be scaled evenly."
	),

	SetTranslationOffsetRange = rangeEnds(
		"vector3",
		Vector3.zero,
		"One corner of the offset, in studs. Each axis is drawn between the two ends on its own, so the "
			.. "offsets fill the box the two corners describe."
	),

	MaterialSDF2D = {
		{
			name = "Materials",
			kind = "string",
			default = "Water",
			description = "Comma-separated list of terrain materials to measure from, such as Water,Sand. "
				.. "The field it outputs holds the distance from every cell of ground to the nearest "
				.. "ground whose surface is one of them, negative on the material itself.",
		},
		{
			name = "VoxelSize",
			label = "Voxel Size",
			kind = "number",
			optional = true,
			default = 4,
			description = "The edge of one cell of the field, in studs. Four is the grid terrain keeps "
				.. "material on, and so the finest the material itself is known to; smaller sharpens the "
				.. "distances around it, larger is coarser and cheaper. The volumes being scattered set "
				.. "what ground the field covers.",
		},
	},

	NoiseTexture2D = {
		{
			name = "Scale",
			kind = "number",
			optional = true,
			default = 64,
			description = "How wide one blotch of the noise is, in studs. Larger is broader patchiness "
				.. "across a biome; smaller breaks the scatter up more finely, down to about the cell "
				.. "size, past which there is no pattern left to see.",
		},
		{
			name = "Phase",
			kind = "number",
			optional = true,
			default = 0,
			description = "Which slice of the noise this is. Two nodes at the same Scale and different "
				.. "Phases give unrelated patterns over the same ground, so two rules can thin out "
				.. "independently rather than in step.",
		},
		{
			name = "VoxelSize",
			label = "Voxel Size",
			kind = "number",
			optional = true,
			default = 4,
			description = "The edge of one cell of the texture, in studs. Only worth changing for a "
				.. "Scale near it, where the pattern is finer than the cells can carry.",
		},
	},

	-- Both of its parameters arrive over wires, so it has none of its own.
	SDFThreshold2D = {},

	-- Nothing to set: what a reroute passes on is whatever is wired into it.
	Reroute = {},

	-- Nothing to set on either merge either. What they hand on is everything
	-- wired into them, and how many that is is said by the wires themselves
	-- rather than by anything here.
	MergePoints = {},
	MergeInstances = {},

	PlaceGeometryOnPoints = {
		-- The asset placed at each point. The runtime still accepts an in-scene
		-- template through a child ObjectValue named Asset, but that path is not
		-- surfaced here: the panel offers only the published asset, titled Asset,
		-- and the value itself is the GeometryAssetID attribute.
		{
			name = "GeometryAssetID",
			label = "Asset",
			kind = "number",
			integer = true,
			optional = true,
			-- An id is not something anyone types from memory, so this field opens
			-- the palette browser instead of a caret.
			browser = "packages",
			description = "The asset placed at each point. Click to pick from the palette in "
				.. "ReplicatedStorage.ScatterGraphPalette, or type an id into that window's search box.",
		},
		{
			name = "ColorRange",
			kind = "colorSequence",
			optional = true,
			default = ColorSequence.new(Color3.new(1, 1, 1)),
			description = "Random tint across the mesh parts of each instance, sampled anywhere along the "
				.. "sequence. A part tagged NoTint keeps its own colour.",
		},
		{
			name = "AvoidIntersections",
			kind = "boolean",
			optional = true,
			description = "When set, an instance is dropped rather than placed where its footprint would "
				.. "overlap one already kept -- including footprints from other rules and other volumes.",
		},
		{
			name = "Radius",
			kind = "number",
			optional = true,
			default = 5,
			description = "The footprint used for that test: a horizontal circle in studs. Two placements "
				.. "clash when their centres are closer than the sum of their radii.",
		},
		{
			name = "Priority",
			kind = "number",
			integer = true,
			optional = true,
			default = 0,
			description = "Which rule wins ground two of them contest: the lower number is kept, so 0 "
				.. "outranks everything. Does nothing unless AvoidIntersections is set.",
		},
	},

	ParentInstancesTo = {
		-- A reference into the place, so a child ObjectValue rather than an
		-- attribute -- an attribute cannot hold one. Required: a node with nowhere
		-- to put anything has nothing to do, and saying so on the card beats
		-- leaving an author to wonder why a rule's geometry has not moved.
		{
			name = "Parent",
			kind = "instance",
			source = "wire",
			description = "Where the instances are moved to. Select it in Studio, then set it here. "
				.. "It must be something in this place, so a graph carrying this node only works "
				.. "where that exists.",
		},
	},
}

-- Attributes that are not parameters of the node. NodeType is what makes it a
-- node in the first place, and GraphPosition is where the Graph view's canvas
-- last saw it dragged to; neither belongs in a list of values to tune.
local HIDDEN = {
	NodeType = true,
	GraphPosition = true,
}

local KIND_BY_TYPE = {
	number = "number",
	boolean = "boolean",
	string = "string",
	Vector2 = "vector2",
	Vector3 = "vector3",
	NumberSequence = "numberSequence",
	ColorSequence = "colorSequence",
}

-- An attribute the schema does not describe is still editable, just without
-- knowing whether it is required or what its choices are.
function AttributeSchema.infer(name: string, value: any): Descriptor
	return {
		name = name,
		kind = KIND_BY_TYPE[typeof(value)] or "readOnly",
		optional = true,
	}
end

-- Every row to show for a node: the attributes its type is known to take,
-- whether or not they are set, followed by anything else it happens to carry.
function AttributeSchema.rowsFor(node: Instance): { Descriptor }
	local rows = {}
	local covered = {}

	for _, descriptor in SCHEMA[node:GetAttribute("NodeType")] or {} do
		table.insert(rows, descriptor)
		covered[descriptor.name] = true
	end

	local extras = {}
	for name, value in node:GetAttributes() do
		if not HIDDEN[name] and not covered[name] then
			table.insert(extras, AttributeSchema.infer(name, value))
		end
	end

	table.sort(extras, function(a, b)
		return a.name < b.name
	end)

	for _, descriptor in extras do
		table.insert(rows, descriptor)
	end

	return rows
end

-- What a node is missing that it cannot evaluate without, as a list of plain
-- descriptions, empty when the node is complete. A required value is one the
-- schema does not mark optional; a wire is missing unless it both exists and
-- points at something. This is what the Graph view flags with a red border and
-- a warning badge, rather than letting the node warn and carry on into an error
-- or an empty result at evaluation time.
-- PlaceGeometryOnPoints places whatever its Asset row points at. The panel
-- sets that as the GeometryAssetID attribute, but the runtime still honours a
-- child ObjectValue named Asset set by hand in the Explorer, so a node with
-- either is complete and only a node with neither is flagged.
local function geometryUnset(node: Instance): boolean
	local assetWire = node:FindFirstChild("Asset")
	local hasAsset = assetWire ~= nil and assetWire:IsA("ObjectValue") and assetWire.Value ~= nil
	local hasAssetId = node:GetAttribute("GeometryAssetID") ~= nil
	return not hasAsset and not hasAssetId
end

-- Does this one row leave the node unable to evaluate? Either a required
-- parameter that is unset, or -- for PlaceGeometryOnPoints -- the Asset row
-- while nothing at all is set. The parameter panel outlines the box this
-- returns true for; issues below reports it in words.
function AttributeSchema.isMissing(node: Instance, descriptor): boolean
	local nodeType = node:GetAttribute("NodeType")

	if nodeType == "PlaceGeometryOnPoints" and descriptor.name == "GeometryAssetID" then
		return geometryUnset(node)
	end

	if descriptor.optional then
		return false
	end

	if descriptor.source == "wire" then
		local wire = node:FindFirstChild(descriptor.name)
		return not (wire ~= nil and wire:IsA("ObjectValue") and wire.Value ~= nil)
	end

	return node:GetAttribute(descriptor.name) == nil
end

function AttributeSchema.issues(node: Instance): { string }
	local issues = {}
	local nodeType = node:GetAttribute("NodeType")

	for _, descriptor in SCHEMA[nodeType] or {} do
		if AttributeSchema.isMissing(node, descriptor) then
			table.insert(issues, (descriptor.label or descriptor.name) .. " is not set.")
		end
	end

	return issues
end

return AttributeSchema
