local CollectionService = game:GetService("CollectionService")
local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BrushToolActive = false

local GraphNode = require(script.Parent.Nodes:WaitForChild("GraphNode"))
local ScatterPointsNode = require(script.Parent.Nodes:WaitForChild("ScatterPointsNode"))
local OutputNode = require(script.Parent.Nodes:WaitForChild("OutputNode"))
local PlaceGeometryOnPointsNode = require(script.Parent.Nodes:WaitForChild("PlaceGeometryOnPointsNode"))
local SnapPointsToTerrainNode = require(script.Parent.Nodes:WaitForChild("SnapPointsToTerrainNode"))
local ScatterPointsAroundPointsNode = require(script.Parent.Nodes:WaitForChild("ScatterPointsAroundPointsNode"))
local Helpers = require(script.Parent:WaitForChild("ScatterGraphHelpers"))
local OccupancyStore = require(script.Parent:WaitForChild("OccupancyStore"))
local VolumeGroup = require(script.Parent:WaitForChild("VolumeGroup"))
local RulesWindow = require(script.Parent:WaitForChild("RulesWindow"))

local InstanceFolder = workspace:FindFirstChild("ScatterGraphInstances")


local toolbar = plugin:CreateToolbar("ScatterGraph")

-- A toolbar button takes an image, not a glyph. These are free public decals
-- rather than anything uploaded for this plugin, so they can in principle be
-- moderated away; the button falls back to no icon rather than breaking if that
-- happens. Each id is the decal's underlying image, which is what the Icon
-- property wants -- the decal id itself does not always resolve.
local ICONS = {
	evaluate = "rbxassetid://8772271242", -- pine tree, from decal 8772271280
	clear = "rbxassetid://14002617467", -- trash can, from decal 14002617522
	rules = "rbxassetid://76681380400497", -- pencil, from decal 128809752302807
}

local newScriptButton = toolbar:CreateButton("EvaluateScatterGraph", "Evaluate the Scatter Graph", ICONS.evaluate)
local clearButton = toolbar:CreateButton("Clear Instances", "Clear all ScatterGraph Instances", ICONS.clear)
local rulesButton = toolbar:CreateButton("Rules", "Browse and edit the rules of every ScatterGraph", ICONS.rules)
--local brushButton = toolbar:CreateButton("Brush", "Enable Brush Mode", "")
--local testButton = toolbar:CreateButton("Test", "Test Button", "")

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
}

local evaluateNode

-- Shared across all branches of a single graph evaluation -- which covers every
-- volume in the group -- so later branches can avoid geometry placed by earlier
-- ones, in any volume. Reset in evaluateGraph.
local currentOccupancy = nil

evaluateNode = function(n, volumes, terrain, debugString)
	local exclusionFunctions = Helpers.exclusionZoneFunctions()

	if n == nil then
		warn("Nil GraphNode!")
		warn(debugString)
	end

	if debugString == nil then
		debugString = n.Parent.Name.."/"..n.Name
	else
		debugString = n.Parent.Name.."/"..n.Name.."->"..debugString
	end

	local nodeType = n:GetAttribute("NodeType")
	local impl = nodeRegistry[nodeType]
	if impl then
		return impl:evaluate(volumes, terrain, {
			node = n,
			evaluateNode = evaluateNode,
			debugString = debugString,
			exclusionFunctions = exclusionFunctions,
			instanceFolder = InstanceFolder,
			insertService = InsertService,
			occupancy = currentOccupancy,
		})
	else
		warn("Invalid node encountered: "..n.Name)
	end
end

local function evaluateGraph(g, volumes, terrain)
	currentOccupancy = OccupancyStore.new()
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
	
	clearAllInstances()
	
	for _, group in collectVolumeGroups() do
		local scatterGraph = group.graph
		if scatterGraph == nil then
			local biomeAsset = InsertService:LoadAsset(group.assetID)
			scatterGraph = biomeAsset:GetChildren()[1]
		end

		if scatterGraph ~= nil then
			evaluateGraph(scatterGraph, VolumeGroup.new(group.volumes), terrain)
		else
			warn("Could not resolve a biome definition for volume "..group.volumes[1].Name)
		end
	end
end

local function onClearButtonClicked()
	BrushToolActive = false
	clearAllInstances()
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
-- The Rules widget owns its own button: clicking it toggles the dock widget.
RulesWindow.install(plugin, rulesButton)
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
