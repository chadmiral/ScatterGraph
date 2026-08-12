--[[
	RuleTemplates

	The whole rules the plugin can add in one go, and the wiring that adds one.

	A rule is a chain: points are scattered, moved about, and finally something
	is placed at each of them, with an entry in the graph's Output registry
	naming the chain so the evaluator can find it. That is four nodes and four
	wires to build by hand, so the shapes worth starting from are kept here.

	Here rather than in either window because both offer them -- the Spreadsheet
	view as ribbon buttons, the Graph view in the menu the right button opens
	-- which is also why the label, icon and tooltip of each one belong to the
	template rather than to a button. Two windows offering the same rules under
	different names would be two rules as far as an author can tell.

	The values are a starting point only. A rule is not finished until its Asset
	wire has something to clone, and spacing and the filters are what an author
	actually tunes afterwards.
]]

local HttpService = game:GetService("HttpService")

local RuleTemplates = {}

-- The nodes shared between templates. Note that a node's name and its NodeType
-- are two different things, and two nodes here are deliberately named something
-- other than their type: the terminal is PlaceAssetOnPoints over a NodeType of
-- PlaceGeometryOnPoints, which is how the existing graphs have it, and the
-- clustering node is Cluster over ScatterPointsAroundPoints. The registry keys
-- off the attribute, so only the attribute has to stay put.
local SCATTER_POINTS = { name = "ScatterPoints", nodeType = "ScatterPoints", attributes = { Seed = 1, Spacing = 40 } }

local SNAP_TO_TERRAIN = {
	name = "SnapPointsToTerrain",
	nodeType = "SnapPointsToTerrain",
	attributes = { MaterialFilter = "Water", SlopeFilter = NumberSequence.new(1, 0) },
}

local PLACE_ASSET = {
	name = "PlaceAssetOnPoints",
	nodeType = "PlaceGeometryOnPoints",
	attributes = { ScaleRange = Vector2.new(0.9, 1.1), RotationType = "UpAxis" },
}

-- Each template is a chain listed source-first; every node is wired to the one
-- before it by a Points wire, and the last node is the terminal the Output entry
-- points at.
RuleTemplates.terrainProp = {
	ruleName = "TerrainProp",
	label = "Terrain Prop",
	icon = "\u{1F332}",
	tooltip = "Adds a rule that scatters points, drops them onto the terrain and places one asset at "
		.. "each: ScatterPoints, SnapPointsToTerrain, PlaceAssetOnPoints. Set its Asset to finish it.",
	nodes = { SCATTER_POINTS, SNAP_TO_TERRAIN, PLACE_ASSET },
}

-- The whole rule is Clustered Prop rather than Cluster, which is the single node
-- inside it that does the clustering. Both are offered in the one menu, the
-- rules above a line and the single nodes below it, and two entries called
-- Cluster in it would be a coin toss.
RuleTemplates.cluster = {
	ruleName = "ClusteredProp",
	label = "Clustered Prop",
	icon = "\u{1F33F}",
	tooltip = "Adds a rule that scatters points, spreads a clump around each one and drops those onto "
		.. "the terrain: ScatterPoints, Cluster, SnapPointsToTerrain, PlaceAssetOnPoints. Set its "
		.. "Asset to finish it.",
	nodes = {
		-- Cluster seeds are spaced further apart than a solo scatter, since
		-- each one fills in with Count points of its own.
		{ name = "ScatterPoints", nodeType = "ScatterPoints", attributes = { Seed = 1, Spacing = 60 } },
		{
			name = "Cluster",
			nodeType = "ScatterPointsAroundPoints",
			attributes = { Seed = 2, InnerRadius = 0, OuterRadius = 8, Count = 20 },
		},
		SNAP_TO_TERRAIN,
		PLACE_ASSET,
	},
}

RuleTemplates.floatingProp = {
	ruleName = "FloatingProp",
	label = "Floating Prop",
	icon = "\u{1F426}",
	tooltip = "Adds a rule that places an asset at each scattered point without consulting the "
		.. "terrain, for anything that hangs in the air: ScatterPoints, PlaceAssetOnPoints. Set its "
		.. "Asset to finish it.",
	-- No terrain snap, so points stay at the middle of the volume's vertical
	-- span. Rotation is unconstrained because nothing is standing on ground.
	nodes = {
		SCATTER_POINTS,
		{
			name = "PlaceAssetOnPoints",
			nodeType = "PlaceGeometryOnPoints",
			attributes = { ScaleRange = Vector2.new(0.9, 1.1), RotationType = "Random" },
		},
	},
}

-- The order both windows offer them in, simplest first.
RuleTemplates.ordered = {
	RuleTemplates.terrainProp,
	RuleTemplates.cluster,
	RuleTemplates.floatingProp,
}

local function makeWire(name: string, nodeType: string, value: Instance?): ObjectValue
	local wire = Instance.new("ObjectValue")
	wire.Name = name
	wire.Value = value
	wire:SetAttribute("NodeType", nodeType)
	return wire
end

-- Every rule ends at an entry in this, so anything that adds one needs it, and
-- a graph that has somehow lost it gets another rather than failing.
function RuleTemplates.findOutputRegistry(graph: Instance): Instance
	for _, child in graph:GetChildren() do
		if child:GetAttribute("NodeType") == "Output" then
			return child
		end
	end

	local registry = Instance.new("Model")
	registry.Name = "Output"
	registry:SetAttribute("NodeType", "Output")
	registry.Parent = graph
	return registry
end

-- Rule names have to be unique twice over: the rule folder sits under the graph
-- root and the registry entry under Output, and the two share the name.
local function uniqueRuleName(graph: Instance, registry: Instance, base: string): string
	local name = base
	local suffix = 1

	while graph:FindFirstChild(name) ~= nil or registry:FindFirstChild(name) ~= nil do
		suffix += 1
		name = base .. suffix
	end

	return name
end

-- Builds one template into a graph, returning the rule's name, the folder its
-- nodes went into, and those nodes in chain order -- which a caller that has
-- somewhere in mind for them needs, since the order is the order they read in.
--
-- The caller is responsible for the undo recording: a window usually has more to
-- put in the same one than this.
function RuleTemplates.add(graph: Instance, template): (string, Instance, { Instance })
	local registry = RuleTemplates.findOutputRegistry(graph)
	local ruleName = uniqueRuleName(graph, registry, template.ruleName)

	local folder = Instance.new("Folder")
	folder.Name = ruleName

	local made = {}
	local upstream = nil

	for _, spec in template.nodes do
		local node = Instance.new("Model")
		node.Name = spec.name
		for attribute, value in spec.attributes do
			node:SetAttribute(attribute, value)
		end
		node:SetAttribute("NodeType", spec.nodeType)

		if upstream ~= nil then
			makeWire("Points", "Points", upstream).Parent = node
		end

		node.Parent = folder
		table.insert(made, node)
		upstream = node
	end

	-- The terminal has nothing to clone yet. The wire is created empty rather
	-- than left out so the slot is visible in the Explorer and in both windows.
	makeWire("Asset", "Asset", nil).Parent = upstream

	-- The rule's durable identity, so the records that persist hand edits
	-- (PlacementLedger) survive the node being renamed. Written on the terminal
	-- because that is the node the Output entry points at.
	upstream:SetAttribute("RuleId", HttpService:GenerateGUID(false))

	folder.Parent = graph
	makeWire(ruleName, "OutputNode", upstream).Parent = registry

	return ruleName, folder, made
end

return RuleTemplates
