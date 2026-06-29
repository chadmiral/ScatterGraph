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

local InstanceFolder = workspace:FindFirstChild("ScatterGraphInstances")


local ScatterGraphsFolder = ReplicatedStorage:FindFirstChild("ScatterGraphs")


local toolbar = plugin:CreateToolbar("ScatterGraph")

-- Add a toolbar button labeled "Empty Script"
local newScriptButton = toolbar:CreateButton("EvaluateScatterGraph", "Evaluate the Scatter Graph", "rbxassetid://14978048121")
local clearButton = toolbar:CreateButton("Clear Instances", "Clear all ScatterGraph Instances", "")
local brushButton = toolbar:CreateButton("Brush", "Enable Brush Mode", "")
local testButton = toolbar:CreateButton("Test", "Test Button", "")

local function clearAllInstances()
	for _, instance in pairs(InstanceFolder:GetChildren()) do
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

evaluateNode = function(n, volume, terrain, debugString)
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
		return impl:evaluate(volume, terrain, {
			node = n,
			evaluateNode = evaluateNode,
			debugString = debugString,
			exclusionFunctions = exclusionFunctions,
			instanceFolder = InstanceFolder,
			insertService = InsertService,
		})
	else
		warn("Invalid node encountered: "..n.Name)
	end
end

local function evaluateGraph(g, volume, terrain)
	for _, node in pairs(g:GetChildren()) do
		local nodeType = node:GetAttribute("NodeType")
		if nodeType == "Output" then
			evaluateNode(node, volume, terrain, nil)
		end
	end
end	

local function onPluginButtonClicked()
	BrushToolActive = false
	local terrain = workspace.Terrain
	
	clearAllInstances()

	if InstanceFolder == nil then
		InstanceFolder = Instance.new("Folder")
		InstanceFolder.Name = "ScatterGraphInstances"
		InstanceFolder.Parent = workspace
	end

	if ScatterGraphsFolder == nil then
		ScatterGraphsFolder = Instance.new("Folder")
		ScatterGraphsFolder.Name = "ScatterGraphs"
		ScatterGraphsFolder.Parent = ReplicatedStorage
	end
	
	local biomeVolumes = CollectionService:GetTagged("ScatterGraphVolume")
	
	for _, volume in pairs(biomeVolumes) do
		local scatterGraph = nil
		
		local biomeDefinitionRef = volume:FindFirstChildOfClass("ObjectValue")
		
		if biomeDefinitionRef == nil then
			local biomeDefinitionID = volume:GetAttribute("BiomeDefinitionAssetID")
			
			local biomeAsset = game:GetService("InsertService"):LoadAsset(biomeDefinitionID)
			local packageChildren = biomeAsset:GetChildren()
			scatterGraph = packageChildren[1]
		else
			scatterGraph = biomeDefinitionRef.Value
		end

		local enabled = volume:GetAttribute("Enabled")
		if enabled then
			evaluateGraph(scatterGraph, volume, terrain)
		end
	end
end

local function onClearButtonClicked()
	BrushToolActive = false
	clearAllInstances()
end

local function onBrushButtonClicked()
	BrushToolActive = not BrushToolActive
end

local function onTestButtonClicked()
	print("test")
	local abstractNode = GraphNode:new()
	abstractNode:evaluate(nil, nil, nil)

	local scatterPointsNode = ScatterPointsNode:new{name="ScatterPointsNode", _type="ScatterPointsNode"}
	scatterPointsNode:evaluate(nil, nil, nil)
end

newScriptButton.Click:Connect(onPluginButtonClicked)
clearButton.Click:Connect(onClearButtonClicked)
brushButton.Click:Connect(onBrushButtonClicked)
testButton.Click:Connect(onTestButtonClicked)

--[[
local function onGraphChangedEvent()
	onPluginButtonClicked() 
end


local graphChangedEvent = game.ReplicatedStorage.ScatterGraphs.NewScatterGraph:WaitForChild("GraphChanged")
if graphChangedEvent ~= nil then
	graphChangedEvent.Event:Connect(onGraphChangedEvent)
end
--]]
