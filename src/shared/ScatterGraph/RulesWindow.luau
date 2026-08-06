--[[
	RulesWindow

	The "Rules" dock widget: an inspector and editor for the biome graphs in the
	place, in three panes that read left to right.

	The first lists every ScatterGraph the place contains. Picking one fills the
	second with that graph's outputs -- the ObjectValue entries under its Output
	node, one per placement rule. Picking one of those fills the third with every
	attribute of every node that feeds it, walked upstream through the Points
	wires so the chain reads source-first the way the graph does. Those
	attributes are editable in place: AttributeSchema decides which editor each
	one gets, and sequences open in the SequenceEditor popout. A row's value is
	usually an attribute, but it can also be a child ObjectValue -- that is how
	PlaceGeometryOnPoints points at the geometry it places -- and both kinds
	read and write the same way from here.

	The Studio selection does not choose which graph is shown. It is what the
	Asset editor reads to name the geometry a rule places, so a window that
	followed it would empty itself in the middle of that gesture.

	The two ribbon rows along the top edit what the panes below them show. The
	upper row makes and deletes whole graphs; the lower one deletes the selected
	rule or adds one of the three chains that cover almost every rule in
	practice. Every edit goes through ChangeHistoryService, so ctrl-Z undoes it
	like any other Studio change.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Selection = game:GetService("Selection")

local AttributeSchema = require(script.Parent:WaitForChild("AttributeSchema"))
local SequenceEditor = require(script.Parent:WaitForChild("SequenceEditor"))

local RulesWindow = {}

local PADDING = 6
local ROW_HEIGHT = 22
local SECTION_HEIGHT = 24
local HEADER_HEIGHT = 26
local RIBBON_HEIGHT = 30
local BUTTON_HEIGHT = 22
local GRAPH_COLUMN = 0.22
local OUTPUT_COLUMN = 0.26
local NAME_COLUMN = 0.45
local TOOLTIP_WIDTH = 280
-- Long enough that sweeping the pointer down the rows does not flash a tooltip
-- at every one of them on the way past.
local TOOLTIP_DELAY = 0.4

local function color(guideColor: Enum.StudioStyleGuideColor, modifier: Enum.StudioStyleGuideModifier?): Color3
	return settings().Studio.Theme:GetColor(guideColor, modifier)
end

local function indent(gui: GuiObject)
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, PADDING)
	padding.Parent = gui
end

-- Values shown as-is where tostring already reads well, and spelled out where it
-- does not: a NumberSequence stringifies to something unreadable, and an
-- Instance's name alone is ambiguous across a graph.
local function formatValue(value: any): string
	local valueType = typeof(value)

	if valueType == "NumberSequence" then
		local parts = {}
		for _, keypoint in value.Keypoints do
			table.insert(parts, string.format("%g -> %g", keypoint.Time, keypoint.Value))
		end
		return table.concat(parts, ", ")
	elseif valueType == "ColorSequence" then
		local parts = {}
		for _, keypoint in value.Keypoints do
			local c = keypoint.Value
			table.insert(
				parts,
				string.format(
					"%g -> #%02X%02X%02X",
					keypoint.Time,
					math.round(c.R * 255),
					math.round(c.G * 255),
					math.round(c.B * 255)
				)
			)
		end
		return table.concat(parts, ", ")
	elseif valueType == "Color3" then
		return string.format("#%02X%02X%02X", math.round(value.R * 255), math.round(value.G * 255), math.round(value.B * 255))
	elseif valueType == "Vector2" then
		return string.format("%g, %g", value.X, value.Y)
	elseif valueType == "Vector3" then
		return string.format("%g, %g, %g", value.X, value.Y, value.Z)
	elseif valueType == "Instance" then
		return value:GetFullName()
	end

	return tostring(value)
end

-- Where a graph can be kept: the storage services by convention, and Workspace
-- because a graph is often left next to the volumes that use it.
local SEARCH_ROOTS = {
	ReplicatedStorage,
	game:GetService("ServerStorage"),
	workspace,
}

-- Where a graph goes when this window makes one, and the location the rest of
-- the system expects to find graphs in.
local GRAPH_FOLDER = "ScatterGraphs"

-- Skipped by the search below. After an evaluation this folder holds every
-- placed clone in the place, which can be more instances than everything else
-- put together, and a graph is never inside it.
local INSTANCE_FOLDER = "ScatterGraphInstances"

local function isGraph(instance: Instance): boolean
	return instance:GetAttribute("NodeType") == "ScatterGraph"
end

local function searchForGraphs(container: Instance, found: { [Instance]: boolean }, graphs: { Instance })
	for _, child in container:GetChildren() do
		if isGraph(child) then
			if not found[child] then
				found[child] = true
				table.insert(graphs, child)
			end
			-- Everything below a graph is its own nodes, never another graph.
			continue
		end

		-- Geometry cannot contain a graph, and not descending into it is what
		-- keeps this search cheap enough to run whenever the window redraws.
		if child.Name == INSTANCE_FOLDER or child:IsA("BasePart") then
			continue
		end

		searchForGraphs(child, found, graphs)
	end
end

local function findGraphFromVolume(instance: Instance): Instance?
	if not instance:IsA("BasePart") or not CollectionService:HasTag(instance, "ScatterGraphVolume") then
		return nil
	end

	local reference = instance:FindFirstChildOfClass("ObjectValue")
	return if reference ~= nil then reference.Value else nil
end

-- Every graph the window can show. Volumes that name a definition by
-- BiomeDefinitionAssetID are not resolved: that graph does not exist until it
-- has been loaded, and nothing here is worth an asset fetch.
local function collectGraphs(): { Instance }
	local found = {}
	local graphs = {}

	for _, container in SEARCH_ROOTS do
		searchForGraphs(container, found, graphs)
	end

	-- A volume may point at a graph kept somewhere the search does not reach.
	-- Its reference outlives a deletion, though, so a graph reached this way has
	-- to be checked for still being in the place at all.
	for _, volume in CollectionService:GetTagged("ScatterGraphVolume") do
		local graph = findGraphFromVolume(volume)
		if graph ~= nil and isGraph(graph) and graph:IsDescendantOf(game) and not found[graph] then
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

local function collectOutputs(graph: Instance): { ObjectValue }
	local outputs = {}

	for _, child in graph:GetChildren() do
		if child:GetAttribute("NodeType") == "Output" then
			for _, wire in child:GetChildren() do
				if wire:IsA("ObjectValue") then
					table.insert(outputs, wire)
				end
			end
		end
	end

	table.sort(outputs, function(a, b)
		return a.Name < b.Name
	end)

	return outputs
end

-- Post-order walk up the wires, so a node always appears after everything that
-- feeds it. Only wires pointing at another graph node are followed, which skips
-- the Asset wire's geometry template. The visited set keeps a node shared by two
-- branches from being listed twice.
local function collectUpstreamNodes(node: Instance?, visited: { [Instance]: boolean }, ordered: { Instance })
	if node == nil or visited[node] then
		return
	end
	visited[node] = true

	for _, wire in node:GetChildren() do
		if wire:IsA("ObjectValue") and wire.Value ~= nil and wire.Value:GetAttribute("NodeType") ~= nil then
			collectUpstreamNodes(wire.Value, visited, ordered)
		end
	end

	table.insert(ordered, node)
end

local function findWire(node: Instance, name: string): ObjectValue?
	local wire = node:FindFirstChild(name)
	return if wire ~= nil and wire:IsA("ObjectValue") then wire else nil
end

-- An attribute is read straight off the node; a wire's value is the Value of
-- the child ObjectValue of that name. PlaceGeometryOnPoints takes its template
-- either way, so both have to reach the panel as ordinary rows.
local function readDescriptorValue(node: Instance, descriptor): any
	if descriptor.source == "wire" then
		local wire = findWire(node, descriptor.name)
		return if wire ~= nil then wire.Value else nil
	end

	return node:GetAttribute(descriptor.name)
end

-- Is this row's value being ignored because the wire that outranks it is set?
local function isSuperseded(node: Instance, descriptor): boolean
	if descriptor.supersededBy == nil then
		return false
	end

	local wire = findWire(node, descriptor.supersededBy)
	return wire ~= nil and wire.Value ~= nil
end

-- The rule templates the ribbon can add. Each is a chain listed source-first;
-- every node is wired to the one before it by a Points wire, and the last node
-- is the terminal the Output entry points at. Note that the terminal is named
-- PlaceAssetOnPoints while its NodeType is PlaceGeometryOnPoints -- the two
-- differ throughout the existing graphs, and the registry keys off the
-- attribute.
--
-- The values here are only a starting point: a rule is not finished until its
-- Asset wire has a template to clone, and spacing and filters are what the
-- author actually tunes.
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

local RULE_TEMPLATES = {
	terrainProp = {
		ruleName = "TerrainProp",
		nodes = { SCATTER_POINTS, SNAP_TO_TERRAIN, PLACE_ASSET },
	},
	cluster = {
		ruleName = "Cluster",
		nodes = {
			-- Cluster seeds are spaced further apart than a solo scatter, since
			-- each one fills in with Count points of its own.
			{ name = "ScatterPoints", nodeType = "ScatterPoints", attributes = { Seed = 1, Spacing = 60 } },
			{
				name = "ScatterPointsAroundPoints",
				nodeType = "ScatterPointsAroundPoints",
				attributes = { Seed = 2, InnerRadius = 0, OuterRadius = 8, Count = 20 },
			},
			SNAP_TO_TERRAIN,
			PLACE_ASSET,
		},
	},
	floatingProp = {
		ruleName = "FloatingProp",
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
	},
}

local function makeWire(name: string, nodeType: string, value: Instance?): ObjectValue
	local wire = Instance.new("ObjectValue")
	wire.Name = name
	wire.Value = value
	wire:SetAttribute("NodeType", nodeType)
	return wire
end

local function findOutputRegistry(graph: Instance): Instance
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

-- Makes the graph folder if the place has never held a graph before, which is
-- what the evaluator does with it too.
local function findGraphFolder(): Instance
	local folder = ReplicatedStorage:FindFirstChild(GRAPH_FOLDER)
	if folder ~= nil then
		return folder
	end

	folder = Instance.new("Folder")
	folder.Name = GRAPH_FOLDER
	folder.Parent = ReplicatedStorage
	return folder
end

local function makeGraph(): Instance
	local container = findGraphFolder()

	local name = "ScatterGraph"
	local suffix = 1
	while container:FindFirstChild(name) ~= nil do
		suffix += 1
		name = "ScatterGraph" .. suffix
	end

	local graph = Instance.new("Model")
	graph.Name = name
	graph:SetAttribute("NodeType", "ScatterGraph")
	-- Made now rather than with the first rule so the graph is a complete,
	-- evaluable one from the moment it exists -- an empty registry places
	-- nothing, but a missing one is a graph the evaluator cannot read.
	findOutputRegistry(graph)
	graph.Parent = container

	return graph
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

local function addRule(graph: Instance, template): (string, Instance)
	local registry = findOutputRegistry(graph)
	local ruleName = uniqueRuleName(graph, registry, template.ruleName)

	local folder = Instance.new("Folder")
	folder.Name = ruleName

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
		upstream = node
	end

	-- The terminal has nothing to clone yet. The wire is created empty rather
	-- than left out so the slot is visible in the Explorer and in this window.
	makeWire("Asset", "Asset", nil).Parent = upstream

	folder.Parent = graph
	makeWire(ruleName, "OutputNode", upstream).Parent = registry

	return ruleName, folder
end

-- Deletes the registry entry and the nodes behind it, but only the nodes this
-- output is alone in using: a node feeding two outputs still has a reason to
-- exist. The rule folder goes too once nothing is left in it.
local function deleteRule(graph: Instance, output: ObjectValue, allOutputs: { ObjectValue })
	local stillNeeded = {}
	for _, other in allOutputs do
		if other ~= output then
			collectUpstreamNodes(other.Value, stillNeeded, {})
		end
	end

	local doomed = {}
	collectUpstreamNodes(output.Value, {}, doomed)

	-- Unparented rather than destroyed, here and below. Destroy locks the Parent
	-- property, so the undo that follows cannot put the instance back and fails
	-- with a warning instead. Deleting in the Explorer unparents too.
	local containers = {}
	for _, node in doomed do
		if not stillNeeded[node] then
			containers[node.Parent] = true
			node.Parent = nil
		end
	end

	output.Parent = nil

	for container in containers do
		if container ~= graph and container.Parent ~= nil and #container:GetChildren() == 0 then
			container.Parent = nil
		end
	end
end

-- Studio's undo stack only records what happens between these calls, so every
-- edit the ribbon makes has to run inside one.
local function recorded(name: string, edit: () -> ())
	local recording = ChangeHistoryService:TryBeginRecording(name)
	local ok, err = pcall(edit)

	if recording ~= nil then
		ChangeHistoryService:FinishRecording(
			recording,
			if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
		)
	end

	if not ok then
		warn("ScatterGraph Rules: " .. name .. " failed -- " .. tostring(err))
	end

	return ok
end

function RulesWindow.install(pluginRef: Plugin, button: PluginToolbarButton)
	-- Three panes side by side need a wider window than two did.
	local widgetInfo = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 720, 400, 460, 240)
	local widget = pluginRef:CreateDockWidgetPluginGui("ScatterGraphRules", widgetInfo)
	widget.Name = "ScatterGraphRules"
	widget.Title = "ScatterGraph Rules"
	widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- Rebuilt wholesale whenever what they show changes: these panes are small,
	-- and the alternative is tracking every widget that needs repainting.
	local root = nil
	local graphList = nil
	local outputHeader = nil
	local outputList = nil
	local detailHeader = nil
	local detailList = nil

	local selectedOutputName = nil
	-- The graph the two right-hand panes are showing.
	local currentGraph: Instance? = nil
	-- A value shown here can also be changed from the Properties pane or by an
	-- undo, so the detail pane listens to the nodes it is showing to stay
	-- current.
	local detailConnections: { RBXScriptConnection } = {}
	-- Most ribbon buttons act on the selected graph or the selected rule, so
	-- they are greyed out when there is none; each remembers which it needs.
	-- Rebuilt with the rest of the interface.
	local ribbonButtons = {}
	-- The open dropdown list, if any. Only one can be open at a time, and it
	-- closes whenever the pane it belongs to is rebuilt.
	local dropdown = nil
	-- The visible tooltip, and a counter that tells a delayed one whether the
	-- pointer is still where it was when the wait started.
	local tooltip = nil
	local tooltipToken = 0

	-- Rebuilds the graph list and everything under it; rebuilds the rule and
	-- detail panes for the graph already chosen.
	local refresh
	local refreshRules

	-- The graph the list has chosen, unless it has since been deleted.
	local function activeGraph(): Instance?
		if currentGraph ~= nil and not currentGraph:IsDescendantOf(game) then
			currentGraph = nil
		end

		return currentGraph
	end

	local function closeDropdown()
		if dropdown ~= nil then
			dropdown:Destroy()
			dropdown = nil
		end
	end

	local function makeLabel(text: string, textColor: Color3, bold: boolean): TextLabel
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Font = if bold then Enum.Font.SourceSansBold else Enum.Font.SourceSans
		label.TextSize = 14
		label.TextColor3 = textColor
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextTruncate = Enum.TextTruncate.AtEnd
		label.Text = text
		return label
	end

	local function hideTooltip()
		-- Also cancels any tooltip still waiting out its delay.
		tooltipToken += 1

		if tooltip ~= nil then
			tooltip:Destroy()
			tooltip = nil
		end
	end

	-- Roblox has no tooltip, so this is a panel pinned to the row that asked for
	-- it. It sits below the row rather than under the pointer: a frame beneath
	-- the pointer takes the hover from the row that raised it, and the two then
	-- flicker against each other.
	local function showTooltip(anchor: GuiObject, text: string)
		hideTooltip()

		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromOffset(TOOLTIP_WIDTH, 0)
		frame.AutomaticSize = Enum.AutomaticSize.Y
		frame.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Titlebar)
		frame.BorderColor3 = color(Enum.StudioStyleGuideColor.Border)
		frame.ZIndex = 20
		tooltip = frame

		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, PADDING)
		padding.PaddingRight = UDim.new(0, PADDING)
		padding.PaddingTop = UDim.new(0, 4)
		padding.PaddingBottom = UDim.new(0, 4)
		padding.Parent = frame

		local label = makeLabel(text, color(Enum.StudioStyleGuideColor.MainText), false)
		label.Size = UDim2.new(1, 0, 0, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.TextTruncate = Enum.TextTruncate.None
		label.TextWrapped = true
		label.TextYAlignment = Enum.TextYAlignment.Top
		label.ZIndex = 20
		label.Parent = frame

		local offset = anchor.AbsolutePosition - root.AbsolutePosition
		local below = offset.Y + anchor.AbsoluteSize.Y + 2
		local x = math.clamp(offset.X, PADDING, math.max(PADDING, root.AbsoluteSize.X - TOOLTIP_WIDTH - PADDING))

		-- The height is only known once the text has been laid out, so the
		-- decision to hang the panel below the row or above it is made again
		-- whenever that height lands.
		local function place()
			local height = frame.AbsoluteSize.Y
			frame.Position = UDim2.fromOffset(
				x,
				if below + height <= root.AbsoluteSize.Y then below else math.max(0, offset.Y - height - 2)
			)
		end

		-- Placed before it is shown, so it never appears in the corner for a
		-- frame on the way to where it belongs.
		place()
		frame.Parent = root
		frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
	end

	-- Waits out the hover delay before showing, and does nothing if the pointer
	-- has moved on or the row has been rebuilt in the meantime.
	local function watchForTooltip(anchor: GuiObject, text: string)
		anchor.MouseEnter:Connect(function()
			tooltipToken += 1
			local token = tooltipToken

			task.delay(TOOLTIP_DELAY, function()
				if token == tooltipToken and anchor.Parent ~= nil then
					showTooltip(anchor, text)
				end
			end)
		end)

		anchor.MouseLeave:Connect(hideTooltip)
	end

	local function clearDetail()
		hideTooltip()
		closeDropdown()

		for _, connection in detailConnections do
			connection:Disconnect()
		end
		table.clear(detailConnections)

		for _, child in detailList:GetChildren() do
			if not child:IsA("UIListLayout") then
				child:Destroy()
			end
		end
	end

	local function commitValue(node: Instance, descriptor, value: any)
		-- A node deleted while its row was on screen is not worth an error.
		if node.Parent == nil then
			return
		end

		recorded("Set " .. descriptor.name, function()
			if descriptor.source ~= "wire" then
				node:SetAttribute(descriptor.name, value)
				return
			end

			local wire = findWire(node, descriptor.name)

			-- Clearing empties the wire rather than removing it: an empty wire
			-- and a missing one mean the same thing to the runtime, and the
			-- empty one keeps the slot visible in the Explorer.
			if wire == nil then
				if value == nil then
					return
				end

				wire = Instance.new("ObjectValue")
				wire.Name = descriptor.name
				wire:SetAttribute("NodeType", descriptor.wireNodeType or descriptor.name)
				wire.Parent = node
			end

			wire.Value = value
		end)
	end

	-- Roblox has no dropdown, so this is a list floated over the panes on a
	-- full-window backdrop that dismisses it when clicked. Items are
	-- { text, activate, enabled }; an item without an action, or with enabled
	-- false, is a line of text the menu shows but does not offer.
	local function openDropdown(anchor: GuiObject, items)
		closeDropdown()

		local backdrop = Instance.new("TextButton")
		backdrop.Size = UDim2.fromScale(1, 1)
		backdrop.BackgroundTransparency = 1
		backdrop.Text = ""
		backdrop.ZIndex = 10
		backdrop.Parent = root
		backdrop.Activated:Connect(closeDropdown)
		dropdown = backdrop

		local height = #items * ROW_HEIGHT
		local offset = anchor.AbsolutePosition - root.AbsolutePosition
		local below = offset.Y + anchor.AbsoluteSize.Y

		local list = Instance.new("Frame")
		list.Size = UDim2.fromOffset(anchor.AbsoluteSize.X, height)
		-- Flips above the field when there is no room beneath it, which there
		-- often is not in a window this short.
		list.Position = UDim2.fromOffset(
			offset.X,
			if below + height <= root.AbsoluteSize.Y then below else math.max(0, offset.Y - height)
		)
		list.BackgroundColor3 = color(Enum.StudioStyleGuideColor.MainBackground)
		list.BorderColor3 = color(Enum.StudioStyleGuideColor.Border)
		list.ZIndex = 11
		list.Parent = backdrop

		local layout = Instance.new("UIListLayout")
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = list

		for index, item in items do
			local enabled = item.activate ~= nil and item.enabled ~= false

			local button = Instance.new("TextButton")
			button.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
			button.LayoutOrder = index
			button.BackgroundColor3 = color(Enum.StudioStyleGuideColor.TableItem)
			button.BorderSizePixel = 0
			button.AutoButtonColor = enabled
			button.Font = Enum.Font.SourceSans
			button.TextSize = 14
			button.TextColor3 = color(
				if enabled then Enum.StudioStyleGuideColor.MainText else Enum.StudioStyleGuideColor.DimmedText
			)
			button.TextXAlignment = Enum.TextXAlignment.Left
			button.TextTruncate = Enum.TextTruncate.AtEnd
			button.Text = item.text
			button.ZIndex = 11
			indent(button)
			button.Parent = list

			button.Activated:Connect(function()
				if not enabled then
					return
				end

				closeDropdown()
				item.activate()
			end)
		end
	end

	local function makeEditorContainer(): Frame
		local container = Instance.new("Frame")
		container.BackgroundTransparency = 1
		container.Position = UDim2.new(NAME_COLUMN, 0, 0, 0)
		container.Size = UDim2.new(1 - NAME_COLUMN, -PADDING, 1, 0)
		return container
	end

	local function makeInput(): TextBox
		local box = Instance.new("TextBox")
		box.Position = UDim2.fromOffset(0, 2)
		box.Size = UDim2.new(1, 0, 1, -4)
		box.BackgroundColor3 = color(Enum.StudioStyleGuideColor.InputFieldBackground)
		box.BorderColor3 = color(Enum.StudioStyleGuideColor.InputFieldBorder)
		box.Font = Enum.Font.SourceSans
		box.TextSize = 14
		box.TextColor3 = color(Enum.StudioStyleGuideColor.MainText)
		box.TextXAlignment = Enum.TextXAlignment.Left
		box.PlaceholderText = "(not set)"
		box.PlaceholderColor3 = color(Enum.StudioStyleGuideColor.DimmedText)
		box.ClearTextOnFocus = false
		box.Text = ""
		indent(box)
		return box
	end

	local function makeValueButton(text: string, unset: boolean): TextButton
		local button = Instance.new("TextButton")
		button.Position = UDim2.fromOffset(0, 2)
		button.Size = UDim2.new(1, 0, 1, -4)
		button.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Button)
		button.BorderColor3 = color(Enum.StudioStyleGuideColor.ButtonBorder)
		button.Font = Enum.Font.SourceSans
		button.TextSize = 14
		button.TextColor3 = color(
			if unset then Enum.StudioStyleGuideColor.DimmedText else Enum.StudioStyleGuideColor.ButtonText
		)
		button.TextXAlignment = Enum.TextXAlignment.Left
		button.TextTruncate = Enum.TextTruncate.AtEnd
		button.Text = text
		indent(button)
		return button
	end

	-- Text and number fields both commit when the field loses focus, and put
	-- back the old text when what was typed cannot be used. Clearing a field
	-- removes an optional attribute; a required one cannot be cleared, since the
	-- nodes only warn about a missing parameter before failing on it.
	local function makeTextEditor(node: Instance, descriptor, value: any): Frame
		local container = makeEditorContainer()
		local box = makeInput()

		local function display(): string
			if value == nil then
				return ""
			end
			return if descriptor.kind == "number" then string.format("%g", value) else tostring(value)
		end

		box.Text = display()
		box.Parent = container

		box.FocusLost:Connect(function()
			local text = string.match(box.Text, "^%s*(.-)%s*$")

			if text == "" then
				if descriptor.optional then
					commitValue(node, descriptor, nil)
				elseif descriptor.kind == "string" then
					commitValue(node, descriptor, "")
				else
					box.Text = display()
				end
				return
			end

			if descriptor.kind ~= "number" then
				commitValue(node, descriptor, text)
				return
			end

			local number = tonumber(text)
			if number == nil then
				box.Text = display()
				return
			end

			commitValue(node, descriptor, if descriptor.integer then math.round(number) else number)
		end)

		return container
	end

	local function makeChoiceEditor(node: Instance, descriptor, value: any): Frame
		local container = makeEditorContainer()
		local button = makeValueButton(if value ~= nil then tostring(value) else "(not set)", value == nil)
		button.Parent = container

		local items = {}
		for _, option in descriptor.choices do
			table.insert(items, {
				text = option,
				activate = function()
					commitValue(node, descriptor, option)
				end,
			})
		end

		if descriptor.optional then
			table.insert(items, {
				text = "(not set)",
				activate = function()
					commitValue(node, descriptor, nil)
				end,
			})
		end

		button.Activated:Connect(function()
			openDropdown(button, items)
		end)

		return container
	end

	-- An instance reference cannot be typed, so it is set from the Studio
	-- selection, which is the same gesture the Properties pane uses for an
	-- ObjectValue. The menu is built at click time because the selection is.
	local function makeInstanceEditor(node: Instance, descriptor, value: any): Frame
		local container = makeEditorContainer()
		local button = makeValueButton(if value ~= nil then value.Name else "(not set)", value == nil)
		button.Parent = container

		button.Activated:Connect(function()
			local items = {}

			-- The button only has room for a name, and a name alone is often
			-- ambiguous, so the menu opens with where the thing actually lives.
			if value ~= nil then
				table.insert(items, { text = value:GetFullName() })
			end

			local selected = Selection:Get()
			if #selected == 1 then
				table.insert(items, {
					text = "Set to " .. selected[1].Name,
					activate = function()
						commitValue(node, descriptor, selected[1])
					end,
				})
			else
				table.insert(items, { text = "Select one instance in Studio to set" })
			end

			if value ~= nil then
				table.insert(items, {
					text = "Clear",
					activate = function()
						commitValue(node, descriptor, nil)
					end,
				})
			end

			openDropdown(button, items)
		end)

		return container
	end

	-- The runtime reads AvoidIntersections as `== true`, so an unset attribute
	-- and false mean the same thing and the box only ever writes a real boolean.
	local function makeBooleanEditor(node: Instance, descriptor, value: any): Frame
		local container = makeEditorContainer()
		local checked = value == true
		local button = makeValueButton(tostring(checked), value == nil)
		button.Parent = container

		button.Activated:Connect(function()
			commitValue(node, descriptor, not checked)
		end)

		return container
	end

	local function makeVector2Editor(node: Instance, descriptor, value: any): Frame
		local container = makeEditorContainer()
		local components = descriptor.components or { "X", "Y" }
		local current = value or descriptor.default or Vector2.zero

		for index = 1, 2 do
			local box = makeInput()
			box.Size = UDim2.new(0.5, -2, 1, -4)
			box.Position = UDim2.new(0.5 * (index - 1), if index == 1 then 0 else 2, 0, 2)
			box.PlaceholderText = components[index]
			box.Text = if value ~= nil then string.format("%g", if index == 1 then value.X else value.Y) else ""
			box.Parent = container

			box.FocusLost:Connect(function()
				local number = tonumber(box.Text)
				if number == nil then
					box.Text = if value ~= nil
						then string.format("%g", if index == 1 then value.X else value.Y)
						else ""
					return
				end

				local updated = if index == 1 then Vector2.new(number, current.Y) else Vector2.new(current.X, number)
				commitValue(node, descriptor, updated)
			end)
		end

		return container
	end

	local function makeSequenceEditor(node: Instance, descriptor, value: any): Frame
		local container = makeEditorContainer()
		local button = makeValueButton(if value ~= nil then formatValue(value) else "(not set)", value == nil)
		button.Parent = container

		button.Activated:Connect(function()
			SequenceEditor.open(
				pluginRef,
				node.Name .. "." .. descriptor.name,
				descriptor.kind,
				value or descriptor.default,
				function(sequence)
					commitValue(node, descriptor, sequence)
				end
			)
		end)

		return container
	end

	local function makeEditor(node: Instance, descriptor, value: any): Frame
		if descriptor.kind == "number" or descriptor.kind == "string" then
			return makeTextEditor(node, descriptor, value)
		elseif descriptor.kind == "choice" then
			return makeChoiceEditor(node, descriptor, value)
		elseif descriptor.kind == "boolean" then
			return makeBooleanEditor(node, descriptor, value)
		elseif descriptor.kind == "vector2" then
			return makeVector2Editor(node, descriptor, value)
		elseif descriptor.kind == "numberSequence" or descriptor.kind == "colorSequence" then
			return makeSequenceEditor(node, descriptor, value)
		elseif descriptor.kind == "instance" then
			return makeInstanceEditor(node, descriptor, value)
		end

		local container = makeEditorContainer()
		local label = makeLabel(
			if value ~= nil then formatValue(value) else "(not set)",
			color(Enum.StudioStyleGuideColor.DimmedText),
			false
		)
		label.Size = UDim2.fromScale(1, 1)
		label.Parent = container
		return container
	end

	local function addAttributeRow(node: Instance, descriptor, order: number)
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
		row.LayoutOrder = order

		-- Both ways of naming the geometry are always shown, so the one that is
		-- currently losing says as much rather than looking like it applies.
		local superseded = isSuperseded(node, descriptor)
		local name = if superseded then descriptor.name .. " (unused)" else descriptor.name

		local nameLabel = makeLabel(name, color(Enum.StudioStyleGuideColor.DimmedText), false)
		nameLabel.Size = UDim2.new(NAME_COLUMN, -PADDING, 1, 0)
		nameLabel.Position = UDim2.fromOffset(PADDING, 0)
		nameLabel.Parent = row

		-- Hung off the name rather than the whole row: the editors are their own
		-- input targets, and a tooltip that came and went as the pointer crossed
		-- into a field would be a distraction while typing.
		if descriptor.description ~= nil then
			watchForTooltip(nameLabel, descriptor.description)
		end

		local editor = makeEditor(node, descriptor, readDescriptorValue(node, descriptor))
		if superseded then
			local box = editor:FindFirstChildOfClass("TextBox")
			if box ~= nil then
				box.PlaceholderText = "(" .. descriptor.supersededBy .. " is set)"
			end
		end
		editor.Parent = row

		row.Parent = detailList
	end

	-- Full-width prose, for the cases where there are no attributes to lay out in
	-- two columns.
	local function addDetailMessage(text: string, order: number)
		local label = makeLabel(text, color(Enum.StudioStyleGuideColor.DimmedText), false)
		label.Size = UDim2.new(1, -PADDING * 2, 0, ROW_HEIGHT)
		label.LayoutOrder = order
		label.TextTruncate = Enum.TextTruncate.None
		label.TextWrapped = true
		label.AutomaticSize = Enum.AutomaticSize.Y
		indent(label)
		label.Parent = detailList
	end

	local function addDetailSection(node: Instance, order: number)
		local nodeType = node:GetAttribute("NodeType")

		-- Reveals the node in the Explorer and the Properties pane, for the parts
		-- of it this window does not show. The selection still resolves to this
		-- same graph, so the panes survive the round trip.
		local section = Instance.new("TextButton")
		section.Size = UDim2.new(1, 0, 0, SECTION_HEIGHT)
		section.LayoutOrder = order
		section.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Titlebar)
		section.BorderSizePixel = 0
		section.AutoButtonColor = false
		section.Font = Enum.Font.SourceSansBold
		section.TextSize = 14
		section.TextColor3 = color(Enum.StudioStyleGuideColor.BrightText)
		section.TextXAlignment = Enum.TextXAlignment.Left
		section.TextTruncate = Enum.TextTruncate.AtEnd
		section.Text = node.Name .. "  (" .. tostring(nodeType) .. ")"
		indent(section)
		section.Parent = detailList

		section.Activated:Connect(function()
			Selection:Set({ node })
		end)

		watchForTooltip(section, "Click to select this node in the Explorer, where the Properties pane shows "
			.. "what this window leaves out.")
	end

	local function showOutput(output: ObjectValue?)
		clearDetail()

		if output == nil then
			detailHeader.Text = "No rule selected"
			return
		end

		detailHeader.Text = output.Name

		if output.Value == nil then
			addDetailMessage("This output is not wired to a node.", 0)
			return
		end

		local ordered = {}
		collectUpstreamNodes(output.Value, {}, ordered)

		local function rebuild()
			showOutput(output)
		end

		local order = 0
		for _, node in ordered do
			order += 1
			addDetailSection(node, order)

			local rows = AttributeSchema.rowsFor(node)
			if #rows == 0 then
				order += 1
				addDetailMessage("(no attributes)", order)
			end

			for _, descriptor in rows do
				order += 1
				addAttributeRow(node, descriptor, order)
			end

			-- A row's value may live in an attribute or in a child ObjectValue,
			-- and either can be changed from here, from the Properties pane, or
			-- by an undo, so the pane watches both. Rewiring a Points wire also
			-- changes which nodes belong on screen at all.
			table.insert(detailConnections, node.AttributeChanged:Connect(rebuild))
			table.insert(detailConnections, node.ChildAdded:Connect(rebuild))
			table.insert(detailConnections, node.ChildRemoved:Connect(rebuild))

			for _, child in node:GetChildren() do
				if child:IsA("ObjectValue") then
					table.insert(detailConnections, child.Changed:Connect(rebuild))
				end
			end
		end
	end

	local function addListRow(list: ScrollingFrame, text: string, isSelected: boolean, order: number, pick: () -> ())
		local row = Instance.new("TextButton")
		row.Size = UDim2.new(1, 0, 0, SECTION_HEIGHT)
		row.LayoutOrder = order
		row.BackgroundColor3 = color(
			Enum.StudioStyleGuideColor.TableItem,
			if isSelected then Enum.StudioStyleGuideModifier.Selected else nil
		)
		row.BorderSizePixel = 0
		row.Font = Enum.Font.SourceSans
		row.TextSize = 14
		row.TextColor3 = color(
			if isSelected then Enum.StudioStyleGuideColor.BrightText else Enum.StudioStyleGuideColor.MainText
		)
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.TextTruncate = Enum.TextTruncate.AtEnd
		row.Text = text
		indent(row)
		row.Parent = list

		row.Activated:Connect(pick)
	end

	local function addListMessage(list: ScrollingFrame, text: string)
		local label = makeLabel(text, color(Enum.StudioStyleGuideColor.DimmedText), false)
		label.Size = UDim2.new(1, -PADDING * 2, 0, SECTION_HEIGHT)
		label.TextTruncate = Enum.TextTruncate.None
		label.TextWrapped = true
		label.AutomaticSize = Enum.AutomaticSize.Y
		indent(label)
		label.Parent = list
	end

	local function clearList(list: ScrollingFrame)
		for _, child in list:GetChildren() do
			if not child:IsA("UIListLayout") then
				child:Destroy()
			end
		end
	end

	local function deleteSelectedRule()
		local graph = activeGraph()
		if graph == nil or selectedOutputName == nil then
			return
		end

		local outputs = collectOutputs(graph)
		local target = nil
		for _, output in outputs do
			if output.Name == selectedOutputName then
				target = output
			end
		end

		if target == nil then
			return
		end

		recorded("Delete ScatterGraph rule", function()
			deleteRule(graph, target, outputs)
		end)

		selectedOutputName = nil
		refreshRules()
	end

	local function addTemplateRule(template)
		local graph = activeGraph()
		if graph == nil then
			return
		end

		local ruleName, folder
		local added = recorded("Add ScatterGraph rule", function()
			ruleName, folder = addRule(graph, template)
		end)

		if not added then
			return
		end

		selectedOutputName = ruleName
		-- Reveals the new nodes in the Explorer, where the parts of a rule this
		-- window does not show can be edited.
		Selection:Set({ folder })
		refreshRules()
	end

	local function createGraph()
		local graph
		local made = recorded("New ScatterGraph", function()
			graph = makeGraph()
		end)

		if not made then
			return
		end

		currentGraph = graph
		selectedOutputName = nil
		-- Reveals it in the Explorer, which is where it gets its real name: a
		-- graph is picked out by name in every volume that uses it.
		Selection:Set({ graph })
		refresh()
	end

	local function deleteCurrentGraph()
		local graph = activeGraph()
		if graph == nil then
			return
		end

		recorded("Delete ScatterGraph", function()
			-- Unparented rather than destroyed, so ctrl-Z can put it back. See
			-- deleteRule.
			graph.Parent = nil
		end)

		currentGraph = nil
		selectedOutputName = nil
		refresh()
	end

	-- spec: { icon, label, tooltip, requires, activate }, where requires is
	-- "none", "graph" or "output" -- what has to be selected for the button to
	-- do anything.
	local function addRibbonButton(spec)
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(0, 0, 0, BUTTON_HEIGHT)
		button.AutomaticSize = Enum.AutomaticSize.X
		button.LayoutOrder = #ribbonButtons + 1
		button.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Button)
		button.BorderSizePixel = 0
		button.Font = Enum.Font.SourceSans
		button.TextSize = 14
		button.TextColor3 = color(Enum.StudioStyleGuideColor.ButtonText)
		button.Text = spec.icon .. "  " .. spec.label

		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, PADDING)
		padding.PaddingRight = UDim.new(0, PADDING)
		padding.Parent = button

		-- The handlers re-resolve what they act on, so a click that slips
		-- through while the button looks disabled still does nothing.
		button.Activated:Connect(spec.activate)
		watchForTooltip(button, spec.tooltip)

		table.insert(ribbonButtons, { button = button, requires = spec.requires })
		return button
	end

	local function updateRibbon(hasGraph: boolean, hasOutput: boolean)
		for _, entry in ribbonButtons do
			local enabled = if entry.requires == "output"
				then hasOutput
				elseif entry.requires == "graph" then hasGraph
				else true
			local modifier = if enabled then nil else Enum.StudioStyleGuideModifier.Disabled

			entry.button.Active = enabled
			entry.button.AutoButtonColor = enabled
			entry.button.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Button, modifier)
			entry.button.TextColor3 = color(Enum.StudioStyleGuideColor.ButtonText, modifier)
		end
	end

	local function buildInterface()
		if root ~= nil then
			root:Destroy()
		end

		local rootFrame = Instance.new("Frame")
		root = rootFrame
		rootFrame.Size = UDim2.fromScale(1, 1)
		rootFrame.BackgroundColor3 = color(Enum.StudioStyleGuideColor.MainBackground)
		rootFrame.BorderSizePixel = 0
		rootFrame.Parent = widget

		local function makePane(position: UDim2, size: UDim2, title: string): (TextLabel, ScrollingFrame)
			local pane = Instance.new("Frame")
			pane.Position = position
			pane.Size = size
			pane.BackgroundTransparency = 1
			pane.Parent = rootFrame

			local header = makeLabel(title, color(Enum.StudioStyleGuideColor.SubText), true)
			header.Size = UDim2.new(1, -PADDING * 2, 0, HEADER_HEIGHT)
			header.Position = UDim2.fromOffset(PADDING, 0)
			header.Parent = pane

			local scroll = Instance.new("ScrollingFrame")
			scroll.Position = UDim2.fromOffset(0, HEADER_HEIGHT)
			scroll.Size = UDim2.new(1, 0, 1, -HEADER_HEIGHT)
			scroll.BackgroundTransparency = 1
			scroll.BorderSizePixel = 0
			scroll.CanvasSize = UDim2.new()
			scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
			scroll.ScrollBarThickness = 8
			scroll.Parent = pane

			local layout = Instance.new("UIListLayout")
			layout.SortOrder = Enum.SortOrder.LayoutOrder
			layout.Parent = scroll

			return header, scroll
		end

		local function makeEdge(y: number)
			local edge = Instance.new("Frame")
			edge.Position = UDim2.fromOffset(0, y)
			edge.Size = UDim2.new(1, 0, 0, 1)
			edge.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Border)
			edge.BorderSizePixel = 0
			edge.Parent = rootFrame
		end

		local function makeRibbonRow(y: number): Frame
			local ribbon = Instance.new("Frame")
			ribbon.Position = UDim2.fromOffset(0, y)
			ribbon.Size = UDim2.new(1, 0, 0, RIBBON_HEIGHT)
			ribbon.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Titlebar)
			ribbon.BorderSizePixel = 0
			ribbon.Parent = rootFrame

			local layout = Instance.new("UIListLayout")
			layout.FillDirection = Enum.FillDirection.Horizontal
			layout.VerticalAlignment = Enum.VerticalAlignment.Center
			layout.SortOrder = Enum.SortOrder.LayoutOrder
			layout.Padding = UDim.new(0, 4)
			layout.Parent = ribbon

			local padding = Instance.new("UIPadding")
			padding.PaddingLeft = UDim.new(0, PADDING)
			padding.Parent = ribbon

			return ribbon
		end

		-- Two rows, because the buttons act at two different scales: the top one
		-- makes and unmakes whole graphs, the one below it edits the rules
		-- inside the graph the top row left selected.
		local graphRibbon = makeRibbonRow(0)
		makeEdge(RIBBON_HEIGHT)
		local ruleRibbon = makeRibbonRow(RIBBON_HEIGHT + 1)

		-- Icons are emoji rather than rbxassetid images: the plugin ships no art,
		-- and the emoji font is the one glyph source that is always present.
		-- Chosen from the set Studio itself ships an emoji for, and from the
		-- solid ones within that: line-drawn glyphs like the spider web lose
		-- their shape at this size.
		table.clear(ribbonButtons)
		addRibbonButton({
			icon = "\u{1F517}",
			label = "New Graph",
			tooltip = "Adds an empty graph to ReplicatedStorage.ScatterGraphs and selects it here and in the "
				.. "Explorer. Rename it there: a scatter volume names the graph it uses.",
			requires = "none",
			activate = createGraph,
		}).Parent = graphRibbon
		addRibbonButton({
			icon = "\u{274C}",
			label = "Delete Graph",
			tooltip = "Deletes the selected graph and every rule in it. Volumes pointing at it place nothing "
				.. "until they are pointed somewhere else. Undo brings it back.",
			requires = "graph",
			activate = deleteCurrentGraph,
		}).Parent = graphRibbon

		addRibbonButton({
			icon = "\u{274C}",
			label = "Delete",
			tooltip = "Deletes the selected rule: its Output entry and the nodes feeding it. A node another "
				.. "rule also feeds from is left alone.",
			requires = "output",
			activate = deleteSelectedRule,
		}).Parent = ruleRibbon
		addRibbonButton({
			icon = "\u{1F332}",
			label = "Terrain Prop",
			tooltip = "Adds a rule that scatters points, drops them onto the terrain and places one asset at "
				.. "each: ScatterPoints, SnapPointsToTerrain, PlaceAssetOnPoints. Set its Asset to finish it.",
			requires = "graph",
			activate = function()
				addTemplateRule(RULE_TEMPLATES.terrainProp)
			end,
		}).Parent = ruleRibbon
		addRibbonButton({
			icon = "\u{1F33F}",
			label = "Cluster",
			tooltip = "Adds a rule that scatters points, spreads a clump around each one and drops those onto "
				.. "the terrain: ScatterPoints, ScatterPointsAroundPoints, SnapPointsToTerrain, "
				.. "PlaceAssetOnPoints. Set its Asset to finish it.",
			requires = "graph",
			activate = function()
				addTemplateRule(RULE_TEMPLATES.cluster)
			end,
		}).Parent = ruleRibbon
		addRibbonButton({
			icon = "\u{1F426}",
			label = "Floating Prop",
			tooltip = "Adds a rule that places an asset at each scattered point without consulting the "
				.. "terrain, for anything that hangs in the air: ScatterPoints, PlaceAssetOnPoints. Set its "
				.. "Asset to finish it.",
			requires = "graph",
			activate = function()
				addTemplateRule(RULE_TEMPLATES.floatingProp)
			end,
		}).Parent = ruleRibbon

		local paneTop = (RIBBON_HEIGHT + 1) * 2
		makeEdge(paneTop - 1)

		local function makeDivider(x: number)
			local divider = Instance.new("Frame")
			divider.Position = UDim2.new(x, 0, 0, paneTop)
			divider.Size = UDim2.new(0, 1, 1, -paneTop)
			divider.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Border)
			divider.BorderSizePixel = 0
			divider.Parent = rootFrame
		end

		local _, graphScroll =
			makePane(UDim2.fromOffset(0, paneTop), UDim2.new(GRAPH_COLUMN, 0, 1, -paneTop), "ScatterGraphs")
		graphList = graphScroll

		makeDivider(GRAPH_COLUMN)

		local outputTitle, outputScroll = makePane(
			UDim2.new(GRAPH_COLUMN, 1, 0, paneTop),
			UDim2.new(OUTPUT_COLUMN, -1, 1, -paneTop),
			"No graph selected"
		)
		outputHeader = outputTitle
		outputList = outputScroll

		local detailLeft = GRAPH_COLUMN + OUTPUT_COLUMN
		makeDivider(detailLeft)

		local header, detailScroll = makePane(
			UDim2.new(detailLeft, 1, 0, paneTop),
			UDim2.new(1 - detailLeft, -1, 1, -paneTop),
			"No rule selected"
		)
		detailHeader = header
		detailList = detailScroll
	end

	refreshRules = function()
		local graph = activeGraph()

		clearDetail()
		clearList(outputList)

		if graph == nil then
			selectedOutputName = nil
			updateRibbon(false, false)
			outputHeader.Text = "No graph selected"
			detailHeader.Text = "No rule selected"
			addDetailMessage("Select a ScatterGraph on the left.", 0)
			return
		end

		outputHeader.Text = graph.Name

		local outputs = collectOutputs(graph)
		if #outputs == 0 then
			selectedOutputName = nil
			updateRibbon(true, false)
			detailHeader.Text = "No rule selected"
			addDetailMessage(graph.Name .. " has no outputs. Add a rule from the ribbon above.", 0)
			return
		end

		updateRibbon(true, true)

		-- The rule picked in one graph rarely exists in the next, so moving
		-- between graphs falls back to the first rule rather than leaving the
		-- detail pane blank for no visible reason. Resolved before the rows are
		-- built so the right one is drawn as selected.
		local selected = nil
		for _, output in outputs do
			if output.Name == selectedOutputName then
				selected = output
			end
		end
		if selected == nil then
			selected = outputs[1]
			selectedOutputName = selected.Name
		end

		for index, output in outputs do
			addListRow(outputList, output.Name, output == selected, index, function()
				selectedOutputName = output.Name
				refreshRules()
			end)
		end

		showOutput(selected)
	end

	-- Rebuilds the graph list, keeping the chosen graph if it is still there and
	-- falling to the first one if it is not. Returns whether that changed which
	-- graph the other two panes should be showing.
	local function refreshGraphs(): boolean
		local previous = activeGraph()
		local graphs = collectGraphs()

		local stillPresent = false
		for _, graph in graphs do
			if graph == previous then
				stillPresent = true
			end
		end

		if not stillPresent then
			currentGraph = graphs[1]
		end

		clearList(graphList)

		if #graphs == 0 then
			addListMessage(graphList, "No ScatterGraphs in this place.")
		end

		for index, graph in graphs do
			addListRow(graphList, graph.Name, graph == currentGraph, index, function()
				if graph == currentGraph then
					return
				end

				currentGraph = graph
				selectedOutputName = nil
				refreshGraphs()
				refreshRules()
			end)
		end

		return currentGraph ~= previous
	end

	refresh = function()
		if not widget.Enabled then
			return
		end

		if root == nil then
			buildInterface()
		end

		refreshGraphs()
		refreshRules()
	end

	widget:GetPropertyChangedSignal("Enabled"):Connect(function()
		button:SetActive(widget.Enabled)
		refresh()
	end)

	-- A graph can be added or removed from anywhere in Studio, and a selection
	-- change is the cheapest reliable sign that the user has been doing
	-- something. Only the graph list is rebuilt: the Asset editor reads the
	-- selection, so redrawing the rule and detail panes here would tear down the
	-- menu the user is picking from. The open menu is closed instead, since what
	-- it offers was decided when it opened.
	Selection.SelectionChanged:Connect(function()
		if not widget.Enabled or root == nil then
			return
		end

		closeDropdown()

		if refreshGraphs() then
			refreshRules()
		end
	end)

	settings().Studio.ThemeChanged:Connect(function()
		if root ~= nil then
			root:Destroy()
			root = nil
		end
		refresh()
	end)

	button.Click:Connect(function()
		widget.Enabled = not widget.Enabled
	end)

	button:SetActive(widget.Enabled)
	refresh()
end

return RulesWindow
