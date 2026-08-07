--[[
	RulesWindow

	The "Spreadsheet View" dock widget: an inspector and editor for the biome
	graphs in the place, in three panes that read left to right.

	The first lists every ScatterGraph the place contains. Picking one fills the
	second with that graph's outputs -- the ObjectValue entries under its Output
	node, one per placement rule. Picking one of those fills the third with every
	attribute of every node that feeds it, walked upstream through the Points
	wires so the chain reads source-first the way the graph does. That third
	pane is a NodeInspector, which the Graph view uses too.

	This window shows a rule as a list, which suits reading and tuning one rule.
	The Graph view, opened from its own toolbar button, shows the same graph as a
	canvas of wired nodes, which suits rearranging it.

	The Studio selection does not choose which graph is shown here -- the first
	pane does. The selection is what the Asset editor reads to name the geometry
	a rule places, so a window that followed it would empty itself in the middle
	of that gesture. The Graph view, having no such list, does read it, but only
	at the moment its button is clicked.

	The two ribbon rows along the top edit what the panes below them show. The
	upper row makes and deletes whole graphs; the lower one deletes the selected
	rule or adds one of the three chains that cover almost every rule in
	practice. Every edit goes through GraphUi's `recorded`, so ctrl-Z undoes it
	like any other Studio change.
]]

local Selection = game:GetService("Selection")

local GraphUi = require(script.Parent:WaitForChild("GraphUi"))
local Graphs = require(script.Parent:WaitForChild("Graphs"))
local NodeInspector = require(script.Parent:WaitForChild("NodeInspector"))
local RuleTemplates = require(script.Parent:WaitForChild("RuleTemplates"))

local RulesWindow = {}

local PADDING = GraphUi.PADDING
local SECTION_HEIGHT = GraphUi.SECTION_HEIGHT
local HEADER_HEIGHT = GraphUi.HEADER_HEIGHT
local RIBBON_HEIGHT = GraphUi.RIBBON_HEIGHT
local BUTTON_HEIGHT = GraphUi.BUTTON_HEIGHT
-- How the width is divided between the three panes. The last takes what is left.
local GRAPH_COLUMN = 0.22
local OUTPUT_COLUMN = 0.26

local color = GraphUi.color
local indent = GraphUi.indent
local makeLabel = GraphUi.makeLabel
local recorded = GraphUi.recorded

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

function RulesWindow.install(pluginRef: Plugin, button: PluginToolbarButton)
	-- Three panes side by side need a wider window than two did.
	local widgetInfo = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 720, 400, 460, 240)
	-- The id stays as it was named, whatever the window is called: it is what
	-- Studio files the window's size and docking under between sessions.
	local widget = pluginRef:CreateDockWidgetPluginGui("ScatterGraphRules", widgetInfo)
	widget.Name = "ScatterGraphRules"
	widget.Title = "ScatterGraph Spreadsheet View"
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
	-- Most ribbon buttons act on the selected graph or the selected rule, so
	-- they are greyed out when there is none; each remembers which it needs.
	-- Rebuilt with the rest of the interface.
	local ribbonButtons = {}
	-- The tooltips and menus this window floats over itself, and the panel that
	-- draws the third pane.
	local overlay = GraphUi.newOverlay()
	local inspector = NodeInspector.new(pluginRef, overlay)

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

	-- The panel is handed the chain rather than the output, and asks for it
	-- again on every rebuild: rewiring a Points wire changes which nodes belong
	-- on screen, and by then the output alone is all that is still known to be
	-- good.
	local function showOutput(output: ObjectValue?)
		if output == nil then
			detailHeader.Text = "No rule selected"
			inspector.clear()
			return
		end

		detailHeader.Text = output.Name

		inspector.show(function()
			if output.Parent == nil or output.Value == nil then
				return {}
			end

			local ordered = {}
			collectUpstreamNodes(output.Value, {}, ordered)
			return ordered
		end, "This output is not wired to a node.")
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
			ruleName, folder = RuleTemplates.add(graph, template)
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
			graph = Graphs.create()
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
		overlay.watchForTooltip(button, spec.tooltip)

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

		-- The floating panels belong to whatever frame is current, and the one
		-- they were last parented to has just been destroyed.
		overlay.attach(rootFrame)

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
		-- One button per template, in the templates' own order and under their own
		-- names, since the Graph view offers the same ones from the same place.
		for _, template in RuleTemplates.ordered do
			addRibbonButton({
				icon = template.icon,
				label = template.label,
				tooltip = template.tooltip,
				requires = "graph",
				activate = function()
					addTemplateRule(template)
				end,
			}).Parent = ruleRibbon
		end

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
		inspector.setList(detailList)
	end

	-- Nothing to inspect, but the pane says why rather than sitting blank.
	local function showNothing(message: string)
		detailHeader.Text = "No rule selected"
		inspector.show(function()
			return {}
		end, message)
	end

	refreshRules = function()
		local graph = activeGraph()

		inspector.clear()
		clearList(outputList)

		if graph == nil then
			selectedOutputName = nil
			updateRibbon(false, false)
			outputHeader.Text = "No graph selected"
			showNothing("Select a ScatterGraph on the left.")
			return
		end

		outputHeader.Text = graph.Name

		local outputs = collectOutputs(graph)
		if #outputs == 0 then
			selectedOutputName = nil
			updateRibbon(true, false)
			showNothing(graph.Name .. " has no outputs. Add a rule from the ribbon above.")
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
		local graphs = Graphs.inPlace()

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

		overlay.closeDropdown()

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
