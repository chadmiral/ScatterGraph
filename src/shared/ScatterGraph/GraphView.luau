--[[
	GraphView

	The graph as a graph: every node of one ScatterGraph on a canvas, wired to
	the nodes it feeds, with the parameters of whichever node is selected in a
	panel down the right-hand side.

	The Rules window shows a rule as a flat list, which suits reading and tuning
	one rule at a time. This shows the shape of the whole thing, which is what
	rearranging it needs. Both edit the same instances -- a node is a Model
	carrying a NodeType attribute, a connection is a child ObjectValue pointing
	at the node upstream of it -- so either window can be left open while the
	other is used, and each picks up the other's edits.

	The canvas is slid with the middle mouse button and zoomed with the wheel,
	which leaves the left button free for the graph itself: picking a node,
	carrying one, and trailing a wire out of a port. The right button opens the
	node types as a menu, and adds the one chosen where the menu was opened.

	Where the nodes sit is the one thing on the canvas that is not already in
	the graph. A node dragged to a new place keeps it in a GraphPosition
	attribute; a node that has never been dragged is laid out in columns by how
	far it is from a source, which is a readable starting arrangement and costs
	nothing to throw away. Nothing is written until something is dragged.
]]

local UserInputService = game:GetService("UserInputService")

local GraphUi = require(script.Parent:WaitForChild("GraphUi"))
local NodeInspector = require(script.Parent:WaitForChild("NodeInspector"))

local GraphView = {}

local PADDING = GraphUi.PADDING
local HEADER_HEIGHT = GraphUi.HEADER_HEIGHT
local RIBBON_HEIGHT = GraphUi.RIBBON_HEIGHT
local BUTTON_HEIGHT = GraphUi.BUTTON_HEIGHT

local color = GraphUi.color
local makeLabel = GraphUi.makeLabel
local recorded = GraphUi.recorded
local findWire = GraphUi.findWire

-- Canvas geometry, in canvas pixels.
local NODE_WIDTH = 176
local TITLE_HEIGHT = 24
local PORT_ROW = 20
local PORT_SIZE = 10
-- How close a dropped wire has to land to count as hitting a port. Larger than
-- the port itself, because the port is small and the gesture is not precise.
local PORT_HIT = 14
local WIRE_THICKNESS = 2
local BREAK_SIZE = 10
local COLUMN_GAP = 72
local ROW_GAP = 24
local MARGIN = 40
-- How far one notch of the wheel moves the zoom, and how far it is allowed to
-- go: far enough out to see a large graph whole, far enough in that a node's
-- text is still worth reading.
local ZOOM_STEP = 1.1
local ZOOM_MIN = 0.25
local ZOOM_MAX = 2.5
-- Share of the window the parameter panel takes.
local PARAM_COLUMN = 0.32

-- Where a node remembers having been dragged to. Hidden from the parameter
-- panel by AttributeSchema, since it belongs to this canvas rather than to the
-- graph the runtime evaluates.
local POSITION_ATTRIBUTE = "GraphPosition"

-- What "Add Node" offers. These values are a starting point for a node built by
-- hand; the Rules window's whole-rule templates tune the same attributes
-- further for the chain each one belongs to.
local NODE_TEMPLATES = {
	{
		label = "Scatter Points",
		name = "ScatterPoints",
		nodeType = "ScatterPoints",
		attributes = { Seed = 1, Spacing = 40 },
	},
	{
		label = "Scatter Around Points",
		name = "ScatterPointsAroundPoints",
		nodeType = "ScatterPointsAroundPoints",
		attributes = { Seed = 2, InnerRadius = 0, OuterRadius = 8, Count = 10 },
	},
	{
		label = "Snap To Terrain",
		name = "SnapPointsToTerrain",
		nodeType = "SnapPointsToTerrain",
		attributes = { MaterialFilter = "Water", SlopeFilter = NumberSequence.new(1, 0) },
	},
	{
		-- Named PlaceAssetOnPoints while its NodeType is PlaceGeometryOnPoints,
		-- which is how every existing graph has it.
		label = "Place Asset",
		name = "PlaceAssetOnPoints",
		nodeType = "PlaceGeometryOnPoints",
		attributes = { ScaleRange = Vector2.new(0.9, 1.1), RotationType = "UpAxis" },
	},
}

-- Wires carry a NodeType attribute of their own, so being one is not enough.
local function isNode(instance: Instance): boolean
	return not instance:IsA("ObjectValue") and instance:GetAttribute("NodeType") ~= nil
end

local function isOutput(node: Instance): boolean
	return node:GetAttribute("NodeType") == "Output"
end

local function collectNodes(graph: Instance): { Instance }
	local nodes = {}

	for _, descendant in graph:GetDescendants() do
		if isNode(descendant) then
			table.insert(nodes, descendant)
		end
	end

	-- Only so that a graph draws the same way twice; the arrangement itself
	-- comes from the layout below.
	table.sort(nodes, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)

	return nodes
end

-- The slots down the left of a node, top to bottom. The Output registry has one
-- per rule registered with it, plus an empty one so that another can be added by
-- dropping a wire on it; every other node reads points from a single Points
-- wire, and a source node reads nothing at all.
local function inputPortsOf(node: Instance)
	if isOutput(node) then
		local ports = {}

		for _, child in node:GetChildren() do
			if child:IsA("ObjectValue") then
				table.insert(ports, { name = child.Name, wire = child })
			end
		end

		table.sort(ports, function(a, b)
			return a.name < b.name
		end)

		table.insert(ports, { name = "(new rule)", isNew = true })
		return ports
	end

	if node:GetAttribute("NodeType") == "ScatterPoints" then
		return {}
	end

	return { { name = "Points", wire = findWire(node, "Points") } }
end

local function uniqueChildName(parent: Instance, base: string): string
	local name = base
	local suffix = 1

	while parent:FindFirstChild(name) ~= nil do
		suffix += 1
		name = base .. suffix
	end

	return name
end

-- One window, reopened rather than remade: a second canvas over the same graph
-- would be two views of one thing, each able to invalidate the other.
local view = nil

local function create(pluginRef: Plugin)
	local widgetInfo = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 940, 560, 560, 320)
	local widget = pluginRef:CreateDockWidgetPluginGui("ScatterGraphGraphView", widgetInfo)
	widget.Name = "ScatterGraphGraphView"
	widget.Title = "ScatterGraph Graph View"
	widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local self = {}

	local overlay = GraphUi.newOverlay()
	local inspector = NodeInspector.new(pluginRef, overlay)

	local graph: Instance? = nil
	local selected: Instance? = nil
	-- Where the canvas has been scrolled to, in view pixels, and how far it is
	-- zoomed: a node at graph point p is drawn at pan + p * zoom.
	local pan = Vector2.zero
	local zoom = 1
	-- Rebuilt on every redraw: where each node sits, what its slots are, and the
	-- widgets drawn for it.
	local positions: { [Instance]: Vector2 } = {}
	local inputs: { [Instance]: any } = {}
	local cards: { [Instance]: any } = {}
	local wires = {}
	local graphConnections: { RBXScriptConnection } = {}
	local ribbonButtons = {}

	local root = nil
	local canvas = nil
	local content = nil
	local contentScale = nil
	local wireLayer = nil
	local nodeLayer = nil
	local message = nil

	-- What the pointer is doing to the canvas, if anything: sliding it,
	-- carrying a node, or trailing a new connection out of a port.
	local drag = nil
	local pendingWire = nil

	local rebuildQueued = false

	local rebuild
	local buildInterface
	-- Opened from the canvas, but built out of the node templates and the
	-- placement the ribbon's Add Node button uses, which are further down.
	local openContextMenu

	local function applyView()
		if content ~= nil then
			content.Position = UDim2.fromOffset(pan.X, pan.Y)
		end

		if contentScale ~= nil then
			contentScale.Scale = zoom
		end
	end

	-- The first in view pixels, relative to the visible corner of the canvas;
	-- the second in the graph's own pixels, which everything on the canvas is
	-- positioned and measured in whatever the zoom happens to be.
	local function viewPoint(input: InputObject): Vector2
		return Vector2.new(input.Position.X, input.Position.Y) - canvas.AbsolutePosition
	end

	local function canvasPoint(input: InputObject): Vector2
		return (viewPoint(input) - pan) / zoom
	end

	-- In the whole window's pixels, which is what the overlay places the panels
	-- it floats over the window in.
	local function windowPoint(input: InputObject): Vector2
		return Vector2.new(input.Position.X, input.Position.Y) - root.AbsolutePosition
	end

	-- Which rule a node belongs to, where the graph says so. Every chain tends to
	-- be built from identically named nodes -- a dozen rules, a dozen nodes
	-- called ScatterPoints -- so without this a card cannot be told from its
	-- opposite number in the rule below.
	local function ruleOf(node: Instance): string?
		local parent = node.Parent

		if parent == nil or parent == graph or isNode(parent) then
			return nil
		end

		return parent.Name
	end

	-- Everything above the first input slot: the name, the node type, and the
	-- rule if there is one.
	local function headerHeight(node: Instance): number
		return TITLE_HEIGHT + PORT_ROW + (if ruleOf(node) ~= nil then PORT_ROW else 0)
	end

	local function nodeHeight(node: Instance): number
		local ports = inputs[node]
		return headerHeight(node) + (if ports ~= nil then #ports else 0) * PORT_ROW
	end

	local function outputPortCenter(node: Instance): Vector2
		local origin = positions[node] or Vector2.zero
		return origin + Vector2.new(NODE_WIDTH, TITLE_HEIGHT + PORT_ROW / 2)
	end

	local function inputPortCenter(node: Instance, index: number): Vector2
		local origin = positions[node] or Vector2.zero
		return origin + Vector2.new(0, headerHeight(node) + (index - 0.5) * PORT_ROW)
	end

	-- Nodes are placed in columns by how far they are from a source, which puts
	-- every wire left to right and reads the way the points flow, and in rows by
	-- the rule they belong to, so a chain runs along its own line the way it
	-- reads in the Rules window. The Output registry goes at the top of the last
	-- column, since every chain ends up pointing at it. A node with a stored
	-- position overrides all of that.
	local function computeLayout(nodes: { Instance })
		positions = {}

		local depth = {}
		local state = {}

		local function depthOf(node: Instance): number
			if state[node] == "done" then
				return depth[node]
			end

			-- Nothing stops an author wiring a loop, and a loop has no depth;
			-- the walk stops rather than following it round again.
			if state[node] == "visiting" then
				return 0
			end

			state[node] = "visiting"

			local deepest = 0
			for _, port in inputs[node] or {} do
				local source = if port.wire ~= nil then port.wire.Value else nil
				if source ~= nil and inputs[source] ~= nil then
					deepest = math.max(deepest, depthOf(source) + 1)
				end
			end

			state[node] = "done"
			depth[node] = deepest
			return deepest
		end

		local outputNode = nil
		for _, node in nodes do
			if isOutput(node) then
				outputNode = node
			end
		end

		-- Rows are seeded from the Output entries, so each rule takes the next
		-- one down. A node feeding two rules belongs to whichever claims it
		-- first, which is also what stops the walk following a loop round.
		local row = {}
		local rowCount = 0

		local function claim(node: Instance, index: number)
			if row[node] ~= nil then
				return
			end

			row[node] = index

			for _, port in inputs[node] or {} do
				local source = if port.wire ~= nil then port.wire.Value else nil
				if source ~= nil and inputs[source] ~= nil then
					claim(source, index)
				end
			end
		end

		if outputNode ~= nil then
			for _, port in inputs[outputNode] do
				local terminal = if port.wire ~= nil then port.wire.Value else nil
				if terminal ~= nil and inputs[terminal] ~= nil and row[terminal] == nil then
					claim(terminal, rowCount)
					rowCount += 1
				end
			end
		end

		-- Whatever no rule reaches -- a node just added, or one left behind by a
		-- rewire -- gets a row of its own under the rest.
		for _, node in nodes do
			if node ~= outputNode and row[node] == nil then
				claim(node, rowCount)
				rowCount += 1
			end
		end

		local bands = {}
		for _, node in nodes do
			local index = row[node]

			if index ~= nil then
				local column = depthOf(node)
				bands[index] = bands[index] or {}
				bands[index][column] = bands[index][column] or {}
				table.insert(bands[index][column], node)
			end
		end

		local top = MARGIN
		for index = 0, rowCount - 1 do
			local band = bands[index]

			if band ~= nil then
				local tallest = 0

				-- Two nodes of one rule at the same distance from a source are
				-- rare but possible; they stack, and the row grows to fit.
				for column, members in band do
					local stacked = top

					for _, node in members do
						positions[node] = Vector2.new(MARGIN + column * (NODE_WIDTH + COLUMN_GAP), stacked)
						stacked += nodeHeight(node) + ROW_GAP
					end

					tallest = math.max(tallest, stacked - top)
				end

				top += tallest + ROW_GAP
			end
		end

		if outputNode ~= nil then
			positions[outputNode] =
				Vector2.new(MARGIN + depthOf(outputNode) * (NODE_WIDTH + COLUMN_GAP), MARGIN)
		end

		for _, node in nodes do
			local stored = node:GetAttribute(POSITION_ATTRIBUTE)
			if typeof(stored) == "Vector2" then
				positions[node] = stored
			end
		end
	end

	local function scheduleRebuild()
		rebuildQueued = true

		task.defer(function()
			if not rebuildQueued then
				return
			end

			-- A redraw in the middle of a drag would put the node back where it
			-- was before the grab, so it waits for the release.
			if drag ~= nil then
				return
			end

			rebuildQueued = false

			if widget.Enabled and root ~= nil then
				rebuild()
			end
		end)
	end

	-- Roblox draws no lines, so a wire is a thin frame turned to face along it.
	local function drawLine(line: Frame, from: Vector2, to: Vector2)
		local delta = to - from
		line.Size = UDim2.fromOffset(math.max(delta.Magnitude, 1), WIRE_THICKNESS)
		line.Position = UDim2.fromOffset((from.X + to.X) / 2, (from.Y + to.Y) / 2)
		line.Rotation = math.deg(math.atan2(delta.Y, delta.X))
	end

	local function layoutWires()
		for _, wire in wires do
			local from = outputPortCenter(wire.from)
			local to = inputPortCenter(wire.to, wire.index)

			drawLine(wire.line, from, to)
			wire.breaker.Position = UDim2.fromOffset((from.X + to.X) / 2, (from.Y + to.Y) / 2)
		end
	end

	local function paintSelection()
		for node, card in cards do
			local isSelected = node == selected

			card.frame.BorderColor3 = color(
				if isSelected then Enum.StudioStyleGuideColor.LinkText else Enum.StudioStyleGuideColor.Border
			)
			card.frame.BorderSizePixel = if isSelected then 2 else 1
			card.strip.BackgroundColor3 = color(
				Enum.StudioStyleGuideColor.Titlebar,
				if isSelected then Enum.StudioStyleGuideModifier.Selected else nil
			)
		end
	end

	local function showInspector()
		if selected == nil then
			inspector.show(function()
				return {}
			end, "Select a node on the canvas to edit its parameters.")
			return
		end

		local node = selected
		inspector.show(function()
			if node.Parent == nil then
				return {}
			end
			return { node }
		end, "This node is no longer in the graph.")
	end

	local function updateRibbon()
		local hasGraph = graph ~= nil and graph:IsDescendantOf(game)
		-- The Output registry is the graph's outlet rather than a node the
		-- author added, and a graph without one evaluates to nothing, so it is
		-- not offered for deletion.
		local hasNode = selected ~= nil and not isOutput(selected)

		for _, entry in ribbonButtons do
			local enabled = if entry.requires == "node" then hasNode else hasGraph
			local modifier = if enabled then nil else Enum.StudioStyleGuideModifier.Disabled

			entry.button.Active = enabled
			entry.button.AutoButtonColor = enabled
			entry.button.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Button, modifier)
			entry.button.TextColor3 = color(Enum.StudioStyleGuideColor.ButtonText, modifier)
		end
	end

	-- Everything a change of selection shows: the card it is on, the parameters
	-- in the panel, and which ribbon buttons a node being selected offers.
	local function select(node: Instance?)
		if node == selected then
			return
		end

		selected = node
		paintSelection()
		showInspector()
		updateRibbon()
	end

	-- Would connecting these feed a node back into itself? The evaluator follows
	-- wires without keeping track of where it has been, so a loop is not a
	-- strange graph, it is a hang.
	local function wouldCycle(source: Instance, target: Instance): boolean
		local seen = {}
		local pending = { source }

		while #pending > 0 do
			local node = table.remove(pending)

			if node == target then
				return true
			end

			if not seen[node] then
				seen[node] = true

				for _, port in inputPortsOf(node) do
					local value = if port.wire ~= nil then port.wire.Value else nil
					if value ~= nil and isNode(value) then
						table.insert(pending, value)
					end
				end
			end
		end

		return false
	end

	local function connect(source: Instance, target: Instance, port)
		if source == target or wouldCycle(source, target) then
			warn("ScatterGraph Graph view: wiring " .. source.Name .. " into " .. target.Name
				.. " would feed it back into itself, so the connection was not made.")
			return
		end

		recorded("Connect " .. source.Name .. " to " .. target.Name, function()
			if isOutput(target) then
				if port.isNew then
					local entry = Instance.new("ObjectValue")
					entry.Name = uniqueChildName(target, source.Name)
					entry:SetAttribute("NodeType", "OutputNode")
					entry.Value = source
					entry.Parent = target
				else
					port.wire.Value = source
				end
				return
			end

			local wire = port.wire or findWire(target, "Points")

			if wire == nil then
				wire = Instance.new("ObjectValue")
				wire.Name = "Points"
				wire:SetAttribute("NodeType", "Points")
				wire.Parent = target
			end

			wire.Value = source
		end)

		rebuild()
	end

	local function disconnect(target: Instance, wire: ObjectValue)
		recorded("Break connection", function()
			if isOutput(target) then
				-- An Output entry pointing at nothing is a rule that places
				-- nothing and warns about it every evaluation, so the entry goes
				-- rather than being emptied.
				wire.Parent = nil
			else
				-- Elsewhere the empty wire stays, which is how the Explorer and
				-- the Rules window keep showing the slot.
				wire.Value = nil
			end
		end)

		rebuild()
	end

	-- Which slot a dropped wire landed on. Ports are small, so a drop that
	-- misses is still taken by the node it landed on.
	local function portAt(point: Vector2)
		for node, ports in inputs do
			for index, port in ports do
				if (point - inputPortCenter(node, index)).Magnitude <= PORT_HIT then
					return node, port
				end
			end
		end

		for node, ports in inputs do
			local origin = positions[node]

			if origin ~= nil and #ports > 0 then
				local within = point.X >= origin.X
					and point.X <= origin.X + NODE_WIDTH
					and point.Y >= origin.Y
					and point.Y <= origin.Y + nodeHeight(node)

				if within then
					-- On the Output node the free slot is the one at the bottom;
					-- dropping on the body should add a rule, not quietly
					-- repoint one that is already there.
					return node, if isOutput(node) then ports[#ports] else ports[1]
				end
			end
		end

		return nil, nil
	end

	local function clearPendingWire()
		if pendingWire ~= nil then
			pendingWire:Destroy()
			pendingWire = nil
		end
	end

	local function endDrag()
		local finished = drag
		drag = nil

		clearPendingWire()

		if finished == nil then
			return
		end

		if finished.kind == "node" then
			if finished.moved and finished.node.Parent ~= nil then
				recorded("Move " .. finished.node.Name, function()
					finished.node:SetAttribute(POSITION_ATTRIBUTE, positions[finished.node])
				end)
			end
		elseif finished.kind == "wire" then
			local target, port = portAt(finished.point or Vector2.zero)
			if target ~= nil and port ~= nil and finished.node.Parent ~= nil then
				connect(finished.node, target, port)
			end
		end

		-- A change that arrived mid-drag was held back rather than snapping the
		-- node out from under the pointer. Nothing else will ask for it.
		if rebuildQueued then
			scheduleRebuild()
		end
	end

	local function onDragMove(input: InputObject)
		if drag == nil or input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end

		if drag.kind == "pan" then
			pan = viewPoint(input) - drag.grab
			applyView()
			return
		end

		if drag.kind == "node" then
			local node = drag.node
			local card = cards[node]

			if card == nil then
				return
			end

			positions[node] = canvasPoint(input) - drag.grab
			card.frame.Position = UDim2.fromOffset(positions[node].X, positions[node].Y)
			drag.moved = true
			layoutWires()
			return
		end

		-- A wire being trailed out of a port: the far end is wherever the
		-- pointer is until it is let go of.
		drag.point = canvasPoint(input)

		if pendingWire ~= nil then
			drawLine(pendingWire, outputPortCenter(drag.node), drag.point)
		end
	end

	-- Which button a drag answers to: the middle one slides the canvas, the left
	-- one carries nodes and wires. A drag therefore ignores the other button
	-- being let go of over it.
	local function endDragOnRelease(input: InputObject)
		if drag == nil then
			return
		end

		local button = if drag.kind == "pan"
			then Enum.UserInputType.MouseButton3
			else Enum.UserInputType.MouseButton1

		if input.UserInputType == button then
			endDrag()
		end
	end

	local function beginPan(input: InputObject)
		drag = { kind = "pan", grab = viewPoint(input) - pan }
	end

	-- Zooming keeps whatever is under the pointer under it, so the wheel reads
	-- as moving towards the node being looked at rather than towards wherever
	-- the graph's own origin has ended up.
	local function zoomAt(input: InputObject, notches: number)
		local at = viewPoint(input)
		local size = canvas.AbsoluteSize

		-- The parameter panel scrolls with the same wheel, and this handler is
		-- reached from anywhere in the window.
		if at.X < 0 or at.Y < 0 or at.X > size.X or at.Y > size.Y then
			return
		end

		local held = (at - pan) / zoom
		zoom = math.clamp(zoom * ZOOM_STEP ^ notches, ZOOM_MIN, ZOOM_MAX)
		pan = at - held * zoom
		applyView()

		-- A slide in progress holds where it was grabbed in view pixels, which
		-- the zoom has just moved the canvas out from under.
		if drag ~= nil and drag.kind == "pan" then
			drag.grab = at - pan
		end
	end

	local function onPointerInput(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			zoomAt(input, input.Position.Z)
		else
			onDragMove(input)
		end
	end

	-- A button swallows the input it is under, so a drag passing over one, a
	-- release on one, or a wheel turned over one never reaches the frame those
	-- are tracked on. Every button on the canvas therefore carries the same
	-- handlers -- and the ports are exactly where a wire is meant to be dropped.
	local function carryDrag(button: GuiObject)
		button.InputChanged:Connect(onPointerInput)
		button.InputEnded:Connect(endDragOnRelease)

		button.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton3 then
				beginPan(input)
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
				openContextMenu(input)
			end
		end)
	end

	local function beginWireDrag(node: Instance)
		clearPendingWire()

		local line = Instance.new("Frame")
		line.AnchorPoint = Vector2.new(0.5, 0.5)
		line.BackgroundColor3 = color(Enum.StudioStyleGuideColor.LinkText)
		line.BorderSizePixel = 0
		line.Size = UDim2.fromOffset(1, WIRE_THICKNESS)
		line.Position = UDim2.fromOffset(outputPortCenter(node).X, outputPortCenter(node).Y)
		line.ZIndex = 3
		line.Parent = wireLayer
		pendingWire = line

		drag = { kind = "wire", node = node, point = outputPortCenter(node) }
	end

	local function makePort(parent: GuiObject, center: Vector2, filled: boolean): TextButton
		local port = Instance.new("TextButton")
		port.AnchorPoint = Vector2.new(0.5, 0.5)
		port.Position = UDim2.fromOffset(center.X, center.Y)
		port.Size = UDim2.fromOffset(PORT_SIZE, PORT_SIZE)
		port.BackgroundColor3 = color(
			if filled then Enum.StudioStyleGuideColor.LinkText else Enum.StudioStyleGuideColor.InputFieldBackground
		)
		port.BorderColor3 = color(Enum.StudioStyleGuideColor.Border)
		port.Text = ""
		port.AutoButtonColor = false
		port.ZIndex = 3
		port.Parent = parent

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = port

		carryDrag(port)
		return port
	end

	local function makeCard(node: Instance)
		local ports = inputs[node]
		local origin = positions[node] or Vector2.zero

		-- A button rather than a frame, for the same reason the ports are: only a
		-- button is handed the press it is under. A frame here is passed over in
		-- favour of the canvas background behind it, which reads the press as a
		-- click on empty canvas and clears the selection rather than making it.
		local frame = Instance.new("TextButton")
		frame.Position = UDim2.fromOffset(origin.X, origin.Y)
		frame.Size = UDim2.fromOffset(NODE_WIDTH, nodeHeight(node))
		frame.BackgroundColor3 = color(Enum.StudioStyleGuideColor.MainBackground)
		frame.BorderColor3 = color(Enum.StudioStyleGuideColor.Border)
		frame.Text = ""
		frame.AutoButtonColor = false
		frame.Parent = nodeLayer

		local strip = Instance.new("Frame")
		strip.Size = UDim2.new(1, 0, 0, TITLE_HEIGHT)
		strip.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Titlebar)
		strip.BorderSizePixel = 0
		strip.Parent = frame

		local title = makeLabel(node.Name, color(Enum.StudioStyleGuideColor.BrightText), true)
		title.Size = UDim2.new(1, -PADDING * 2, 1, 0)
		title.Position = UDim2.fromOffset(PADDING, 0)
		title.Parent = strip

		local kind = makeLabel(
			tostring(node:GetAttribute("NodeType")),
			color(Enum.StudioStyleGuideColor.DimmedText),
			false
		)
		kind.Size = UDim2.new(1, -PADDING * 2, 0, PORT_ROW)
		kind.Position = UDim2.fromOffset(PADDING, TITLE_HEIGHT)
		kind.Parent = frame

		local rule = ruleOf(node)
		if rule ~= nil then
			local ruleLabel = makeLabel(rule, color(Enum.StudioStyleGuideColor.SubText), false)
			ruleLabel.Size = UDim2.new(1, -PADDING * 2, 0, PORT_ROW)
			ruleLabel.Position = UDim2.fromOffset(PADDING, TITLE_HEIGHT + PORT_ROW)
			ruleLabel.Parent = frame
		end

		cards[node] = { frame = frame, strip = strip }

		if not isOutput(node) then
			local port = makePort(frame, Vector2.new(NODE_WIDTH, TITLE_HEIGHT + PORT_ROW / 2), true)
			overlay.watchForTooltip(
				port,
				"The points this node produces. Drag from here onto another node to feed it."
			)

			port.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					select(node)
					beginWireDrag(node)
				end
			end)
		end

		for index, entry in ports do
			local top = headerHeight(node) + (index - 1) * PORT_ROW

			local label = makeLabel(
				entry.name,
				color(
					if entry.isNew then Enum.StudioStyleGuideColor.DimmedText else Enum.StudioStyleGuideColor.MainText
				),
				false
			)
			label.Size = UDim2.new(1, -PADDING * 2, 0, PORT_ROW)
			label.Position = UDim2.fromOffset(PADDING, top)
			label.Parent = frame

			local connected = entry.wire ~= nil and entry.wire.Value ~= nil
			local port = makePort(frame, Vector2.new(0, top + PORT_ROW / 2), connected)

			overlay.watchForTooltip(
				port,
				if entry.isNew
					then "An empty slot. Drop a wire here to register another rule with this Output."
					else "What this node reads. Drop a wire from another node's right-hand port here to change it."
			)
		end

		-- The title strip and the labels are drawn over the card but take no
		-- input of their own, so a press anywhere on it arrives here; the ports
		-- are buttons and take theirs first, which is what keeps a grab at a
		-- port from also dragging the node it belongs to.
		frame.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
				return
			end

			select(node)
			drag = { kind = "node", node = node, grab = canvasPoint(input) - (positions[node] or Vector2.zero) }
		end)

		-- Being a button, the card takes the moves and the wheel over it as well
		-- as the press, so it carries the same handlers every other button on
		-- the canvas does: without them a node dragged under its own pointer
		-- would stop moving.
		carryDrag(frame)

		overlay.watchForTooltip(strip, "Drag to move this node. Its parameters are on the right.")
	end

	local function makeWireBetween(source: Instance, target: Instance, index: number, port)
		local line = Instance.new("Frame")
		line.AnchorPoint = Vector2.new(0.5, 0.5)
		line.BackgroundColor3 = color(Enum.StudioStyleGuideColor.DimmedText)
		line.BorderSizePixel = 0
		line.Parent = wireLayer

		local breaker = Instance.new("TextButton")
		breaker.AnchorPoint = Vector2.new(0.5, 0.5)
		breaker.Size = UDim2.fromOffset(BREAK_SIZE, BREAK_SIZE)
		breaker.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Button)
		breaker.BorderColor3 = color(Enum.StudioStyleGuideColor.Border)
		breaker.Text = ""
		breaker.ZIndex = 2
		breaker.Parent = wireLayer

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = breaker

		breaker.Activated:Connect(function()
			disconnect(target, port.wire)
		end)

		carryDrag(breaker)
		overlay.watchForTooltip(breaker, "Click to break this connection.")

		table.insert(wires, { line = line, breaker = breaker, from = source, to = target, index = index })
	end

	local function watchGraph(nodes: { Instance })
		-- Nodes and wires can come and go from the Rules window, the Explorer,
		-- or an undo, and any of those is a different picture.
		table.insert(graphConnections, graph.DescendantAdded:Connect(scheduleRebuild))
		table.insert(graphConnections, graph.DescendantRemoving:Connect(scheduleRebuild))
		table.insert(graphConnections, graph.AncestryChanged:Connect(scheduleRebuild))
		table.insert(graphConnections, graph:GetPropertyChangedSignal("Name"):Connect(scheduleRebuild))

		for _, node in nodes do
			-- The canvas shows a node's name and where it sits, and draws its
			-- wires, so it follows all three. Either window can be the one that
			-- changed them, and so can an undo.
			table.insert(graphConnections, node:GetPropertyChangedSignal("Name"):Connect(scheduleRebuild))
			table.insert(graphConnections, node.AttributeChanged:Connect(scheduleRebuild))

			for _, child in node:GetChildren() do
				if child:IsA("ObjectValue") then
					table.insert(graphConnections, child.Changed:Connect(scheduleRebuild))
				end
			end
		end
	end

	local function showMessage(text: string)
		if message ~= nil then
			message:Destroy()
			message = nil
		end

		if text == "" then
			return
		end

		local label = makeLabel(text, color(Enum.StudioStyleGuideColor.DimmedText), false)
		label.Size = UDim2.new(1, -PADDING * 2, 0, HEADER_HEIGHT)
		label.Position = UDim2.fromOffset(PADDING, PADDING)
		label.TextTruncate = Enum.TextTruncate.None
		label.TextWrapped = true
		label.ZIndex = 4
		label.Parent = canvas
		message = label
	end

	rebuild = function()
		if root == nil then
			return
		end

		rebuildQueued = false

		for _, connection in graphConnections do
			connection:Disconnect()
		end
		table.clear(graphConnections)

		wireLayer:ClearAllChildren()
		nodeLayer:ClearAllChildren()
		table.clear(wires)
		table.clear(cards)
		pendingWire = nil
		showMessage("")

		if graph == nil or not graph:IsDescendantOf(game) then
			widget.Title = "ScatterGraph Graph View"
			selected = nil
			inputs = {}
			showMessage("This graph is no longer in the place.")
			showInspector()
			updateRibbon()
			return
		end

		widget.Title = "ScatterGraph Graph View - " .. graph.Name

		local nodes = collectNodes(graph)

		inputs = {}
		for _, node in nodes do
			inputs[node] = inputPortsOf(node)
		end

		if selected ~= nil and inputs[selected] == nil then
			selected = nil
		end

		computeLayout(nodes)

		for _, node in nodes do
			makeCard(node)
		end

		for _, target in nodes do
			for index, port in inputs[target] do
				local source = if port.wire ~= nil then port.wire.Value else nil
				-- A wire pointing outside this graph has nothing to draw to.
				if source ~= nil and inputs[source] ~= nil then
					makeWireBetween(source, target, index, port)
				end
			end
		end

		layoutWires()
		paintSelection()
		watchGraph(nodes)
		showInspector()
		updateRibbon()

		if #nodes == 0 then
			showMessage("This graph has no nodes yet. Add one from the ribbon above.")
		end
	end

	-- Slides the canvas so the top-left node is in view, which is the only way
	-- back if the pan has wandered off into empty space.
	local function frameAll()
		local corner = nil

		for _, position in positions do
			corner = if corner == nil
				then position
				else Vector2.new(math.min(corner.X, position.X), math.min(corner.Y, position.Y))
		end

		pan = if corner == nil then Vector2.zero else Vector2.new(MARGIN, MARGIN) - corner * zoom
		applyView()
	end

	-- Where a node goes when nothing pointed at a place for it: the middle of
	-- what is on screen, rather than the origin of a canvas that may have been
	-- panned away from.
	local function viewMiddle(): Vector2
		return (canvas.AbsoluteSize / 2 - pan) / zoom - Vector2.new(NODE_WIDTH / 2, TITLE_HEIGHT)
	end

	-- `at` is the corner the new node's card is laid out from, in graph pixels.
	local function addNode(template, at: Vector2)
		if graph == nil or not graph:IsDescendantOf(game) then
			return
		end

		local created = nil

		local made = recorded("Add " .. template.label .. " node", function()
			local node = Instance.new("Model")
			node.Name = uniqueChildName(graph, template.name)

			for attribute, value in template.attributes do
				node:SetAttribute(attribute, value)
			end

			node:SetAttribute("NodeType", template.nodeType)
			node:SetAttribute(POSITION_ATTRIBUTE, at)

			node.Parent = graph
			created = node
		end)

		if made and created ~= nil then
			selected = created
			rebuild()
		end
	end

	-- Every node type the window can add, as menu items that put the node at a
	-- given place. Shared by the ribbon's Add Node button and the right-click
	-- menu, which differ only in where that place comes from.
	local function nodeTemplateItems(at: Vector2)
		local items = {}

		for _, template in NODE_TEMPLATES do
			table.insert(items, {
				text = template.label,
				activate = function()
					addNode(template, at)
				end,
			})
		end

		return items
	end

	openContextMenu = function(input: InputObject)
		-- Mid-drag the pointer is already saying something else, and a menu over
		-- a graph that is not there has nothing to add a node to.
		if drag ~= nil or graph == nil or not graph:IsDescendantOf(game) then
			return
		end

		overlay.openMenuAt(windowPoint(input), nodeTemplateItems(canvasPoint(input)))
	end

	local function deleteSelected()
		local node = selected

		if node == nil or graph == nil or node.Parent == nil or isOutput(node) then
			return
		end

		recorded("Delete " .. node.Name, function()
			-- Wires left pointing at a node that is gone are not harmless: the
			-- evaluator warns about an empty one and then carries on into it.
			for _, other in collectNodes(graph) do
				for _, port in inputPortsOf(other) do
					if port.wire ~= nil and port.wire.Value == node then
						if isOutput(other) then
							port.wire.Parent = nil
						else
							port.wire.Value = nil
						end
					end
				end
			end

			node.Parent = nil
		end)

		selected = nil
		rebuild()
	end

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

		button.Activated:Connect(spec.activate)
		overlay.watchForTooltip(button, spec.tooltip)

		table.insert(ribbonButtons, { button = button, requires = spec.requires })
		return button
	end

	buildInterface = function()
		if root ~= nil then
			root:Destroy()
		end

		local rootFrame = Instance.new("Frame")
		root = rootFrame
		rootFrame.Size = UDim2.fromScale(1, 1)
		rootFrame.BackgroundColor3 = color(Enum.StudioStyleGuideColor.MainBackground)
		rootFrame.BorderSizePixel = 0
		rootFrame.Parent = widget

		overlay.attach(rootFrame)

		local ribbon = Instance.new("Frame")
		ribbon.Size = UDim2.new(1, 0, 0, RIBBON_HEIGHT)
		ribbon.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Titlebar)
		ribbon.BorderSizePixel = 0
		ribbon.Parent = rootFrame

		local ribbonLayout = Instance.new("UIListLayout")
		ribbonLayout.FillDirection = Enum.FillDirection.Horizontal
		ribbonLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		ribbonLayout.SortOrder = Enum.SortOrder.LayoutOrder
		ribbonLayout.Padding = UDim.new(0, 4)
		ribbonLayout.Parent = ribbon

		local ribbonPadding = Instance.new("UIPadding")
		ribbonPadding.PaddingLeft = UDim.new(0, PADDING)
		ribbonPadding.Parent = ribbon

		table.clear(ribbonButtons)

		local addButton
		addButton = addRibbonButton({
			icon = "\u{2795}",
			label = "Add Node",
			tooltip = "Adds a node to the graph, unwired, in the middle of the view. Right-click the canvas to "
				.. "add one where the pointer is instead. Drag from its right-hand port to feed something with it.",
			requires = "graph",
			activate = function()
				overlay.openDropdown(addButton, nodeTemplateItems(viewMiddle()))
			end,
		})
		addButton.Parent = ribbon

		addRibbonButton({
			icon = "\u{274C}",
			label = "Delete Node",
			tooltip = "Deletes the selected node and empties the wires that fed from it. The nodes feeding it "
				.. "stay where they are.",
			requires = "node",
			activate = deleteSelected,
		}).Parent = ribbon

		addRibbonButton({
			icon = "\u{1F50D}",
			label = "Frame All",
			tooltip = "Slides the canvas back to the nodes, for when panning has left them off screen.",
			requires = "graph",
			activate = frameAll,
		}).Parent = ribbon

		local edge = Instance.new("Frame")
		edge.Position = UDim2.fromOffset(0, RIBBON_HEIGHT)
		edge.Size = UDim2.new(1, 0, 0, 1)
		edge.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Border)
		edge.BorderSizePixel = 0
		edge.Parent = rootFrame

		local paneTop = RIBBON_HEIGHT + 1

		canvas = Instance.new("Frame")
		canvas.Position = UDim2.fromOffset(0, paneTop)
		canvas.Size = UDim2.new(1 - PARAM_COLUMN, 0, 1, -paneTop)
		canvas.BackgroundColor3 = color(Enum.StudioStyleGuideColor.ViewPortBackground)
		canvas.BorderSizePixel = 0
		-- Everything on the canvas is positioned in graph pixels and may sit
		-- well outside the visible corner of it.
		canvas.ClipsDescendants = true
		canvas.Parent = rootFrame

		-- Behind the nodes, and a button so that a press on empty canvas is
		-- something this can hear rather than something the widget swallows.
		local background = Instance.new("TextButton")
		background.Size = UDim2.fromScale(1, 1)
		background.BackgroundTransparency = 1
		background.Text = ""
		background.AutoButtonColor = false
		background.ZIndex = 0
		background.Parent = canvas

		background.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				select(nil)
			end
		end)

		-- Sliding the canvas and turning the wheel over it come from here, since
		-- the background is what a press on empty canvas, or on a node, lands on.
		carryDrag(background)

		content = Instance.new("Frame")
		content.Size = UDim2.fromScale(1, 1)
		content.BackgroundTransparency = 1
		content.Parent = canvas

		-- The zoom, applied once here rather than by every card and wire working
		-- it into the graph pixels they are placed in.
		contentScale = Instance.new("UIScale")
		contentScale.Parent = content

		wireLayer = Instance.new("Frame")
		wireLayer.Size = UDim2.fromScale(1, 1)
		wireLayer.BackgroundTransparency = 1
		wireLayer.ZIndex = 1
		wireLayer.Parent = content

		nodeLayer = Instance.new("Frame")
		nodeLayer.Size = UDim2.fromScale(1, 1)
		nodeLayer.BackgroundTransparency = 1
		nodeLayer.ZIndex = 2
		nodeLayer.Parent = content

		applyView()

		local divider = Instance.new("Frame")
		divider.Position = UDim2.new(1 - PARAM_COLUMN, 0, 0, paneTop)
		divider.Size = UDim2.new(0, 1, 1, -paneTop)
		divider.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Border)
		divider.BorderSizePixel = 0
		divider.Parent = rootFrame

		local pane = Instance.new("Frame")
		pane.Position = UDim2.new(1 - PARAM_COLUMN, 1, 0, paneTop)
		pane.Size = UDim2.new(PARAM_COLUMN, -1, 1, -paneTop)
		pane.BackgroundTransparency = 1
		pane.Parent = rootFrame

		local header = makeLabel("Parameters", color(Enum.StudioStyleGuideColor.SubText), true)
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

		inspector.setList(scroll)

		-- Tracked on the root rather than the canvas so a drag that wanders off
		-- the canvas keeps working until the mouse comes back or is released.
		rootFrame.InputChanged:Connect(onPointerInput)
		rootFrame.InputEnded:Connect(endDragOnRelease)
	end

	-- An edit made in the panel can rewire the graph, which is a different
	-- drawing of it.
	inspector.onChanged = scheduleRebuild

	widget:GetPropertyChangedSignal("Enabled"):Connect(function()
		if widget.Enabled then
			if root == nil then
				buildInterface()
			end
			rebuild()
		end
	end)

	-- Backstops for a release this window never sees, because it happened
	-- outside the widget or over something that swallowed it.
	UserInputService.InputEnded:Connect(endDragOnRelease)

	widget.WindowFocusReleased:Connect(endDrag)

	settings().Studio.ThemeChanged:Connect(function()
		if root ~= nil then
			root:Destroy()
			root = nil
		end

		if widget.Enabled then
			buildInterface()
			rebuild()
		end
	end)

	function self.show(newGraph: Instance)
		local changed = newGraph ~= graph

		graph = newGraph

		if changed then
			selected = nil
		end

		widget.Enabled = true

		if root == nil then
			buildInterface()
		end

		rebuild()

		-- A graph opened for the first time is framed; one reopened keeps the
		-- pan the author left it at.
		if changed then
			frameAll()
		end
	end

	return self
end

-- Opens the given graph, reusing the window if it is already up.
function GraphView.open(pluginRef: Plugin, graph: Instance)
	if view == nil then
		view = create(pluginRef)
	end

	view.show(graph)
end

return GraphView
