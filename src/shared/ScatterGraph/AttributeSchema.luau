--[[
	AttributeSchema

	Which values each node type takes, in the order the panels show them,
	and what kind of editor each one needs. This is the one place that knows
	RotationType is a fixed set of strings rather than free text, or that Radius
	may be cleared because the runtime defaults it.

	A value is usually an attribute of the node. It can instead be a wire -- a
	child ObjectValue of the same name -- which is how a node refers to an
	instance. PlaceGeometryOnPoints takes its geometry either way.

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
	-- number | string | choice | boolean | vector2 | numberSequence |
	-- colorSequence | instance | readOnly
	kind: string,
	-- Where the value lives. Attributes are the usual case; a wire is a child
	-- ObjectValue of the same name, which is how a node points at an instance.
	source: ("attribute" | "wire")?,
	-- NodeType to stamp on a wire this window creates.
	wireNodeType: string?,
	optional: boolean?,
	integer: boolean?,
	choices: { string }?,
	-- Component labels for vector2, in X, Y order.
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

-- RotationType is matched literally in ScatterGraphHelpers: anything that is
-- not Random or UpAxis leaves the placement unrotated, so None is spelled out
-- rather than left as an empty box.
local ROTATION_TYPES = { "None", "UpAxis", "Random" }

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

	PlaceGeometryOnPoints = {
		-- The two ways to say what gets placed, listed in the order the node
		-- resolves them: an in-scene template to clone wins over a published
		-- asset to load.
		{
			name = "Asset",
			kind = "instance",
			source = "wire",
			wireNodeType = "Asset",
			optional = true,
			description = "The instance in the scene to clone at each point. Set from the Studio "
				.. "selection. Takes precedence over GeometryAssetID.",
		},
		{
			name = "GeometryAssetID",
			kind = "number",
			integer = true,
			optional = true,
			supersededBy = "Asset",
			-- An id is not something anyone types from memory, so this field opens
			-- the Packages browser instead of a caret.
			browser = "packages",
			description = "Published asset to load and clone instead of an in-scene template; the first "
				.. "child of the loaded asset is used. Click to pick from the packages this place uses, or "
				.. "type an id into that window's search box. Ignored while Asset is set.",
		},
		{
			name = "ScaleRange",
			kind = "vector2",
			optional = true,
			components = { "Min", "Max" },
			default = Vector2.new(1, 1),
			description = "Uniform scale, sampled per instance between Min and Max. Left unset, every "
				.. "instance is placed at its authored size.",
		},
		{
			name = "RotationType",
			kind = "choice",
			optional = true,
			choices = ROTATION_TYPES,
			description = "How each instance is turned. UpAxis is a random spin around world Y, which "
				.. "suits anything that grows upright; Random turns on all three axes; None leaves the "
				.. "placement as it comes.",
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
function AttributeSchema.issues(node: Instance): { string }
	local issues = {}
	local nodeType = node:GetAttribute("NodeType")

	for _, descriptor in SCHEMA[nodeType] or {} do
		if not descriptor.optional then
			local present
			if descriptor.source == "wire" then
				local wire = node:FindFirstChild(descriptor.name)
				present = wire ~= nil and wire:IsA("ObjectValue") and wire.Value ~= nil
			else
				present = node:GetAttribute(descriptor.name) ~= nil
			end

			if not present then
				table.insert(issues, descriptor.name .. " is not set.")
			end
		end
	end

	-- PlaceGeometryOnPoints has something to clone given either way -- an
	-- in-scene Asset wire or a published GeometryAssetID -- so each is optional
	-- on its own, but a node with neither places nothing.
	if nodeType == "PlaceGeometryOnPoints" then
		local assetWire = node:FindFirstChild("Asset")
		local hasAsset = assetWire ~= nil and assetWire:IsA("ObjectValue") and assetWire.Value ~= nil
		local hasAssetId = node:GetAttribute("GeometryAssetID") ~= nil

		if not hasAsset and not hasAssetId then
			table.insert(issues, "No geometry to place: set an Asset or a GeometryAssetID.")
		end
	end

	return issues
end

return AttributeSchema
