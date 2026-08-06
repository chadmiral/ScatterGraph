--[[
	AttributeSchema

	Which values each node type takes, in the order the Rules window shows them,
	and what kind of editor each one needs. This is the one place that knows
	RotationType is a fixed set of strings rather than free text, or that Radius
	may be cleared because the runtime defaults it.

	A value is usually an attribute of the node. It can instead be a wire -- a
	child ObjectValue of the same name -- which is how a node refers to an
	instance. PlaceGeometryOnPoints takes its geometry either way.

	Attributes a node carries that are not listed here still appear -- their
	editor is inferred from the value's type -- so an unrecognised node type, or
	an attribute added by hand, stays editable.

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
}

-- RotationType is matched literally in ScatterGraphHelpers: anything that is
-- not Random or UpAxis leaves the placement unrotated, so None is spelled out
-- rather than left as an empty box.
local ROTATION_TYPES = { "None", "UpAxis", "Random" }

local SCHEMA: { [string]: { Descriptor } } = {
	ScatterPoints = {
		{ name = "Seed", kind = "number", integer = true, default = 1 },
		{ name = "Spacing", kind = "number", default = 40 },
	},

	ScatterPointsAroundPoints = {
		{ name = "Seed", kind = "number", integer = true, default = 1 },
		{ name = "InnerRadius", kind = "number", default = 0 },
		{ name = "OuterRadius", kind = "number", default = 8 },
		{ name = "Count", kind = "number", integer = true, default = 10 },
	},

	SnapPointsToTerrain = {
		{ name = "MaterialFilter", kind = "string", default = "Water" },
		{ name = "SlopeFilter", kind = "numberSequence", default = NumberSequence.new(1, 0) },
	},

	PlaceGeometryOnPoints = {
		-- The two ways to say what gets placed, listed in the order the node
		-- resolves them: an in-scene template to clone wins over a published
		-- asset to load.
		{ name = "Asset", kind = "instance", source = "wire", wireNodeType = "Asset", optional = true },
		{ name = "GeometryAssetID", kind = "number", integer = true, optional = true, supersededBy = "Asset" },
		{
			name = "ScaleRange",
			kind = "vector2",
			optional = true,
			components = { "Min", "Max" },
			default = Vector2.new(1, 1),
		},
		{ name = "RotationType", kind = "choice", optional = true, choices = ROTATION_TYPES },
		{
			name = "ColorRange",
			kind = "colorSequence",
			optional = true,
			default = ColorSequence.new(Color3.new(1, 1, 1)),
		},
		{ name = "AvoidIntersections", kind = "boolean", optional = true },
		{ name = "Radius", kind = "number", optional = true, default = 5 },
		{ name = "Priority", kind = "number", integer = true, optional = true, default = 0 },
	},
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
		if name ~= "NodeType" and not covered[name] then
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

return AttributeSchema
