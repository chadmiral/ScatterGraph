local CollectionService = game:GetService("CollectionService")
local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Selection = game:GetService("Selection")

local BrushToolActive = false

local GraphNode = require(script.Parent.Nodes:WaitForChild("GraphNode"))
local ScatterPointsNode = require(script.Parent.Nodes:WaitForChild("ScatterPointsNode"))
local OutputNode = require(script.Parent.Nodes:WaitForChild("OutputNode"))
local PlaceGeometryOnPointsNode = require(script.Parent.Nodes:WaitForChild("PlaceGeometryOnPointsNode"))
local SnapPointsToTerrainNode = require(script.Parent.Nodes:WaitForChild("SnapPointsToTerrainNode"))
local ScatterPointsAroundPointsNode = require(script.Parent.Nodes:WaitForChild("ScatterPointsAroundPointsNode"))
local MaterialSDF2DNode = require(script.Parent.Nodes:WaitForChild("MaterialSDF2DNode"))
local NumberNode = require(script.Parent.Nodes:WaitForChild("NumberNode"))
local SDFGrid2D = require(script.Parent:WaitForChild("SDFGrid2D"))
local Helpers = require(script.Parent:WaitForChild("ScatterGraphHelpers"))
local OccupancyStore = require(script.Parent:WaitForChild("OccupancyStore"))
local PlacementLedger = require(script.Parent:WaitForChild("PlacementLedger"))
local VolumeGroup = require(script.Parent:WaitForChild("VolumeGroup"))
local GraphView = require(script.Parent:WaitForChild("GraphView"))
local RulesWindow = require(script.Parent:WaitForChild("RulesWindow"))
local GraphUi = require(script.Parent:WaitForChild("GraphUi"))

local InstanceFolder = workspace:FindFirstChild("ScatterGraphInstances")


local toolbar = plugin:CreateToolbar("ScatterGraph")

-- A toolbar button takes an image, not a glyph. The first two are free public
-- decals rather than anything uploaded for this plugin, so they can in
-- principle be moderated away; the button falls back to no icon rather than
-- breaking if that happens. Each id is the decal's underlying image, which is
-- what the Icon property wants -- the decal id itself does not always resolve.
local ICONS = {
	evaluate = "rbxassetid://8772271242", -- pine tree, from decal 8772271280
	clear = "rbxassetid://14002617467", -- trash can, from decal 14002617522
}

-- These four buttons borrow Studio's own art instead, which is on disk beside
-- Studio rather than on the asset server: the node graph is the icon Studio
-- gives the Animation Graph Editor, the table the one it gives UITableLayout,
-- the wireframe box the one it gives SelectionBox (Promote Selection keeps the
-- selection), and the circular arrow the one it gives Rotate (Forget Edits
-- resets a rule so it regenerates). Each is drawn at the 32 pixel size a toolbar
-- button uses. Studio ships a copy per theme, and the dark copy is drawn light,
-- so which copy is used follows the theme -- see paintStudioIcons. The %s is the
-- theme name.
local STUDIO_ICONS = {
	graphView = "rbxasset://studio_svg_textures/Shared/WidgetIcons/%s/Large/AnimationGraphEditor.png",
	spreadsheetView = "rbxasset://studio_svg_textures/Shared/InsertableObjects/%s/Standard/UITableLayout@2x.png",
	promote = "rbxasset://studio_svg_textures/Shared/InsertableObjects/%s/Standard/SelectionBox@2x.png",
	forget = "rbxasset://studio_svg_textures/Shared/InsertableObjects/%s/Standard/Rotate@2x.png",
}

local newScriptButton = toolbar:CreateButton("EvaluateScatterGraph", "Evaluate the Scatter Graph", ICONS.evaluate)
local clearButton = toolbar:CreateButton("Clear Instances", "Clear all ScatterGraph Instances", ICONS.clear)
local promoteButton = toolbar:CreateButton(
	"Promote Selection",
	"Lifts the selected placed instances out of the ScatterGraph for good: the next run leaves their points "
		.. "empty and never overwrites them, whatever their stamp says. Select the instances in the Explorer "
		.. "or viewport first.",
	""
)
local forgetButton = toolbar:CreateButton(
	"Forget Edits",
	"Discards every rule's memory of hand edits -- all promotions and records of deleted points -- and removes "
		.. "the instances they had promoted, so the next run places the whole place from nothing.",
	""
)
local spreadsheetViewButton = toolbar:CreateButton(
	"Spreadsheet View",
	"Browse and edit the rules of every ScatterGraph as a list",
	""
)
local graphViewButton = toolbar:CreateButton(
	"Graph View",
	"Opens the selected graph as a canvas of wired nodes, which can be added, moved, rewired and deleted",
	""
)
--local brushButton = toolbar:CreateButton("Brush", "Enable Brush Mode", "")
--local testButton = toolbar:CreateButton("Test", "Test Button", "")

-- Studio's icons come in a Dark and a Light set, each drawn to sit on that
-- theme's toolbar: the dark set is pale, and would all but vanish against the
-- light one. Which set to use is read off the theme's own background rather than
-- its name, so a theme that is neither of the two built-in ones still gets a
-- legible icon.
local function paintStudioIcons()
	local background = settings().Studio.Theme:GetColor(Enum.StudioStyleGuideColor.MainBackground)
	local theme = if background.R + background.G + background.B < 1.5 then "Dark" else "Light"

	spreadsheetViewButton.Icon = string.format(STUDIO_ICONS.spreadsheetView, theme)
	graphViewButton.Icon = string.format(STUDIO_ICONS.graphView, theme)
	promoteButton.Icon = string.format(STUDIO_ICONS.promote, theme)
	forgetButton.Icon = string.format(STUDIO_ICONS.forget, theme)
end

paintStudioIcons()
settings().Studio.ThemeChanged:Connect(paintStudioIcons)

local function clearAllInstances()
	local instances = CollectionService:GetTagged("ScatterGraphInstance")
	for _, instance in pairs(instances) do
		instance:Destroy()
	end
end

local nodeRegistry = {
	Output = OutputNode,
	PlaceGeometryOnPoints = PlaceGeometryOnPointsNode,
	SnapPointsToTerrain = SnapPointsToTerrainNode,
	ScatterPoints = ScatterPointsNode,
	ScatterPointsAroundPoints = ScatterPointsAroundPointsNode,
	MaterialSDF2D = MaterialSDF2DNode,
	Number = NumberNode,
}

local evaluateNode

-- Shared across all branches of a single graph evaluation -- which covers every
-- volume in the group -- so later branches can avoid geometry placed by earlier
-- ones, in any volume. Reset in evaluateGraph.
local currentOccupancy = nil
-- The run's ledger and the graph it is currently placing under, carried down to
-- the terminal so each placement can be stamped and recorded. Both are set for
-- the length of a single Evaluate press.
local currentRun = nil
local currentGraphKey = nil
-- Every exclusion volume in the place, with the rules each one applies to. Read
-- once a run rather than once a node: the tag does not change while a run is in
-- flight, and a volume aimed at nothing is worth saying once.
local currentExclusionZones = {}
-- The exclusions that apply to the rule being evaluated. Set when a rule's chain
-- begins, since the Output entry naming it is the only thing that knows which
-- rule this is, and read by every node in that chain: a volume aimed at a rule
-- excludes the whole of it, not only its terminal. Reset in evaluateGraph.
local currentExclusionFunctions = {}
-- The grid every distance field in this graph is measured over, set from the
-- volumes being scattered before any node runs and handed to all of them. A node
-- measuring a field does not choose its own: two fields are read against each
-- other only if they line up voxel for voxel, and the ground being scattered is
-- what the resolution should answer to in the first place. Set in evaluateGraph.
local currentGridLayout = nil
-- The distance fields measured so far in this graph, by the node that measured
-- them. A field costs the best part of a second over a biome, and every rule that
-- masks against one asks the same node for it again: the answer depends on the
-- node's own parameters and the volumes, neither of which move during a run.
-- Reset in evaluateGraph, since the grid it is measured over is.
local currentFieldCache = {}

-- `rule` is the Output entry that names the chain being evaluated. Only the
-- Output node passes it -- it is the only node that knows -- so a call from
-- anywhere else leaves it out and the rule already set stands for the chain.
evaluateNode = function(n, volumes, terrain, debugString, rule)
	if rule ~= nil then
		currentExclusionFunctions = Helpers.exclusionZoneFunctions(currentExclusionZones, rule)
	end

	if n == nil then
		warn("Nil GraphNode!")
		warn(debugString)
	end

	if debugString == nil then
		debugString = n.Parent.Name.."/"..n.Name
	else
		debugString = n.Parent.Name.."/"..n.Name.."->"..debugString
	end

	-- The rule's identity is worked out from the entry that names it, and reaches
	-- only the node that entry points at: the terminal, which is what stamps and
	-- records a placement under it.
	local ruleKey, ruleName
	if rule ~= nil then
		ruleKey, ruleName = PlacementLedger.ruleKey(rule)
	end

	local nodeType = n:GetAttribute("NodeType")
	local impl = nodeRegistry[nodeType]
	if impl then
		return impl:evaluate(volumes, terrain, {
			node = n,
			evaluateNode = evaluateNode,
			debugString = debugString,
			exclusionFunctions = currentExclusionFunctions,
			gridLayout = currentGridLayout,
			fieldCache = currentFieldCache,
			instanceFolder = InstanceFolder,
			insertService = InsertService,
			occupancy = currentOccupancy,
			run = currentRun,
			graphKey = currentGraphKey,
			ruleKey = ruleKey,
			ruleName = ruleName,
		})
	else
		warn("Invalid node encountered: "..n.Name)
	end
end

local function evaluateGraph(g, volumes, terrain, graphKey)
	currentGraphKey = graphKey
	-- Nothing outside a rule is excluded from anything; the Output node below
	-- fills this in as it reaches each rule.
	currentExclusionFunctions = {}
	-- Settled from the volumes before the first Output node is reached, so every
	-- field measured anywhere in this graph covers the same ground.
	currentGridLayout = SDFGrid2D.layoutFor(volumes)
	currentFieldCache = {}
	currentOccupancy = OccupancyStore.new()
	currentOccupancy.run = currentRun
	currentOccupancy.graphKey = graphKey

	-- Instances the author edited and kept are solids at where they actually
	-- sit, so AvoidIntersections rules keep clear of them, whatever the stamp of
	-- their original placement said.
	if currentRun ~= nil then
		for _, claim in currentRun:promotedClaims(graphKey) do
			currentOccupancy:addSolid(claim.x, claim.z, claim.radius, claim.ruleKey)
		end
	end

	for _, node in pairs(g:GetChildren()) do
		local nodeType = node:GetAttribute("NodeType")
		if nodeType == "Output" then
			evaluateNode(node, volumes, terrain, nil)
		end
	end
	-- Resolve intersection-avoiding placements once every branch has run, so the
	-- outcome does not depend on branch evaluation order.
	currentOccupancy:resolveDeferred()
end	

-- Enabled volumes are bucketed by the biome definition they point at. Each
-- bucket is evaluated once for all of its volumes, so volumes sharing a
-- definition behave as one region: overlaps union instead of being scattered
-- over twice. Volumes with different definitions stay independent of each other.
local function collectVolumeGroups()
	local groupsByDefinition = {}
	local groups = {}

	for _, volume in pairs(CollectionService:GetTagged("ScatterGraphVolume")) do
		if not volume:IsA("BasePart") then
			warn("Scatter volume "..volume.Name.." is not a part. Skipping")
			continue
		end

		if volume:GetAttribute("Enabled") then
			local biomeDefinitionRef = volume:FindFirstChildOfClass("ObjectValue")
			local biomeDefinition = if biomeDefinitionRef ~= nil
				then biomeDefinitionRef.Value
				else volume:GetAttribute("BiomeDefinitionAssetID")

			if biomeDefinition == nil then
				warn("Scatter volume "..volume.Name.." has no biome definition. Skipping")
				continue
			end

			local group = groupsByDefinition[biomeDefinition]
			if group == nil then
				-- An ObjectValue references the graph directly. An asset ID is
				-- loaded once for the whole group rather than once per volume,
				-- which is also what makes the group share one graph instance.
				local isInstance = typeof(biomeDefinition) == "Instance"
				group = {
					graph = if isInstance then biomeDefinition else nil,
					assetID = if isInstance then nil else biomeDefinition,
					volumes = {},
				}

				groupsByDefinition[biomeDefinition] = group
				table.insert(groups, group)
			end

			table.insert(group.volumes, volume)
		end
	end

	return groups
end

local function onPluginButtonClicked()
	BrushToolActive = false
	local terrain = workspace.Terrain

	if InstanceFolder == nil then
		InstanceFolder = Instance.new("Folder")
		InstanceFolder.Name = "ScatterGraphInstances"
		InstanceFolder.Parent = workspace
	end
	
	-- The sweep replaces the old clear: rather than destroying everything, it
	-- promotes hand-edited instances out of the system and destroys only the
	-- untouched ones, leaving the ledger knowing which points were live so the
	-- placement pass below can tell a deletion from an ordinary re-run.
	currentRun = PlacementLedger.beginRun()
	currentRun:sweep()
	currentExclusionZones = Helpers.exclusionZones()

	for _, group in collectVolumeGroups() do
		local scatterGraph = group.graph
		local graphKey
		if scatterGraph == nil then
			local biomeAsset = InsertService:LoadAsset(group.assetID)
			scatterGraph = biomeAsset:GetChildren()[1]
			-- Asset-loaded graphs have no lasting instance, so they are keyed by
			-- the id they were loaded from instead of a name.
			graphKey = "Asset:" .. tostring(group.assetID)
		else
			graphKey = PlacementLedger.graphKey(scatterGraph)
		end

		if scatterGraph ~= nil then
			evaluateGraph(scatterGraph, VolumeGroup.new(group.volumes), terrain, graphKey)
		else
			warn("Could not resolve a biome definition for volume "..group.volumes[1].Name)
		end
	end

	-- Tombstone the deletions the sweep and placement uncovered, prune the
	-- points no rule wants any more, and write every book.
	currentRun:finishRun()
	currentRun = nil
	currentGraphKey = nil
end

local function onClearButtonClicked()
	BrushToolActive = false
	clearAllInstances()
	-- The instances are gone, so their `placed` entries have to go too, or the
	-- next Evaluate would read every one of them as a hand deletion and never
	-- put them back. Promotions and tombstones are kept.
	PlacementLedger.wipePlaced()
end

-- Keep whatever is selected in the Explorer, whatever the stamp says. The
-- escape hatch for an edit the deep stamp cannot see, or a prop the author
-- wants held even though it is untouched.
local function onPromoteButtonClicked()
	local promoted = 0
	local acted = GraphUi.recorded("Promote ScatterGraph instances", function()
		promoted = PlacementLedger.promoteSelection(Selection:Get())
	end)
	if acted and promoted == 0 then
		warn("Promote Selection: nothing tagged as a ScatterGraph instance is selected.")
	end
end

-- Throw away every rule's records and its promotions across the whole place, so
-- the next run rebuilds everything from nothing.
local function onForgetButtonClicked()
	GraphUi.recorded("Forget ScatterGraph edits", function()
		PlacementLedger.forgetAll()
	end)
end

--[[
local function onBrushButtonClicked()
	BrushToolActive = not BrushToolActive
end

local function onTestButtonClicked()
	print("test")
	local abstractNode = GraphNode:new()
	abstractNode:evaluate(nil, nil, nil)

	local scatterPointsNode = ScatterPointsNode:new{name="ScatterPointsNode", _type="ScatterPointsNode"}
	scatterPointsNode:evaluate(nil, nil, nil)
end--]]

newScriptButton.Click:Connect(onPluginButtonClicked)
clearButton.Click:Connect(onClearButtonClicked)
promoteButton.Click:Connect(onPromoteButtonClicked)
forgetButton.Click:Connect(onForgetButtonClicked)
-- Each view owns its own button: clicking it toggles that view's dock widget.
RulesWindow.install(plugin, spreadsheetViewButton)
GraphView.install(plugin, graphViewButton)
--brushButton.Click:Connect(onBrushButtonClicked)
--testButton.Click:Connect(onTestButtonClicked)

--[[
local function onGraphChangedEvent()
	onPluginButtonClicked() 
end


local graphChangedEvent = game.ReplicatedStorage.ScatterGraphs.NewScatterGraph:WaitForChild("GraphChanged")
if graphChangedEvent ~= nil then
	graphChangedEvent.Event:Connect(onGraphChangedEvent)
end
--]]
