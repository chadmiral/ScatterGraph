--[[
	Graphs

	Which ScatterGraphs a place holds, and which one the author means.

	The Spreadsheet view lists them all and lets one be picked from that list.
	The Graph view has no such list: it is opened by a toolbar button, which has
	nothing to say about which graph to open. So it asks here instead, and the
	answer is read off the Studio selection -- a graph, a node inside one, or a
	volume that uses one all name the same graph -- falling back to the only
	graph in the place when the selection says nothing.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Selection = game:GetService("Selection")

local Graphs = {}

-- Where a graph can be kept: the storage services by convention, and Workspace
-- because a graph is often left next to the volumes that use it.
local SEARCH_ROOTS = {
	ReplicatedStorage,
	game:GetService("ServerStorage"),
	workspace,
}

-- Skipped by the search below. After an evaluation this folder holds every
-- placed clone in the place, which can be more instances than everything else
-- put together, and a graph is never inside it.
local INSTANCE_FOLDER = "ScatterGraphInstances"

function Graphs.isGraph(instance: Instance): boolean
	return instance:GetAttribute("NodeType") == "ScatterGraph"
end

local function searchForGraphs(container: Instance, found: { [Instance]: boolean }, graphs: { Instance })
	for _, child in container:GetChildren() do
		if Graphs.isGraph(child) then
			if not found[child] then
				found[child] = true
				table.insert(graphs, child)
			end
			-- Everything below a graph is its own nodes, never another graph.
			continue
		end

		-- Geometry cannot contain a graph, and not descending into it is what
		-- keeps this search cheap enough to run whenever a window redraws.
		if child.Name == INSTANCE_FOLDER or child:IsA("BasePart") then
			continue
		end

		searchForGraphs(child, found, graphs)
	end
end

-- The graph a scatter volume places, if the instance is a volume at all.
function Graphs.fromVolume(instance: Instance): Instance?
	if not instance:IsA("BasePart") or not CollectionService:HasTag(instance, "ScatterGraphVolume") then
		return nil
	end

	local reference = instance:FindFirstChildOfClass("ObjectValue")
	return if reference ~= nil then reference.Value else nil
end

-- Every graph a window can show, by name. Volumes that name a definition by
-- BiomeDefinitionAssetID are not resolved: that graph does not exist until it
-- has been loaded, and nothing here is worth an asset fetch.
function Graphs.inPlace(): { Instance }
	local found = {}
	local graphs = {}

	for _, container in SEARCH_ROOTS do
		searchForGraphs(container, found, graphs)
	end

	-- A volume may point at a graph kept somewhere the search does not reach.
	-- Its reference outlives a deletion, though, so a graph reached this way has
	-- to be checked for still being in the place at all.
	for _, volume in CollectionService:GetTagged("ScatterGraphVolume") do
		local graph = Graphs.fromVolume(volume)
		if graph ~= nil and Graphs.isGraph(graph) and graph:IsDescendantOf(game) and not found[graph] then
			found[graph] = true
			table.insert(graphs, graph)
		end
	end

	table.sort(graphs, function(a, b)
		if a.Name == b.Name then
			return a:GetFullName() < b:GetFullName()
		end
		return a.Name < b.Name
	end)

	return graphs
end

-- The graph the Studio selection names: the graph itself, the graph a selected
-- node sits in, or the graph a selected volume places. Nothing if the selection
-- is somewhere else in the place entirely.
function Graphs.selected(): Instance?
	for _, instance in Selection:Get() do
		local ancestor: Instance? = instance
		while ancestor ~= nil do
			if Graphs.isGraph(ancestor) then
				return ancestor
			end
			ancestor = ancestor.Parent
		end

		local placed = Graphs.fromVolume(instance)
		if placed ~= nil and Graphs.isGraph(placed) and placed:IsDescendantOf(game) then
			return placed
		end
	end

	return nil
end

return Graphs
