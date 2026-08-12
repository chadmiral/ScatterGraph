--[[
	GraphView

	The graph as a graph: every node of one ScatterGraph on a canvas, wired to
	the nodes it feeds, with the parameters of whichever nodes are selected in a
	panel down the right-hand side.

	The Spreadsheet view shows a rule as a flat list, which suits reading and
	tuning one rule at a time. This shows the shape of the whole thing, which is
	what rearranging it needs. Both edit the same instances -- a node is a Model
	carrying a NodeType attribute, a connection is a child ObjectValue pointing
	at the node upstream of it -- so either window can be left open while the
	other is used, and each picks up the other's edits.

	Its toolbar button says to show a graph but not which one, so the Studio
	selection says: a graph, a node inside one or a volume that uses one all open
	that graph, and a selection pointing at none of those reopens whatever the
	window was last left showing.

	The canvas is slid with the middle mouse button and zoomed with the wheel,
	which leaves the left button free for the graph itself: picking nodes,
	carrying them, and trailing a wire out of a port. Dragging it over empty
	canvas boxes in everything the box touches, and shift adds to what is already
	picked rather than starting again. The right button opens what can be added as
	a menu -- the whole rules the Spreadsheet view offers, and the single nodes to
	build a chain by hand -- and adds the one chosen where the menu was opened.

	A reroute is drawn as a dot the size of a port rather than as a card, since a
	bend in a wire should look like one and it has nothing else to show. Its ends
	are the same point, so the wire in and the wire out meet there. Dragging the dot
	moves it; pointing at it grows the output port a card would have on its edge,
	which is what a wire is then pulled out of. That gesture is geometry rather than
	a held key because the keyboard reaches this window through a focused text box
	(see grabKeyboard), which never reports a modifier being held.

	More than one node can be picked, so everything that acts on a selection acts
	on all of it: the panel shows each picked node under its own heading, a drag
	carries the whole handful at once, and Delete Node deletes all of them as a
	single undo.

	Evaluate Graph runs what is on screen and nothing else, so a graph can be
	tuned and placed without disturbing what the other graphs in the place have
	put down. The run itself belongs to the plugin script, which owns every other
	pass over the place; this window only says which graph and when.

	A node that measures something over the ground grows a strip along the bottom
	of its card with a thumbnail of what it last made in it (see TexturePreview),
	which is the one thing on the canvas that comes from a run rather than from
	the graph. There is nothing to draw until the graph has been run, so the strip
	is not there at all until then and the card is its old height.

	Where the nodes sit is the one thing on the canvas that is not already in
	the graph. A node dragged to a new place keeps it in a GraphPosition
	attribute; a node that has never been dragged is laid out in columns by how
	far it is from a source, which is a readable starting arrangement and costs
	nothing to throw away. Rewiring the graph would work those columns out
	again, so an edit to the wiring first writes down where the laid-out nodes
	are: an author who cuts one wire asked for that wire to go, not for the rest
	of the graph to rearrange itself around the gap.

	Every position lands on a ten pixel grid, shown as dots twenty pixels apart
	that double or halve as the zoom would otherwise crowd them or spread them
	out. They are one repeating image rather than a frame apiece, since at that
	spacing a frame apiece would be thousands of them. A dot always falls on a
	multiple of ten graph pixels, whatever the zoom, so a node sits on one
	rather than near one -- which is what the zoom moving between whole tenths
	is in aid of.
]]

local AssetService = game:GetService("AssetService")
local UserInputService = game:GetService("UserInputService")
local Selection = game:GetService("Selection")

local DataTypes = require(script.Parent:WaitForChild("DataTypes"))
local GraphUi = require(script.Parent:WaitForChild("GraphUi"))
local Graphs = require(script.Parent:WaitForChild("Graphs"))
local NodeInspector = require(script.Parent:WaitForChild("NodeInspector"))
local RuleTemplates = require(script.Parent:WaitForChild("RuleTemplates"))
local AttributeSchema = require(script.Parent:WaitForChild("AttributeSchema"))
local TexturePreview = require(script.Parent:WaitForChild("TexturePreview"))

local GraphView = {}

local PADDING = GraphUi.PADDING
local HEADER_HEIGHT = GraphUi.HEADER_HEIGHT
local RIBBON_HEIGHT = GraphUi.RIBBON_HEIGHT
local BUTTON_HEIGHT = GraphUi.BUTTON_HEIGHT
-- Where the canvas and panel begin: below both ribbon rows and the hairline
-- under each. The divider drag reads this the same way the interface builds it.
local PANE_TOP = (RIBBON_HEIGHT + 1) * 2

-- What the hidden keyboard catcher is kept holding between keystrokes. A focused
-- TextBox routes Delete, Backspace and a letter into editing its text rather
-- than into InputBegan, so the shortcuts are read from what the key does to this
-- seed instead: a delete key shortens it, a letter lengthens it. Several
-- characters with the caret among them so a delete key finds one either side of
-- it to remove, whichever direction the key works in.
local KEY_CATCHER_SEED = "...."
local KEY_CATCHER_CARET = 3

local color = GraphUi.color
local makeLabel = GraphUi.makeLabel
local recorded = GraphUi.recorded
local findWire = GraphUi.findWire

-- Canvas geometry, in canvas pixels.
local NODE_WIDTH = 176
local TITLE_HEIGHT = 24
local PORT_ROW = 20
local PORT_SIZE = 10
-- A port is drawn in the colour of the type it carries, filled when something is
-- wired to it and a ring of that colour around a hole when nothing is. This is
-- how thick that ring is: enough of the type colour left to read at a glance,
-- enough of a hole left to tell a full port from an empty one.
local PORT_RING = 2
-- How close a dropped wire has to land to count as hitting a port. Larger than
-- the port itself, because the port is small and the gesture is not precise.
local PORT_HIT = 14
local WIRE_THICKNESS = 2
local BREAK_SIZE = 10
-- A reroute is drawn as one dot rather than a card. It holds no parameters and
-- does nothing to what passes through it, so a card's worth of canvas would say
-- nothing the dot does not, and a wire bent around the graph should look like a
-- bent wire. Twice a port, because unlike a port it is also the handle the thing
-- is dragged by, and a round number of grid snaps so it lands on the grid square.
local REROUTE_SIZE = 20
-- The strip along the bottom of a texture node's card that its last evaluated
-- texture is drawn in. Tall enough to read a pattern off and no taller: a card
-- is a node, not a picture, and every card in a column grows by this much the
-- moment the graph is run. The picture is fitted inside it and centred, so the
-- ground keeps its shape rather than being stretched to a fixed rectangle.
local PREVIEW_HEIGHT = 88
local COLUMN_GAP = 72
local ROW_GAP = 24
local MARGIN = 40
-- How far the wheel can zoom: far enough out to see a large graph whole, far
-- enough in that a node's text is still worth reading. Zoom runs continuously
-- between the two rather than snapping to fixed stops, so a turn scales smoothly
-- and a high-resolution wheel's fractional notches are not rounded away and lost.
-- Each notch multiplies the zoom by the step, which is what makes one turn feel
-- like the same amount of zoom whatever the canvas is already at. The grid tiling
-- rounds to whole pixels at any zoom (see refreshGrid), so a fractional zoom no
-- longer needs to be avoided.
local ZOOM_MIN = 0.1
local ZOOM_MAX = 2.5
local ZOOM_DEFAULT = 1
local ZOOM_WHEEL_STEP = 1.075

-- A title bar is coloured by what its node does, so a chain reads at a glance:
-- green makes points, teal derives more points from them, brown puts them on the
-- ground, olive measures a field over it, rust turns something into a texture that
-- thins a scatter out, violet holds a value the rest read, blue places geometry
-- and a paler blue moves it elsewhere in the hierarchy, a flat grey-green joins
-- several chains into one, and grey is the outlet the graph ends at. Both merges
-- are the one colour: what a title says is what the node does to what it is
-- given, and they do the same thing -- which of the two kinds of thing it is
-- being done to is what the ports are coloured for. These are fixed rather than theme
-- colours because they say which node type this is, not which part of the window
-- it is. A reroute is not here: it has no title to colour, being drawn as a dot in
-- the colour of whatever it is carrying.
local TITLE_COLORS = {
	ScatterPoints = Color3.fromRGB(62, 108, 74),
	ScatterPointsAroundPoints = Color3.fromRGB(86, 142, 154),
	SnapPointsToTerrain = Color3.fromRGB(122, 88, 50),
	MaterialSDF2D = Color3.fromRGB(124, 110, 46),
	SDFThreshold2D = Color3.fromRGB(140, 84, 62),
	NoiseTexture2D = Color3.fromRGB(140, 84, 62),
	Number = Color3.fromRGB(104, 78, 148),
	PlaceGeometryOnPoints = Color3.fromRGB(78, 84, 134),
	ParentInstancesTo = Color3.fromRGB(70, 104, 140),
	MergePoints = Color3.fromRGB(72, 100, 96),
	MergeInstances = Color3.fromRGB(72, 100, 96),
	Output = Color3.fromRGB(84, 84, 92),
}
-- A node type this window has never heard of still gets a card.
local TITLE_FALLBACK = Color3.fromRGB(96, 82, 104)
-- Written on the coloured strips rather than on the window, so it does not
-- follow the theme's text colour onto a background that no longer follows it.
local TITLE_TEXT = Color3.fromRGB(238, 238, 238)
-- How much lighter the strip of the selected node is: enough to pick it out of a
-- column, not so much that the type colour stops being the type colour.
local TITLE_SELECTED_LIFT = 0.3
-- Draws the edge of a card against both the canvas behind it and the card
-- itself, in either Studio theme, which the theme's own border colour does not.
local NODE_BORDER = Color3.fromRGB(158, 158, 158)
-- A node missing something it needs to evaluate -- a required attribute, or a
-- PlaceGeometryOnPoints with neither an Asset nor a GeometryAssetID -- is drawn
-- with this border and a badge of it in the corner. Shared with the parameter
-- panel, which outlines the offending edit box in the same red.
local ERROR_COLOR = GraphUi.ERROR_COLOR
-- The warning badge over the top-right corner of an incomplete node.
local BADGE_SIZE = 16
-- Faint enough to read the nodes through the box being dragged over them.
local MARQUEE_FILL = 0.85

-- A Note is not a node the graph evaluates -- it has no ports and nothing wires
-- to it, so the runtime never reaches it -- but a place to pin a comment on the
-- canvas. Drawn as a post-it: a yellow card with a darker gummed strip along the
-- top to drag it by, and dark ink that reads on the yellow whatever the theme.
local NOTE_BACKGROUND = Color3.fromRGB(245, 224, 115)
local NOTE_HEADER = Color3.fromRGB(232, 208, 84)
local NOTE_TEXT = Color3.fromRGB(64, 54, 18)
-- A fixed card, tall enough for a few lines; the body scrolls past that rather
-- than the card growing, so a long note does not shove the layout around.
local NOTE_HEIGHT = 120

-- The canvas grid. Positions round to the snap, which is what makes a graph tidy
-- itself; the dots are drawn twice as far apart, since one at every snap is
-- denser than it needs to be to read the spacing off.
local GRID_SNAP = 10
local GRID_SPACING = 20
local GRID_DOT = Color3.fromRGB(80, 80, 80)
-- The band the dots are kept within on screen, by doubling the spacing when the
-- zoom crowds them and halving it when the zoom spreads them out. Halving stops
-- at the snap, so every dot stays somewhere a node can actually land. The band is
-- more than twice as wide as it is deep, so the two never fight over a zoom.
local GRID_MIN_SCREEN = 12
local GRID_MAX_SCREEN = 44
-- Share of the window the parameter panel takes to begin with; the divider
-- between it and the canvas can be dragged, so this is only the starting split.
local PARAM_COLUMN = 0.32
-- How far that drag can go, as the panel's share of the window: enough either
-- way that neither the canvas nor the panel can be squeezed shut.
local PARAM_COLUMN_MIN = 0.15
local PARAM_COLUMN_MAX = 0.6

-- Where a node remembers having been dragged to. Hidden from the parameter
-- panel by AttributeSchema, since it belongs to this canvas rather than to the
-- graph the runtime evaluates.
local POSITION_ATTRIBUTE = "GraphPosition"

-- The single nodes the add menu offers, below the whole rules from RuleTemplates.
-- These values are a starting point for a node built by hand; a template tunes
-- the same attributes further for the chain each one belongs to.
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
		-- Several chains of points read as one. Its slots are made as they are
		-- wired, so it starts with nothing but the empty one to drop a wire on.
		label = "Merge Points",
		name = "MergePoints",
		nodeType = "MergePoints",
		attributes = {},
	},
	{
		label = "Material SDF 2D",
		name = "MaterialSDF2D",
		nodeType = "MaterialSDF2D",
		attributes = { Materials = "Water", VoxelSize = 4 },
	},
	{
		label = "SDF Threshold",
		name = "SDFThreshold2D",
		nodeType = "SDFThreshold2D",
		attributes = {},
	},
	{
		label = "Noise Texture 2D",
		name = "NoiseTexture2D",
		nodeType = "NoiseTexture2D",
		attributes = { Scale = 64, Phase = 0, VoxelSize = 4 },
	},
	{
		label = "Number",
		name = "Number",
		nodeType = "Number",
		attributes = { Value = 0 },
	},
	{
		-- Named PlaceAssetOnPoints while its NodeType is PlaceGeometryOnPoints,
		-- which is how every existing graph has it.
		label = "Place Asset",
		name = "PlaceAssetOnPoints",
		nodeType = "PlaceGeometryOnPoints",
		attributes = { ScaleRange = Vector2.new(0.9, 1.1), RotationType = "UpAxis" },
	},
	{
		-- Puts what the rule placed somewhere else in the hierarchy and hands it
		-- on. Where is a reference into the place, set from the parameter panel
		-- rather than here: an attribute cannot hold one, so the row makes the
		-- ObjectValue the first time it is set.
		label = "Parent Instances To",
		name = "ParentInstancesTo",
		nodeType = "ParentInstancesTo",
		attributes = {},
	},
	{
		-- What several terminals placed, read as one, so a rule can end in more
		-- than one kind of geometry.
		label = "Merge Instances",
		name = "MergeInstances",
		nodeType = "MergeInstances",
		attributes = {},
	},
	{
		-- A bend in a wire, for the canvas rather than the evaluation: it hands
		-- on whatever reaches it, and takes the type of that when something does.
		-- Drawn as a dot rather than a card, since that is all it is.
		label = "Reroute",
		name = "Reroute",
		nodeType = "Reroute",
		attributes = {},
	},
	{
		-- Not a working node: a post-it to write on. The runtime never sees it,
		-- since nothing wires to it. Text is the note itself.
		label = "Note",
		name = "Note",
		nodeType = "Note",
		attributes = { Text = "" },
	},
}

-- Wires carry a NodeType attribute of their own, so being one is not enough.
local function isNode(instance: Instance): boolean
	return not instance:IsA("ObjectValue") and instance:GetAttribute("NodeType") ~= nil
end

local function isOutput(node: Instance): boolean
	return node:GetAttribute("NodeType") == "Output"
end

-- A comment card rather than a working node: no ports, no wires, nothing to
-- evaluate. Drawn and dragged like any other card, but its whole body is an
-- editable note instead of a strip of parameters.
local function isNote(node: Instance): boolean
	return node:GetAttribute("NodeType") == "Note"
end

-- A bend in a wire rather than a step in the work: drawn as a dot the size of a
-- port, where the wire in and the wire out meet at the same point.
local function isReroute(node: Instance): boolean
	return node:GetAttribute("NodeType") == "Reroute"
end

local function snapToGrid(point: Vector2): Vector2
	return Vector2.new(
		math.round(point.X / GRID_SNAP) * GRID_SNAP,
		math.round(point.Y / GRID_SNAP) * GRID_SNAP
	)
end

-- How far apart to draw the dots at a given zoom, in graph pixels: the spacing
-- doubled until they are not on top of each other, then halved while they are
-- further apart than they need to be. Every step is a multiple or a factor of the
-- snap, so a dot always marks somewhere a node can land.
local function gridSpacingFor(zoom: number): number
	local spacing = GRID_SPACING

	while spacing * zoom < GRID_MIN_SCREEN do
		spacing *= 2
	end

	while spacing > GRID_SNAP and spacing * zoom > GRID_MAX_SCREEN do
		spacing /= 2
	end

	return spacing
end

-- One tile of the grid: a single dot in the corner of an otherwise empty square,
-- which an ImageLabel repeats across the canvas. Drawn here rather than uploaded,
-- so the plugin does not depend on an asset that could be moderated away.
--
-- The square is as many pixels across as the tile is drawn on screen, which is
-- what keeps the dot a single pixel however far the canvas is zoomed. The zoom
-- moves between a handful of sizes, so each is kept once it is made.
local gridTiles: { [number]: Content } = {}
local gridTileImages = {}
local gridTilesFailed = false

local function gridTile(size: number): Content?
	if gridTilesFailed then
		return nil
	end

	if gridTiles[size] ~= nil then
		return gridTiles[size]
	end

	local ok, err = pcall(function()
		local image = AssetService:CreateEditableImage({ Size = Vector2.new(size, size) })

		-- Every byte starts at zero, which is a transparent square; the dot is
		-- the one pixel written over it.
		local pixels = buffer.create(size * size * 4)
		buffer.writeu8(pixels, 0, math.round(GRID_DOT.R * 255))
		buffer.writeu8(pixels, 1, math.round(GRID_DOT.G * 255))
		buffer.writeu8(pixels, 2, math.round(GRID_DOT.B * 255))
		buffer.writeu8(pixels, 3, 255)

		image:WritePixelsBuffer(Vector2.zero, image.Size, pixels)

		-- Held onto beyond the Content, which is a handle rather than a copy.
		gridTileImages[size] = image
		gridTiles[size] = Content.fromObject(image)
	end)

	if not ok then
		-- The snapping is the half that matters; without the tiles the canvas
		-- simply has no dots on it.
		gridTilesFailed = true
		warn("ScatterGraph: no canvas grid -- " .. tostring(err))
	end

	return gridTiles[size]
end

-- A distance in studs, for a card to say out loud. Whole studs, because a
-- picture measured in cells four studs across cannot mean anything finer -- and
-- in the short form past ten thousand, which is not a distance anything in a
-- place is at but is exactly what a field for a material the place does not have
-- reads everywhere, and reads better as 1e+10 than as eleven digits.
local function studLength(distance: number): string
	local whole = math.round(distance)
	return if whole < 10000 then tostring(whole) else string.format("%g", whole)
end

-- The part of a segment that falls inside a rectangle, or nothing if none of it
-- does. Liang-Barsky: the segment is walked as a fraction of itself, and each
-- edge of the rectangle either brings the near end forward or the far end back.
local function clipSegment(from: Vector2, to: Vector2, low: Vector2, high: Vector2): (Vector2?, Vector2?)
	local delta = to - from
	local near, far = 0, 1

	-- Each edge as "t * scale <= limit", which is a lower bound on t when the
	-- segment crosses the edge on the way in and an upper bound on the way out.
	local edges = {
		{ -delta.X, from.X - low.X },
		{ delta.X, high.X - from.X },
		{ -delta.Y, from.Y - low.Y },
		{ delta.Y, high.Y - from.Y },
	}

	for _, edge in edges do
		local scale, limit = edge[1], edge[2]

		if scale == 0 then
			-- Parallel to this edge, so it is either inside it for the whole
			-- length or outside it for the whole length.
			if limit < 0 then
				return nil, nil
			end
		else
			local t = limit / scale

			if scale < 0 then
				near = math.max(near, t)
			else
				far = math.min(far, t)
			end
		end
	end

	if near > far then
		return nil, nil
	end

	return from + delta * near, from + delta * far
end

local function titleColor(node: Instance): Color3
	return TITLE_COLORS[node:GetAttribute("NodeType")] or TITLE_FALLBACK
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

-- The slots down the left of a node, top to bottom, each with the wire it holds
-- and the slot it was built from -- which is what says where a wire dropped on it
-- is written and what type it may carry.
--
-- DataTypes declares the slots; the only ones not declared are the Output
-- registry's, which are one per rule registered with it rather than a fixed list,
-- plus an empty one so that another can be added by dropping a wire on it. A
-- source node and a note declare none and read nothing.
local function inputPortsOf(node: Instance)
	local ports = {}

	for _, slot in DataTypes.inputsOf(node) do
		if slot.repeated then
			local entries = {}

			for _, child in node:GetChildren() do
				if child:IsA("ObjectValue") then
					table.insert(entries, { name = child.Name, wire = child, slot = slot, dataType = slot.dataType })
				end
			end

			table.sort(entries, function(a, b)
				return a.name < b.name
			end)

			for _, entry in entries do
				table.insert(ports, entry)
			end

			table.insert(ports, {
				name = slot.newLabel or "(add input)",
				isNew = true,
				slot = slot,
				dataType = slot.dataType,
			})
		else
			table.insert(ports, {
				name = slot.label or slot.name,
				wire = findWire(node, slot.name),
				slot = slot,
				dataType = slot.dataType,
			})
		end
	end

	return ports
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

-- evaluateGraph runs one graph and leaves the rest of the place alone. It lives
-- with the rest of the evaluation, in the plugin script, and is handed here so
-- the ribbon can offer it over the graph on screen.
local function create(pluginRef: Plugin, evaluateGraph: ((Instance) -> ())?)
	local widgetInfo = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 940, 560, 560, 320)
	local widget = pluginRef:CreateDockWidgetPluginGui("ScatterGraphGraphView", widgetInfo)
	widget.Name = "ScatterGraphGraphView"
	widget.Title = "ScatterGraph Graph View"
	widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local self = {}

	local overlay = GraphUi.newOverlay()
	local inspector = NodeInspector.new(pluginRef, overlay)

	local graph: Instance? = nil
	-- Which nodes are picked, as a set: a box dragged over the canvas can pick
	-- any number of them, and the panel, the ribbon and a drag all work off the
	-- same set however many are in it.
	local selection: { [Instance]: boolean } = {}
	-- Where the canvas has been scrolled to, in view pixels, and how far it is
	-- zoomed: a node at graph point p is drawn at pan + p * zoom.
	local pan = Vector2.zero
	local zoom = ZOOM_DEFAULT
	-- The panel's share of the window, moved by dragging the divider. Held here
	-- rather than rebuilt from the constant so a theme change or a graph switch
	-- keeps the width the author dragged it to.
	local paramColumn = PARAM_COLUMN
	-- Rebuilt on every redraw: where each node sits, what its slots are, and the
	-- widgets drawn for it.
	local positions: { [Instance]: Vector2 } = {}
	local inputs: { [Instance]: any } = {}
	local cards: { [Instance]: any } = {}
	-- The image behind each texture node's thumbnail, by the node it is drawn on.
	-- An EditableImage is a handle with a cost of its own rather than a table, so
	-- one is made when the picture on a card changes and destroyed the moment
	-- that card or that picture is not current -- and, in between, survives the
	-- rebuilds that redraw everything else.
	local previewImages: { [Instance]: any } = {}
	local previewsFailed = false
	local wires = {}
	local graphConnections: { RBXScriptConnection } = {}
	local ribbonButtons = {}

	local root = nil
	local canvas = nil
	-- The right-hand control on the node ribbon: it names the graph on screen and
	-- drops down the list of every graph in the place to switch between them.
	local graphChooser = nil
	-- The movable seam between the canvas and the panel, and the state of a drag
	-- of it. The frames are rebuilt with the interface; the fraction they are
	-- drawn at lives further up, so a rebuild keeps the width it was dragged to.
	local dividerFrame = nil
	local dividerGrip = nil
	local dividerHandle = nil
	local paramPane = nil
	local draggingDivider = false
	-- An invisible TextBox that exists only to hold keyboard focus. A DockWidget
	-- feeds keys to neither UserInputService nor ContextActionService, and a
	-- plain frame cannot take keyboard focus; a focused TextBox both hears the
	-- keys and swallows them, so they never fall through to the 3D viewport.
	local keyCatcher = nil
	local gridLayer = nil
	-- Which tile the grid is currently drawn from, so the zoom crossing a stop is
	-- the only thing that swaps it.
	local gridTileSize = nil
	local content = nil
	local contentScale = nil
	local wireLayer = nil
	local nodeLayer = nil
	local message = nil

	-- What the pointer is doing to the canvas, if anything: sliding it, boxing in
	-- what it passes over, carrying the nodes picked, or trailing a new
	-- connection out of a port.
	local drag = nil
	local pendingWire = nil
	local marqueeBox = nil

	local rebuildQueued = false

	local rebuild
	local buildInterface
	-- Opened from the canvas, but built out of the node templates and the
	-- placement the ribbon's Add Node button uses, which are further down.
	local openContextMenu
	-- Wires are cut to the part of them the canvas can show, so sliding or
	-- zooming the canvas is a redraw of every wire and not just a new offset.
	local layoutWires

	-- The grid is drawn in the window's own pixels rather than the graph's, so
	-- that the tile can be sized to the zoom and lined up with the graph's
	-- multiples: one repeating image, wherever the canvas has been slid to.
	local function refreshGrid()
		if gridLayer == nil or canvas == nil then
			return
		end

		local spacing = gridSpacingFor(zoom)
		local onScreen = spacing * zoom
		-- The tile is drawn at whatever the spacing works out to, so the image
		-- behind it is that many pixels across.
		local tileSize = math.max(2, math.round(onScreen))
		local tile = gridTile(tileSize)

		if tile == nil then
			gridLayer.Visible = false
			return
		end

		-- Only when the zoom has crossed a stop, rather than on every pan.
		if gridTileSize ~= tileSize then
			gridTileSize = tileSize
			gridLayer.ImageContent = tile
		end

		-- Tiling starts at the label's own corner, so the label starts at the
		-- last crossing at or before the corner of the canvas. That is what puts
		-- a dot on every multiple of the spacing rather than on whichever graph
		-- point the canvas happens to have been slid to.
		--
		-- Measured from where the canvas itself was put rather than from the pan
		-- it came from: the canvas rounds the pan to a whole pixel, and the grid
		-- starting anywhere else would leave every dot that fraction off the node
		-- it belongs to. From here on the arithmetic is exact, since the spacing
		-- is a multiple of the snap and the zoom a tenth.
		local origin = Vector2.new(math.round(pan.X), math.round(pan.Y))
		local low = -origin / zoom
		local first = Vector2.new(math.floor(low.X / spacing), math.floor(low.Y / spacing)) * spacing
		local corner = origin + first * zoom
		local size = canvas.AbsoluteSize - corner + Vector2.new(onScreen, onScreen)

		-- Rounded rather than left to the conversion a screen offset does anyway,
		-- since these are whole numbers by the time they arrive and rounding says
		-- so instead of hoping a float lands on the right side of it.
		gridLayer.Visible = true
		gridLayer.TileSize = UDim2.fromOffset(math.round(onScreen), math.round(onScreen))
		gridLayer.Position = UDim2.fromOffset(math.round(corner.X), math.round(corner.Y))
		gridLayer.Size = UDim2.fromOffset(math.round(size.X), math.round(size.Y))
	end

	local function applyView()
		if content ~= nil then
			-- Rounded, so that the grid can round its own corner the same way and
			-- land on the same pixels as the nodes.
			content.Position = UDim2.fromOffset(math.round(pan.X), math.round(pan.Y))
		end

		if contentScale ~= nil then
			contentScale.Scale = zoom
		end

		refreshGrid()

		if layoutWires ~= nil then
			layoutWires()
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

	-- True while the catcher's text is being reset in code, so the reset is not
	-- mistaken for a keystroke by the handler that watches its text.
	local reseedingKeyCatcher = false

	-- Whether an editable field (a parameter box or a note body) currently holds
	-- the keyboard, and whether the pointer is over the canvas. Together these
	-- decide when the catcher may take the keyboard: it may only do so while the
	-- author is on the canvas and not typing into a field. The catcher is a
	-- focused text box, and a focused text box eats every key, so leaving it up
	-- while a field is being edited swallows the keystrokes meant for the field.
	local fieldFocused = false
	local pointerOverCanvas = false

	-- Restores the seed and drops the caret back into the middle of it, ready for
	-- the next key to shorten or lengthen it.
	local function reseedKeyCatcher()
		if keyCatcher == nil then
			return
		end

		reseedingKeyCatcher = true
		keyCatcher.Text = KEY_CATCHER_SEED
		keyCatcher.CursorPosition = KEY_CATCHER_CARET
		reseedingKeyCatcher = false
	end

	-- Points keyboard focus at the hidden catcher, which is what makes the view's
	-- shortcuts fire and keeps their keys from reaching the viewport. Refused
	-- while a field is being typed into, so selecting a node and then editing one
	-- of its parameters does not hand the keyboard straight back to the catcher.
	local function grabKeyboard()
		if keyCatcher ~= nil and not fieldFocused then
			keyCatcher:CaptureFocus()
			reseedKeyCatcher()
		end
	end

	-- Hands the keyboard back so a field can take it.
	local function releaseKeyboard()
		if keyCatcher ~= nil then
			keyCatcher:ReleaseFocus()
		end
	end

	-- A field reports here as it gains and loses the keyboard. Gaining it drops
	-- the catcher at once so the field keeps the keys; losing it re-arms the
	-- shortcuts, but only if the pointer is still on the canvas, so tabbing out of
	-- a field toward the rest of Studio does not silently grab the keyboard back.
	local function setFieldFocused(focused: boolean)
		fieldFocused = focused

		if focused then
			releaseKeyboard()
		elseif pointerOverCanvas then
			grabKeyboard()
		end
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

	local function nodeWidth(node: Instance): number
		return if isReroute(node) then REROUTE_SIZE else NODE_WIDTH
	end

	-- How much taller a card is for having a picture on it, which is none at all
	-- until the node has been evaluated and there is one to draw -- or ever, in a
	-- Studio that cannot make the image to draw it with, where a card should be
	-- its old self rather than one with an empty strip along the bottom.
	local function previewHeight(node: Instance): number
		if previewsFailed or TexturePreview.of(node) == nil then
			return 0
		end

		return PREVIEW_HEIGHT + PADDING
	end

	local function nodeHeight(node: Instance): number
		if isNote(node) then
			return NOTE_HEIGHT
		end

		if isReroute(node) then
			return REROUTE_SIZE
		end

		local ports = inputs[node]
		return headerHeight(node)
			+ (if ports ~= nil then #ports else 0) * PORT_ROW
			+ previewHeight(node)
	end

	-- Both ends of a reroute are the dot itself: the wire arriving and the wire
	-- leaving meet at one point, which is what makes it read as a bend in a wire
	-- rather than as a node with a near side and a far side.
	local function rerouteCenter(node: Instance): Vector2
		local origin = positions[node] or Vector2.zero
		return origin + Vector2.new(REROUTE_SIZE / 2, REROUTE_SIZE / 2)
	end

	local function outputPortCenter(node: Instance): Vector2
		if isReroute(node) then
			return rerouteCenter(node)
		end

		local origin = positions[node] or Vector2.zero
		return origin + Vector2.new(NODE_WIDTH, TITLE_HEIGHT + PORT_ROW / 2)
	end

	local function inputPortCenter(node: Instance, index: number): Vector2
		if isReroute(node) then
			return rerouteCenter(node)
		end

		local origin = positions[node] or Vector2.zero
		return origin + Vector2.new(0, headerHeight(node) + (index - 0.5) * PORT_ROW)
	end

	-- Nodes are placed in columns by how far they are from a source, which puts
	-- every wire left to right and reads the way the points flow, and in rows by
	-- the rule they belong to, so a chain runs along its own line the way it
	-- reads in the Spreadsheet view. The Output registry goes at the top of the last
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

		-- Everything on the canvas sits on the grid, whether it was laid out by
		-- the columns above or dragged somewhere by hand before there was a grid
		-- to drag it onto. A nudged position is written back only when the node
		-- is next moved, so this alone leaves the graph alone.
		for node, position in positions do
			positions[node] = snapToGrid(position)
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

	-- A run makes the textures the cards draw, and there is no other sign of one
	-- having happened: nothing in the graph changes when it is evaluated. The
	-- pictures arrive one node at a time, and this coalesces them into the one
	-- redraw a rebuild already is.
	TexturePreview.onChanged(scheduleRebuild)

	-- What the canvas can currently show, in graph pixels.
	local function visibleBounds(): (Vector2, Vector2)
		local size = if canvas ~= nil then canvas.AbsoluteSize else Vector2.zero
		return -pan / zoom, (size - pan) / zoom
	end

	-- Roblox draws no lines, so a wire is a thin frame turned to face along it.
	-- A turned frame is also the one thing ClipsDescendants does not hold to the
	-- canvas, so a wire running off the edge would draw straight over the
	-- parameter panel beside it: the segment is cut to what is on screen here
	-- instead, which a frame at any angle obeys because it is only ever asked to
	-- draw the part that fits.
	-- Returns the piece it drew, for a caller that has to know how much of the wire
	-- that was: a gradient along one has to be cut to the same piece.
	local function drawLine(line: Frame, from: Vector2, to: Vector2): (Vector2?, Vector2?)
		local low, high = visibleBounds()
		local start, finish = clipSegment(from, to, low, high)

		if start == nil or finish == nil then
			line.Visible = false
			return nil, nil
		end

		line.Visible = true

		local delta = finish - start
		line.Size = UDim2.fromOffset(math.max(delta.Magnitude, 1), WIRE_THICKNESS)
		line.Position = UDim2.fromOffset((start.X + finish.X) / 2, (start.Y + finish.Y) / 2)
		-- Off the whole wire's direction rather than the visible piece's, which
		-- is the same heading but degenerates when the piece has no length.
		line.Rotation = math.deg(math.atan2(to.Y - from.Y, to.X - from.X))
		return start, finish
	end

	-- The sweep along a wire that converts what it carries, cut to the piece of the
	-- wire actually on screen. The frame is turned to face along the wire, so the
	-- gradient runs from the source end to the target end without being told which
	-- way that is; what it does have to be told is where the visible piece begins
	-- and ends along the whole, or a wire mostly off the edge would show the whole
	-- sweep across the little of it that is left.
	local function paintCast(wire, from: Vector2, to: Vector2, start: Vector2, finish: Vector2)
		local length = (to - from).Magnitude
		local at = if length > 0 then (start - from).Magnitude / length else 0
		local ends = if length > 0 then (finish - from).Magnitude / length else 1

		wire.gradient.Color =
			ColorSequence.new(wire.castFrom:Lerp(wire.castTo, at), wire.castFrom:Lerp(wire.castTo, ends))
	end

	layoutWires = function()
		for _, wire in wires do
			local from = outputPortCenter(wire.from)
			local to = inputPortCenter(wire.to, wire.index)

			local start, finish = drawLine(wire.line, from, to)

			if wire.gradient ~= nil and start ~= nil and finish ~= nil then
				paintCast(wire, from, to, start, finish)
			end

			wire.breaker.Position = UDim2.fromOffset((from.X + to.X) / 2, (from.Y + to.Y) / 2)
		end
	end

	-- The picked nodes in the order they are laid out, left to right and then top
	-- to bottom, so the panel below reads the way the canvas does.
	local function selectionList(): { Instance }
		local nodes = {}

		for node in selection do
			table.insert(nodes, node)
		end

		table.sort(nodes, function(a, b)
			local pa = positions[a] or Vector2.zero
			local pb = positions[b] or Vector2.zero

			if pa.X ~= pb.X then
				return pa.X < pb.X
			end

			if pa.Y ~= pb.Y then
				return pa.Y < pb.Y
			end

			return a:GetFullName() < b:GetFullName()
		end)

		return nodes
	end

	-- The one node in the selection, where being the only one is what matters:
	-- deleting says something different about one node than about nine.
	local function loneSelection(): Instance?
		local only = nil

		for node in selection do
			if only ~= nil then
				return nil
			end
			only = node
		end

		return only
	end

	local function paintSelection()
		for node, card in cards do
			local isSelected = selection[node] == true

			-- A red edge marks a node that cannot run, and it wins over the
			-- selection colour so the error stays visible while the node is
			-- picked -- the strip lift below still shows that it is selected.
			local edge, weight
			if card.invalid then
				edge, weight = ERROR_COLOR, 2
			elseif isSelected then
				edge, weight = color(Enum.StudioStyleGuideColor.LinkText), 2
			else
				edge, weight = NODE_BORDER, 1
			end

			-- A round card is edged with a stroke rather than a border, a border
			-- being drawn square whatever the corner radius says.
			if card.stroke ~= nil then
				card.stroke.Color = edge
				card.stroke.Thickness = weight
			else
				card.frame.BorderColor3 = edge
				card.frame.BorderSizePixel = weight
			end
			-- Selection lightens the type colour rather than replacing it, so a
			-- selected node still says what it is.
			card.strip.BackgroundColor3 = if isSelected
				then card.tint:Lerp(Color3.new(1, 1, 1), TITLE_SELECTED_LIFT)
				else card.tint
		end
	end

	local function showInspector()
		local nodes = selectionList()

		if #nodes == 0 then
			inspector.show(function()
				return {}
			end, "Select a node on the canvas to edit its parameters. Drag a box over several to pick them all.")
			return
		end

		-- Every picked node in one panel, each under its own heading: the panel
		-- is built to show a list, which is how the Spreadsheet view uses it.
		inspector.show(function()
			local shown = {}

			for _, node in nodes do
				if node.Parent ~= nil then
					table.insert(shown, node)
				end
			end

			return shown
		end, "These nodes are no longer in the graph.")
	end

	local function updateRibbon()
		local hasGraph = graph ~= nil and graph:IsDescendantOf(game)

		-- The chooser always names what is on screen, so it stays right whether
		-- the graph changed under it or the view was pointed at a new one.
		if graphChooser ~= nil then
			local name = "(no graph)"
			if graph ~= nil and graph:IsDescendantOf(game) then
				name = graph.Name
			end
			graphChooser.Text = name .. "   \u{25BE}"
		end
		-- The Output registry is the graph's outlet rather than a node the
		-- author added, and a graph without one evaluates to nothing, so it is
		-- not offered for deletion. A selection that includes it still offers
		-- deletion for whatever else is picked.
		local hasNode = false

		for node in selection do
			if not isOutput(node) then
				hasNode = true
				break
			end
		end

		for _, entry in ribbonButtons do
			local enabled = if entry.requires == "node"
				then hasNode
				elseif entry.requires == "none" then true
				else hasGraph
			local modifier = if enabled then nil else Enum.StudioStyleGuideModifier.Disabled

			entry.button.Active = enabled
			entry.button.AutoButtonColor = enabled
			entry.button.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Button, modifier)
			entry.button.TextColor3 = color(Enum.StudioStyleGuideColor.ButtonText, modifier)
		end
	end

	-- Everything a change of selection shows: the cards it is on, the parameters
	-- in the panel, and which ribbon buttons having a node picked offers.
	local function applySelection()
		paintSelection()
		showInspector()
		updateRibbon()
	end

	local function selectOnly(node: Instance?)
		-- Nothing has changed when the node asked for is already the only one
		-- picked, or when a second click on empty canvas clears nothing.
		if node == nil then
			if next(selection) == nil then
				return
			end
		elseif loneSelection() == node then
			return
		end

		table.clear(selection)

		if node ~= nil then
			selection[node] = true
		end

		applySelection()
	end

	local function toggleSelected(node: Instance)
		if selection[node] then
			selection[node] = nil
		else
			selection[node] = true
		end

		applySelection()
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

	-- Writes down where the nodes are before an edit that would otherwise move
	-- them. The columns are worked out from the wiring, so changing the wiring
	-- relays out every node that has never been dragged: cutting a wire shortens
	-- the chain behind it and everything downstream slides a column left, and a
	-- chain no longer reaching the Output drops to a row of its own. The author
	-- did not ask for any of that by deleting one wire.
	--
	-- Every node on the canvas rather than only the two either end of the wire,
	-- since that is how far a relayout reaches. A node already carrying a
	-- position is left as it is, because it is already saying where it wants to
	-- be. Called inside the edit's own recording, so one undo takes the wiring
	-- and these positions back together.
	local function pinPositions()
		for node, position in positions do
			if node.Parent ~= nil and typeof(node:GetAttribute(POSITION_ATTRIBUTE)) ~= "Vector2" then
				node:SetAttribute(POSITION_ATTRIBUTE, position)
			end
		end
	end

	local function connect(source: Instance, target: Instance, port)
		if source == target or wouldCycle(source, target) then
			warn("ScatterGraph Graph view: wiring " .. source.Name .. " into " .. target.Name
				.. " would feed it back into itself, so the connection was not made.")
			return
		end

		-- A slot takes one kind of thing -- or something with an obvious reading as
		-- that kind of thing, a number wired to a texture slot being read as that
		-- shade everywhere -- and this is the gesture that would put something else
		-- in it. The ports say as much in their colours; a drop aimed at one anyway
		-- is turned down rather than quietly making a wire the node cannot read.
		local produced = DataTypes.producedBy(source)
		if not DataTypes.accepts(produced, port.dataType) then
			warn("ScatterGraph Graph view: " .. source.Name .. " produces " .. DataTypes.label(produced)
				.. " and the " .. port.name .. " slot on " .. target.Name .. " takes "
				.. DataTypes.label(port.dataType) .. ", so the connection was not made.")
			return
		end

		local slot = port.slot

		-- What the wire is stamped with. A slot that takes anything says nothing
		-- about it, so the stamp is what turned out to be wired to it: a reroute's
		-- wire reads as the kind of thing it is carrying.
		local stamp = slot.wireNodeType or produced

		recorded("Connect " .. source.Name .. " to " .. target.Name, function()
			pinPositions()

			-- A repeated slot has a wire per thing registered with it, so a drop
			-- on its empty port adds one named after what it registers.
			if port.isNew then
				local entry = Instance.new("ObjectValue")
				entry.Name = uniqueChildName(target, source.Name)
				entry:SetAttribute("NodeType", stamp)
				entry.Value = source
				entry.Parent = target
				return
			end

			local wire = port.wire

			if wire == nil then
				wire = Instance.new("ObjectValue")
				wire.Name = slot.name
				wire.Parent = target
			end

			-- Restamped rather than stamped only when new, since a reroute
			-- emptied and then aimed at another kind of thing is carrying
			-- something else now.
			if stamp ~= nil then
				wire:SetAttribute("NodeType", stamp)
			end

			wire.Value = source
		end)

		rebuild()
	end

	local function disconnect(port)
		recorded("Break connection", function()
			pinPositions()

			if port.slot.repeated then
				-- An Output entry pointing at nothing is a rule that places
				-- nothing and warns about it every evaluation, so the entry goes
				-- rather than being emptied.
				port.wire.Parent = nil
			else
				-- A declared slot keeps its empty wire, which is how the Explorer
				-- and the Spreadsheet view keep showing the slot.
				port.wire.Value = nil
			end
		end)

		rebuild()
	end

	-- Which slot a dropped wire landed on, given what the wire is carrying. Ports
	-- are small, so a drop that misses one is still taken by the node it landed
	-- on -- and there it is the slot that takes what is being dragged, since a
	-- node with two slots of different types is unambiguous about which one a
	-- distance field or a cloud of points was meant for.
	local function portAt(point: Vector2, dataType)
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
					and point.X <= origin.X + nodeWidth(node)
					and point.Y >= origin.Y
					and point.Y <= origin.Y + nodeHeight(node)

				if within then
					-- On a node whose slots are made as they are wired -- the
					-- Output registry, either merge -- the free slot is the empty
					-- one at the bottom, and dropping on the body should take that
					-- rather than quietly repoint a wire that is already there.
					local last = ports[#ports]
					local fallback = if last.isNew then last else ports[1]

					if dataType ~= nil then
						for _, port in ports do
							if port.dataType == dataType then
								-- Which of a repeated slot's ports the drop takes
								-- is still the question the fallback answers.
								return node, if port.slot.repeated then fallback else port
							end
						end

						-- Failing that, a slot this would be read into on the way
						-- in. Still a better answer than the first slot on the
						-- card, which is one the drop could not be wired to at all.
						for _, port in ports do
							if DataTypes.converts(dataType, port.dataType) then
								return node, if port.slot.repeated then fallback else port
							end
						end
					end

					return node, fallback
				end
			end
		end

		return nil, nil
	end

	-- Every node the box drawn between two graph points touches. Touching rather
	-- than containing, so a box swept across a column picks the whole column
	-- without having to reach round the ends of it.
	local function nodesWithin(from: Vector2, to: Vector2): { Instance }
		local low = Vector2.new(math.min(from.X, to.X), math.min(from.Y, to.Y))
		local high = Vector2.new(math.max(from.X, to.X), math.max(from.Y, to.Y))

		local found = {}

		for node in inputs do
			local origin = positions[node]

			if origin ~= nil then
				local corner = origin + Vector2.new(nodeWidth(node), nodeHeight(node))
				local overlaps = origin.X <= high.X
					and corner.X >= low.X
					and origin.Y <= high.Y
					and corner.Y >= low.Y

				if overlaps then
					table.insert(found, node)
				end
			end
		end

		return found
	end

	local function clearPendingWire()
		if pendingWire ~= nil then
			pendingWire:Destroy()
			pendingWire = nil
		end
	end

	local function clearMarquee()
		if marqueeBox ~= nil then
			marqueeBox:Destroy()
			marqueeBox = nil
		end
	end

	-- What the box covers, drawn in graph pixels like everything else on the
	-- canvas so it stays over the same nodes while zoomed.
	local function layoutMarquee(from: Vector2, to: Vector2)
		if marqueeBox == nil then
			return
		end

		local low = Vector2.new(math.min(from.X, to.X), math.min(from.Y, to.Y))
		local size = Vector2.new(math.abs(to.X - from.X), math.abs(to.Y - from.Y))

		marqueeBox.Position = UDim2.fromOffset(low.X, low.Y)
		marqueeBox.Size = UDim2.fromOffset(size.X, size.Y)
	end

	local function endDrag()
		local finished = drag
		drag = nil

		clearPendingWire()
		clearMarquee()

		if finished == nil then
			return
		end

		if finished.kind == "node" then
			if finished.moved then
				-- One entry in the undo history for the whole handful, since one
				-- drag moved them together.
				local count = 0
				for _ in finished.grabs do
					count += 1
				end

				local label = if count == 1 then "Move " .. finished.node.Name else "Move " .. count .. " nodes"

				recorded(label, function()
					for node in finished.grabs do
						if node.Parent ~= nil then
							node:SetAttribute(POSITION_ATTRIBUTE, positions[node])
						end
					end
				end)
			end
		elseif finished.kind == "marquee" then
			-- The set was kept up to date as the box was dragged; the release is
			-- what hands it to the panel and the ribbon.
			applySelection()
		elseif finished.kind == "wire" then
			local target, port = portAt(finished.point or Vector2.zero, DataTypes.producedBy(finished.node))
			-- A wire dropped back on the node it came from is a gesture given up
			-- on rather than a mistake worth saying anything about -- and on a
			-- reroute, where the wire leaves from the same point its own slot sits
			-- at, letting go without moving is exactly that.
			if target ~= nil and port ~= nil and target ~= finished.node and finished.node.Parent ~= nil then
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
			-- Every picked node carries its own offset from the pointer, so the
			-- handful keeps its arrangement rather than piling up on the one
			-- actually grabbed.
			local at = canvasPoint(input)

			for node, grab in drag.grabs do
				local card = cards[node]

				if card ~= nil then
					-- Each node snaps on its own, which keeps the handful in the
					-- arrangement it was picked up in: they were all on the grid
					-- to begin with, so they all land the same distance off it.
					positions[node] = snapToGrid(at + grab)
					card.frame.Position = UDim2.fromOffset(positions[node].X, positions[node].Y)
				end
			end

			drag.moved = true
			layoutWires()
			return
		end

		if drag.kind == "marquee" then
			drag.point = canvasPoint(input)
			layoutMarquee(drag.origin, drag.point)

			-- Painted as the box moves, so what a release would pick is visible
			-- before it happens. The panel and the ribbon wait for the release,
			-- being far more work than a border colour.
			table.clear(selection)

			for node in drag.base do
				selection[node] = true
			end

			for _, node in nodesWithin(drag.origin, drag.point) do
				selection[node] = true
			end

			paintSelection()
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

	-- Shift adds to what is already picked rather than starting again, for both
	-- a box and a click.
	local function addingToSelection(): boolean
		return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
	end

	-- A press on empty canvas starts boxing in nodes. A press that turns out to
	-- be a click is a box of no size, which picks nothing -- which is what a
	-- click on empty canvas means anyway.
	local function beginMarquee(input: InputObject)
		local base = {}

		if addingToSelection() then
			for node in selection do
				base[node] = true
			end
		end

		local origin = canvasPoint(input)
		drag = { kind = "marquee", origin = origin, point = origin, base = base }

		local box = Instance.new("Frame")
		box.BackgroundColor3 = color(Enum.StudioStyleGuideColor.LinkText)
		box.BackgroundTransparency = MARQUEE_FILL
		box.BorderColor3 = color(Enum.StudioStyleGuideColor.LinkText)
		box.BorderSizePixel = 1
		box.ZIndex = 4
		box.Parent = content
		marqueeBox = box

		layoutMarquee(origin, origin)

		if next(selection) ~= nil and next(base) == nil then
			table.clear(selection)
			paintSelection()
		end
	end

	-- Where a press on a card leaves the selection: the node pressed on its own,
	-- unless it is already picked -- dragging a handful starts on one of them --
	-- or shift is held, which adds it to or takes it out of the handful.
	local function pickForDrag(node: Instance)
		if addingToSelection() then
			toggleSelected(node)
			return
		end

		if not selection[node] then
			selectOnly(node)
		end
	end

	-- Every picked node's offset from where the pointer grabbed, which is what
	-- moves them together. Whatever was pressed on is picked by now, so the
	-- selection is the handful being carried.
	local function beginNodeDrag(node: Instance, input: InputObject)
		local at = canvasPoint(input)
		local grabs = {}

		for other in selection do
			grabs[other] = (positions[other] or Vector2.zero) - at
		end

		drag = { kind = "node", node = node, grabs = grabs }
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

		-- Geometric so a notch is the same proportion of zoom at either end of the
		-- range, and raised to the notch count so a fractional wheel delta scales
		-- by that fraction rather than being rounded to a whole step or to nothing.
		local target = math.clamp(zoom * ZOOM_WHEEL_STEP ^ notches, ZOOM_MIN, ZOOM_MAX)

		if target == zoom then
			return
		end

		local held = (at - pan) / zoom
		zoom = target
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

		-- The trail out of a port is drawn in that port's type colour, which is
		-- the colour the wire will be if the drop lands: a connection looks the
		-- same while it is being made as it does once it is made.
		local line = Instance.new("Frame")
		line.AnchorPoint = Vector2.new(0.5, 0.5)
		line.BackgroundColor3 = DataTypes.color(DataTypes.producedBy(node))
		line.BorderSizePixel = 0
		line.Size = UDim2.fromOffset(1, WIRE_THICKNESS)
		line.Position = UDim2.fromOffset(outputPortCenter(node).X, outputPortCenter(node).Y)
		line.ZIndex = 3
		line.Parent = wireLayer
		pendingWire = line

		drag = { kind = "wire", node = node, point = outputPortCenter(node) }
	end

	-- A port is a circle in the colour of the data type it carries, so what a
	-- wire is allowed to join reads off the canvas rather than out of the node
	-- reference. Whether it is connected is said by the fill instead: a full port
	-- is a solid disc, an empty one a ring of the same colour around the colour
	-- an empty field is drawn in. Colour therefore only ever means type, which is
	-- what makes it worth reading.
	local function makePort(
		parent: GuiObject,
		center: Vector2,
		filled: boolean,
		dataType: DataTypes.DataType?
	): TextButton
		local port = Instance.new("TextButton")
		port.AnchorPoint = Vector2.new(0.5, 0.5)
		port.Position = UDim2.fromOffset(center.X, center.Y)
		port.Size = UDim2.fromOffset(PORT_SIZE, PORT_SIZE)
		port.BackgroundColor3 = DataTypes.color(dataType)
		port.BorderColor3 = color(Enum.StudioStyleGuideColor.Border)
		port.Text = ""
		port.AutoButtonColor = false
		port.ZIndex = 3
		port.Parent = parent

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = port

		-- The hole in an empty port. A frame rather than a smaller port drawn
		-- over a larger one, and one that takes no input of its own, so a press
		-- in the middle of a port still reaches the button underneath it.
		if not filled then
			local hole = Instance.new("Frame")
			hole.AnchorPoint = Vector2.new(0.5, 0.5)
			hole.Position = UDim2.fromScale(0.5, 0.5)
			hole.Size = UDim2.fromOffset(PORT_SIZE - PORT_RING * 2, PORT_SIZE - PORT_RING * 2)
			hole.BackgroundColor3 = color(Enum.StudioStyleGuideColor.InputFieldBackground)
			hole.BorderSizePixel = 0
			hole.Parent = port

			local holeCorner = Instance.new("UICorner")
			holeCorner.CornerRadius = UDim.new(1, 0)
			holeCorner.Parent = hole
		end

		carryDrag(port)
		return port
	end

	local function makeNoteCard(node: Instance)
		local origin = positions[node] or Vector2.zero

		local frame = Instance.new("TextButton")
		frame.Position = UDim2.fromOffset(origin.X, origin.Y)
		frame.Size = UDim2.fromOffset(NODE_WIDTH, NOTE_HEIGHT)
		frame.BackgroundColor3 = NOTE_BACKGROUND
		frame.BorderColor3 = NODE_BORDER
		frame.BorderSizePixel = 1
		frame.Text = ""
		frame.AutoButtonColor = false
		frame.Parent = nodeLayer

		-- The gummed strip along the top: what the note is dragged by, since the
		-- body below takes its own clicks for editing. It takes no input of its
		-- own, so a press on it reaches the card and starts a drag.
		local strip = Instance.new("Frame")
		strip.Size = UDim2.new(1, 0, 0, TITLE_HEIGHT)
		strip.BackgroundColor3 = NOTE_HEADER
		strip.BorderSizePixel = 0
		strip.Parent = frame

		local title = makeLabel(node.Name, NOTE_TEXT, true)
		title.Size = UDim2.new(1, -PADDING * 2, 1, 0)
		title.Position = UDim2.fromOffset(PADDING, 0)
		title.Parent = strip

		-- The note itself, editable in place. What is typed is committed to the
		-- Text attribute only when the box loses focus, so a keystroke does not
		-- schedule a rebuild that would tear the card out from under the caret.
		local body = Instance.new("TextBox")
		body.Position = UDim2.fromOffset(0, TITLE_HEIGHT)
		body.Size = UDim2.new(1, 0, 1, -TITLE_HEIGHT)
		body.BackgroundTransparency = 1
		body.ClearTextOnFocus = false
		body.MultiLine = true
		body.TextWrapped = true
		body.TextXAlignment = Enum.TextXAlignment.Left
		body.TextYAlignment = Enum.TextYAlignment.Top
		body.Font = Enum.Font.SourceSans
		body.TextSize = 14
		body.TextColor3 = NOTE_TEXT
		body.PlaceholderText = "Write a note..."
		body.PlaceholderColor3 = NOTE_TEXT:Lerp(NOTE_BACKGROUND, 0.5)
		local stored = node:GetAttribute("Text")
		body.Text = if typeof(stored) == "string" then stored else ""
		body.Parent = frame

		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, PADDING)
		pad.PaddingRight = UDim.new(0, PADDING)
		pad.PaddingTop = UDim.new(0, 4)
		pad.PaddingBottom = UDim.new(0, 4)
		pad.Parent = body

		cards[node] = { frame = frame, strip = strip, tint = NOTE_HEADER, invalid = false }

		-- Editing a note is picking it, so the panel and ribbon agree with the
		-- canvas about what is selected. Focus is left on the box, so this does
		-- not interrupt the typing that raised it.
		body.Focused:Connect(function()
			-- Drops the catcher so the note keeps the keys it is being typed into,
			-- the same way a parameter field does.
			setFieldFocused(true)
			selectOnly(node)
		end)

		body.FocusLost:Connect(function()
			setFieldFocused(false)

			local current = node:GetAttribute("Text")
			current = if typeof(current) == "string" then current else ""
			if body.Text == current then
				return
			end
			recorded("Edit note", function()
				node:SetAttribute("Text", body.Text)
			end)
		end)

		-- Dragging works off the strip and the card's own margins; the body,
		-- being a text box, keeps its clicks for the caret.
		frame.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
				return
			end

			grabKeyboard()
			pickForDrag(node)

			if selection[node] then
				beginNodeDrag(node, input)
			end
		end)

		carryDrag(frame)

		overlay.watchForTooltip(strip, "Drag to move this note. Click the body to write in it.")
	end

	-- A reroute as a dot: no title, no parameter rows, and no pair of ports on
	-- opposite edges, since all three would be a card's worth of canvas spent
	-- saying that a wire goes through here. It is drawn like the ports it stands
	-- between -- the colour of what it carries, solid once something is wired into
	-- it and a ring while nothing is -- so an empty one reads as an empty port
	-- rather than needing a badge to say the same thing.
	local function makeRerouteCard(node: Instance)
		local origin = positions[node] or Vector2.zero
		local carried = DataTypes.producedBy(node)
		local port = (inputs[node] or {})[1]
		local filled = port ~= nil and port.wire ~= nil and port.wire.Value ~= nil
		local tint = DataTypes.color(carried)

		local dot = Instance.new("TextButton")
		dot.Position = UDim2.fromOffset(origin.X, origin.Y)
		dot.Size = UDim2.fromOffset(REROUTE_SIZE, REROUTE_SIZE)
		dot.BackgroundColor3 = tint
		dot.BorderSizePixel = 0
		dot.Text = ""
		dot.AutoButtonColor = false
		dot.Parent = nodeLayer

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = dot

		-- A stroke rather than the border every card is edged with, since a border
		-- is drawn square whatever the corner radius says and this one is a circle.
		-- Border mode rather than the contextual default, which on a button means
		-- the text it does not have.
		local stroke = Instance.new("UIStroke")
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Color = NODE_BORDER
		stroke.Thickness = 1
		stroke.Parent = dot

		-- The hole in an empty reroute. Its ring is the same share of the dot as a
		-- port's is of a port, so the two read as the same thing at their two
		-- sizes. It takes no input of its own, so a press in the middle of the dot
		-- still reaches the dot.
		if not filled then
			local ring = PORT_RING * REROUTE_SIZE / PORT_SIZE

			local hole = Instance.new("Frame")
			hole.AnchorPoint = Vector2.new(0.5, 0.5)
			hole.Position = UDim2.fromScale(0.5, 0.5)
			hole.Size = UDim2.fromOffset(REROUTE_SIZE - ring * 2, REROUTE_SIZE - ring * 2)
			hole.BackgroundColor3 = color(Enum.StudioStyleGuideColor.InputFieldBackground)
			hole.BorderSizePixel = 0
			hole.Parent = dot

			local holeCorner = Instance.new("UICorner")
			holeCorner.CornerRadius = UDim.new(1, 0)
			holeCorner.Parent = hole
		end

		-- The dot stands in for the strip a card is selected by, so picking one
		-- lightens the type colour the way picking a card lightens its title.
		cards[node] = { frame = dot, strip = dot, stroke = stroke, tint = tint, invalid = false }

		-- What a wire is pulled out of. A card keeps its two gestures apart by
		-- geometry -- the body is dragged to move it, the port on its edge to wire
		-- it -- and a dot has no room for both, so it grows one: an ordinary output
		-- port on its right edge, shown while the pointer is on it and gone again
		-- afterwards, which leaves a reroute a bare dot to look at and a node with
		-- a port to work. Geometry rather than a held key because this window's
		-- keyboard arrives through a focused text box rather than through key
		-- events (see grabKeyboard), and a modifier held on macOS never reaches it.
		local nub = makePort(dot, Vector2.new(REROUTE_SIZE, REROUTE_SIZE / 2), true, carried)
		nub.Visible = false

		overlay.watchForTooltip(
			nub,
			"The "
				.. DataTypes.label(carried)
				.. " this reroute carries. Drag from here onto another node to feed it."
		)

		-- Tracked on both, because the port hangs half outside the dot: the pointer
		-- reaching it can leave the dot, and hiding the port then would take it out
		-- from under the pointer on its way to it.
		local onDot, onNub = false, false
		local function showNub()
			nub.Visible = onDot or onNub
		end

		dot.MouseEnter:Connect(function()
			onDot = true
			showNub()
		end)
		dot.MouseLeave:Connect(function()
			onDot = false
			showNub()
		end)

		nub.MouseEnter:Connect(function()
			onNub = true
			showNub()
		end)
		nub.MouseLeave:Connect(function()
			onNub = false
			showNub()
		end)

		nub.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				selectOnly(node)
				beginWireDrag(node)
			end
		end)

		dot.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
				return
			end

			grabKeyboard()
			pickForDrag(node)

			if selection[node] then
				beginNodeDrag(node, input)
			end
		end)

		carryDrag(dot)

		overlay.watchForTooltip(
			dot,
			node.Name
				.. ": a reroute carrying "
				.. (if carried ~= nil then DataTypes.label(carried) else "nothing yet")
				.. ".\nDrag to move it. Drag from the port on its right to wire it into another node."
				.. "\nDrop a wire on it to change what it carries."
		)
	end

	-- The image a thumbnail is drawn from, made once per picture and kept until
	-- the node makes a different one. Nil where this Studio cannot make an
	-- editable image at all, which costs the cards their pictures and nothing
	-- else -- said once rather than once a card, since it will not start working
	-- partway through a session.
	local function previewContent(node: Instance, preview): Content?
		local held = previewImages[node]

		if held ~= nil then
			if held.preview == preview then
				return held.content
			end

			held.image:Destroy()
			previewImages[node] = nil
		end

		if previewsFailed then
			return nil
		end

		local ok, err = pcall(function()
			local image = AssetService:CreateEditableImage({ Size = Vector2.new(preview.width, preview.height) })
			image:WritePixelsBuffer(Vector2.zero, image.Size, preview.pixels)

			-- The image is held alongside the Content, which is a handle to it
			-- rather than a copy of it.
			previewImages[node] = { preview = preview, image = image, content = Content.fromObject(image) }
		end)

		if not ok then
			previewsFailed = true
			warn("ScatterGraph: no texture previews -- " .. tostring(err))
			return nil
		end

		return previewImages[node].content
	end

	-- Let go of the images of every node not in `keep`, which is what a rebuild
	-- leaves behind when a node is deleted or a picture forgotten.
	local function releasePreviewImages(keep: { [Instance]: any })
		for node, held in previewImages do
			if keep[node] == nil then
				held.image:Destroy()
				previewImages[node] = nil
			end
		end
	end

	-- What a picture on a card is of, in the words the card uses for it. A
	-- density is drawn as the shades it already is, and read as chances; a field
	-- is studs, stretched to fill the ramp, and so has to say what it was
	-- stretched by -- which is also the only place either says which way round
	-- the picture is.
	local function previewTooltip(preview): string
		local ground = " Over "
			.. math.floor(preview.studs.X)
			.. " by "
			.. math.floor(preview.studs.Y)
			.. " studs of ground, at "
			.. math.floor(preview.cells.X)
			.. " by "
			.. math.floor(preview.cells.Y)
			.. " cells."

		if preview.kind == "field" then
			return "The distance field this node measured when its graph was last run, seen from above."
				.. "\nDark is the material itself, down to "
				.. studLength(preview.inside)
				.. " studs inside it at the darkest; light is the ground off it, out to "
				.. studLength(preview.outside)
				.. " studs clear at the lightest. The halfway tone is its edge."
				.. "\nThe shades are stretched to whatever this field runs to, so they say where things are "
				.. "rather than how far."
				.. ground
		end

		return "The texture this node made when its graph was last run, seen from above."
			.. "\nRead as a density, white keeps every candidate point standing there and black keeps none."
			.. ground
	end

	-- What this node measured, last time it was evaluated: a small greyscale
	-- picture, fitted into the strip at the bottom of the card and centred there
	-- so it keeps the shape of the ground it covers. Nothing is drawn for a node
	-- that has not been run, which is how a card says so.
	local function addPreview(node: Instance, frame: Frame | TextButton, top: number)
		local preview = TexturePreview.of(node)
		if preview == nil then
			return
		end

		local content = previewContent(node, preview)
		if content == nil then
			return
		end

		local box = Instance.new("Frame")
		box.Position = UDim2.fromOffset(PADDING, top)
		box.Size = UDim2.fromOffset(NODE_WIDTH - PADDING * 2, PREVIEW_HEIGHT)
		box.BackgroundColor3 = color(Enum.StudioStyleGuideColor.InputFieldBackground)
		box.BorderSizePixel = 0
		box.Parent = frame

		-- As large as it goes without leaving the strip or being stretched. The
		-- picture is already the shape of the ground, so one scale does both.
		local fit = math.min(box.Size.X.Offset / preview.width, PREVIEW_HEIGHT / preview.height)

		local picture = Instance.new("ImageLabel")
		picture.AnchorPoint = Vector2.new(0.5, 0.5)
		picture.Position = UDim2.fromScale(0.5, 0.5)
		picture.Size = UDim2.fromOffset(
			math.max(1, math.floor(preview.width * fit)),
			math.max(1, math.floor(preview.height * fit))
		)
		picture.BackgroundTransparency = 1
		picture.ImageContent = content

		-- A density is left the grey it is, since grey there is a stated chance
		-- and any colour over it would be saying something the texture does not.
		-- A field is not a shade of anything to begin with, so it is tinted the
		-- colour its own wires and ports are: the two kinds of picture are then
		-- told apart at a glance, in the colour language the canvas already has.
		if preview.kind == "field" then
			picture.ImageColor3 = DataTypes.color(DataTypes.SDF_GRID_2D)
		end

		picture.Parent = box

		overlay.watchForTooltip(box, previewTooltip(preview))
	end

	local function makeCard(node: Instance)
		if isNote(node) then
			makeNoteCard(node)
			return
		end

		if isReroute(node) then
			makeRerouteCard(node)
			return
		end

		local ports = inputs[node]
		local origin = positions[node] or Vector2.zero
		local issues = AttributeSchema.issues(node)

		-- A button rather than a frame, for the same reason the ports are: only a
		-- button is handed the press it is under. A frame here is passed over in
		-- favour of the canvas background behind it, which reads the press as a
		-- click on empty canvas and clears the selection rather than making it.
		local frame = Instance.new("TextButton")
		frame.Position = UDim2.fromOffset(origin.X, origin.Y)
		frame.Size = UDim2.fromOffset(NODE_WIDTH, nodeHeight(node))
		frame.BackgroundColor3 = color(Enum.StudioStyleGuideColor.MainBackground)
		frame.BorderColor3 = NODE_BORDER
		frame.BorderSizePixel = 1
		frame.Text = ""
		frame.AutoButtonColor = false
		frame.Parent = nodeLayer

		local tint = titleColor(node)

		local strip = Instance.new("Frame")
		strip.Size = UDim2.new(1, 0, 0, TITLE_HEIGHT)
		strip.BackgroundColor3 = tint
		strip.BorderSizePixel = 0
		strip.Parent = frame

		local title = makeLabel(node.Name, TITLE_TEXT, true)
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

		cards[node] = { frame = frame, strip = strip, tint = tint, invalid = #issues > 0 }

		-- A node that cannot evaluate wears a red badge over its top-right
		-- corner; hovering it explains what is missing. The badge takes no input
		-- of its own, so a grab on it still carries the node like the strip does.
		if #issues > 0 then
			local badge = Instance.new("TextLabel")
			badge.AnchorPoint = Vector2.new(0.5, 0.5)
			badge.Position = UDim2.new(1, 0, 0, 0)
			badge.Size = UDim2.fromOffset(BADGE_SIZE, BADGE_SIZE)
			badge.BackgroundColor3 = ERROR_COLOR
			badge.BorderColor3 = TITLE_TEXT
			badge.BorderSizePixel = 1
			badge.Font = Enum.Font.SourceSansBold
			badge.TextSize = 14
			badge.TextColor3 = TITLE_TEXT
			badge.Text = "!"
			badge.ZIndex = 6
			badge.Parent = frame

			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(1, 0)
			corner.Parent = badge

			local lines = { "This node is missing something it needs:" }
			for _, issue in issues do
				table.insert(lines, "\u{2022}  " .. issue)
			end
			overlay.watchForTooltip(badge, table.concat(lines, "\n"))
		end

		if not isOutput(node) then
			local produces = DataTypes.producedBy(node)
			local port = makePort(frame, Vector2.new(NODE_WIDTH, TITLE_HEIGHT + PORT_ROW / 2), true, produces)
			overlay.watchForTooltip(
				port,
				"The " .. DataTypes.label(produces)
					.. " this node produces. Drag from here onto another node to feed it."
			)

			port.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					selectOnly(node)
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
			local port = makePort(frame, Vector2.new(0, top + PORT_ROW / 2), connected, entry.dataType)

			-- What else the slot will take, said here because nothing else on the
			-- canvas offers it: the port is the colour of the one type it is, and a
			-- conversion only shows itself once a wire making one has been drawn.
			local alsoReads = ""
			for _, readable in DataTypes.readInto(entry.dataType) do
				alsoReads ..= " A " .. DataTypes.label(readable) .. " may be wired here too, and is read as one."
			end

			overlay.watchForTooltip(
				port,
				if entry.isNew
					then entry.slot.newTooltip or "An empty slot. Drop a wire here to add an input."
					else "The " .. DataTypes.label(entry.dataType)
						.. " this node reads. Drop a wire from another node's right-hand port here to change it."
						.. alsoReads
			)
		end

		addPreview(node, frame, headerHeight(node) + #ports * PORT_ROW + PADDING)

		-- The title strip and the labels are drawn over the card but take no
		-- input of their own, so a press anywhere on it arrives here; the ports
		-- are buttons and take theirs first, which is what keeps a grab at a
		-- port from also dragging the node it belongs to.
		frame.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
				return
			end

			grabKeyboard()
			pickForDrag(node)

			-- Shift may have just taken this node out of the selection, which
			-- makes the press a deselect rather than the start of a move.
			if selection[node] then
				beginNodeDrag(node, input)
			end
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
		line.BorderSizePixel = 0
		line.Parent = wireLayer

		-- A wire is the colour of what it carries, the same colour as the ports at
		-- its two ends, so what is flowing where reads off the canvas from across
		-- the room rather than by following a grey line to the port it lands on.
		-- A wire out of a node that carries nothing yet -- an empty reroute -- has
		-- no colour to be, and is the grey an unknown type is drawn in.
		--
		-- A wire that is read into something else on the way in runs from the
		-- colour of what it comes out of to the colour of what it goes into, so the
		-- conversion is visible as the one place on the canvas where a wire changes
		-- colour along its length.
		local produced = DataTypes.producedBy(source)
		local gradient = nil

		if DataTypes.converts(produced, port.dataType) then
			gradient = Instance.new("UIGradient")
			-- A gradient tints what it is on, so the line underneath is white for
			-- the two type colours to come out as themselves. The colours are set
			-- as the wire is laid out, which is what cuts the sweep to the piece of
			-- it on screen.
			line.BackgroundColor3 = Color3.new(1, 1, 1)
			gradient.Parent = line
		else
			line.BackgroundColor3 = DataTypes.color(produced)
		end

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
			disconnect(port)
		end)

		carryDrag(breaker)
		overlay.watchForTooltip(breaker, "Click to break this connection.")

		table.insert(wires, {
			line = line,
			breaker = breaker,
			from = source,
			to = target,
			index = index,
			gradient = gradient,
			castFrom = DataTypes.color(produced),
			castTo = DataTypes.color(port.dataType),
		})
	end

	local function watchGraph(nodes: { Instance })
		-- Nodes and wires can come and go from the Spreadsheet view, the Explorer,
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
			table.clear(selection)
			inputs = {}
			releasePreviewImages(cards)
			-- Nothing to show either because the place holds no graph at all, or
			-- because the one being shown has since gone.
			showMessage(if graph == nil
				then "No graph to show. Select one, or make one in the Spreadsheet view, then click Graph View."
				else "This graph is no longer in the place.")
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

		-- A node picked before the graph changed under the window may be gone
		-- now, and a selection is only ever of nodes that are on the canvas.
		for node in selection do
			if inputs[node] == nil then
				selection[node] = nil
			end
		end

		computeLayout(nodes)

		for _, node in nodes do
			makeCard(node)
		end

		-- Whatever was not drawn this time is not on the canvas: a node deleted,
		-- or one whose picture a run has since cleared.
		releasePreviewImages(cards)

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

	-- Frames a set of nodes: the zoom comes down to where they fit inside and
	-- the canvas slides to centre them. `only`, when given, frames just the nodes
	-- it holds; otherwise every node on the canvas is framed. Returns whether it
	-- found anything to frame, so a caller can fall back when it did not.
	local function frameNodes(only: { [Instance]: boolean }?): boolean
		local low, high = nil, nil

		-- The far corner of a card as well as the near one, since nodes framed by
		-- their top-left corners alone would run off the bottom and the right by
		-- the size of the last one.
		for node, position in positions do
			if only == nil or only[node] then
				local far = position + Vector2.new(nodeWidth(node), nodeHeight(node))
				low = if low == nil
					then position
					else Vector2.new(math.min(low.X, position.X), math.min(low.Y, position.Y))
				high = if high == nil
					then far
					else Vector2.new(math.max(high.X, far.X), math.max(high.Y, far.Y))
			end
		end

		if low == nil or high == nil then
			return false
		end

		-- The largest zoom the nodes fit at, with a margin left round them so the
		-- outermost are not flush against the edge. Never past actual size,
		-- however few there are: a two node graph blown up to fill the canvas is
		-- not what asking to see it means. A zero span in a direction (a lone node,
		-- or a column of them) fits at any zoom, so it does not hold the zoom in.
		local room = canvas.AbsoluteSize - Vector2.new(MARGIN, MARGIN) * 2
		local span = high - low
		local fitX = if span.X > 0 then room.X / span.X else math.huge
		local fitY = if span.Y > 0 then room.Y / span.Y else math.huge

		zoom = math.clamp(math.min(fitX, fitY, ZOOM_DEFAULT), ZOOM_MIN, ZOOM_MAX)

		-- A span too big for even the smallest stop is shown from its top-left
		-- corner rather than its middle, since that is where reading one starts.
		local scaled = span * zoom
		local corner = if scaled.X <= room.X and scaled.Y <= room.Y
			then (canvas.AbsoluteSize - scaled) / 2
			else Vector2.new(MARGIN, MARGIN)

		pan = Vector2.new(
			math.round(corner.X - low.X * zoom),
			math.round(corner.Y - low.Y * zoom)
		)
		applyView()
		return true
	end

	-- Puts the whole graph on screen. This is the way back from a pan or a zoom
	-- that has left the graph off the edge, so it has to answer for both rather
	-- than only sliding; an empty graph, having nothing to measure, slides home.
	local function frameAll()
		if not frameNodes(nil) then
			pan = Vector2.zero
			applyView()
		end
	end

	-- What the F hotkey frames: the picked nodes when any are picked, the whole
	-- graph otherwise. Falls back to the whole graph if the selection holds
	-- nothing that is currently on the canvas.
	local function frameSelection()
		if next(selection) == nil or not frameNodes(selection) then
			frameAll()
		end
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
			node:SetAttribute(POSITION_ATTRIBUTE, snapToGrid(at))

			node.Parent = graph
			created = node
		end)

		if made and created ~= nil then
			table.clear(selection)
			selection[created] = true
			rebuild()
		end
	end

	-- A whole rule in one go: the chain the template describes, wired up and
	-- registered as an output, laid out left to right from `at` the way the
	-- columns would have laid it out anyway. Building the same thing a node at a
	-- time is four nodes and four wires.
	local function addRuleTemplate(template, at: Vector2)
		if graph == nil or not graph:IsDescendantOf(game) then
			return
		end

		local made = nil

		local added = recorded("Add " .. template.label .. " rule", function()
			-- Wiring a chain into the Output registry works the columns out again
			-- for every node that has never been placed by hand.
			pinPositions()

			local _, _, nodes = RuleTemplates.add(graph, template)

			-- Placed here rather than left to the layout, since the author pointed
			-- at somewhere for this rule to go.
			local corner = snapToGrid(at)
			for index, node in nodes do
				local along = Vector2.new((index - 1) * (NODE_WIDTH + COLUMN_GAP), 0)
				node:SetAttribute(POSITION_ATTRIBUTE, snapToGrid(corner + along))
			end

			made = nodes
		end)

		if added and made ~= nil then
			table.clear(selection)
			for _, node in made do
				if node.Parent ~= nil then
					selection[node] = true
				end
			end
			rebuild()
		end
	end

	-- What the window can add, as menu items that put it at a given place: the
	-- whole rules first under their own icons, then a line, then the single nodes
	-- to build a chain out of by hand. Shared by the ribbon's Add Node button and
	-- the right-click menu, which differ in where that place comes from and in
	-- whether anything else on screen already says what the menu is for.
	local function addMenuItems(at: Vector2, heading: string?)
		local items = {}

		if heading ~= nil then
			table.insert(items, { kind = "header", text = heading })
		end

		for _, template in RuleTemplates.ordered do
			table.insert(items, {
				text = template.label,
				icon = template.icon,
				activate = function()
					addRuleTemplate(template, at)
				end,
			})
		end

		table.insert(items, { kind = "divider" })

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

		overlay.openMenuAt(windowPoint(input), addMenuItems(canvasPoint(input), "Add Node"))
	end

	local function deleteSelected()
		if graph == nil then
			return
		end

		-- The Output registry is not offered for deletion, so a selection that
		-- happens to include it deletes everything else and leaves it alone.
		local doomed = {}
		local order = {}

		for node in selection do
			if node.Parent ~= nil and not isOutput(node) then
				doomed[node] = true
				table.insert(order, node)
			end
		end

		if #order == 0 then
			return
		end

		local label = if #order == 1 then "Delete " .. order[1].Name else "Delete " .. #order .. " nodes"

		recorded(label, function()
			-- Deleting a node breaks the wires into it, which would move what is
			-- left of the chain for the same reason breaking one by hand would.
			pinPositions()

			-- Wires left pointing at a node that is gone are not harmless: the
			-- evaluator warns about an empty one and then carries on into it.
			for _, other in collectNodes(graph) do
				if not doomed[other] then
					for _, port in inputPortsOf(other) do
						if port.wire ~= nil and doomed[port.wire.Value] then
							if isOutput(other) then
								port.wire.Parent = nil
							else
								port.wire.Value = nil
							end
						end
					end
				end
			end

			for node in doomed do
				node.Parent = nil
			end
		end)

		table.clear(selection)
		rebuild()
	end

	-- Reads a keystroke off what it did to the catcher's seed, since a focused
	-- TextBox spends these keys on editing its text instead of raising them as
	-- input: a letter f (from the F shortcut) is inserted, a delete key removes
	-- one of the seed characters. Anything else is ignored, and the seed is put
	-- back for the next key either way.
	local function readKeyCatcher()
		if keyCatcher == nil or reseedingKeyCatcher then
			return
		end

		local text = keyCatcher.Text
		if string.find(string.lower(text), "f", 1, true) ~= nil then
			frameSelection()
		elseif #text < #KEY_CATCHER_SEED then
			deleteSelected()
		end

		reseedKeyCatcher()
	end

	-- Makes a graph and shows it, the same gesture the Spreadsheet view's New
	-- Graph button makes -- both go through Graphs.create, so a graph made in
	-- either window is identical, and both select it in the Explorer where it
	-- gets its real name.
	local function createGraph()
		local made
		local ok = recorded("New ScatterGraph", function()
			made = Graphs.create()
		end)

		if not ok or made == nil then
			return
		end

		Selection:Set({ made })
		self.show(made)
	end

	-- Deletes the graph on screen and drops to whatever graph is left, or to the
	-- empty view when none is. Unparented rather than destroyed so ctrl-Z brings
	-- it back, exactly as the Spreadsheet view's Delete Graph does.
	local function deleteGraph()
		if graph == nil or not graph:IsDescendantOf(game) then
			return
		end

		local removed = graph
		recorded("Delete ScatterGraph", function()
			removed.Parent = nil
		end)

		local remaining = Graphs.inPlace()[1]
		if remaining ~= nil then
			self.show(remaining)
		else
			graph = nil
			table.clear(selection)
			rebuild()
		end
	end

	-- Runs the graph on screen and nothing else. Not wrapped in a recording: a
	-- run places, promotes and destroys instances across the place and keeps a
	-- record of having done so, which is not one edit to be stepped back over,
	-- and the toolbar's Evaluate does not pretend otherwise either.
	local function evaluateCurrentGraph()
		if evaluateGraph == nil or graph == nil or not graph:IsDescendantOf(game) then
			return
		end

		evaluateGraph(graph)
	end

	-- Drops down every graph in the place, the same list the Spreadsheet view's
	-- first column shows, with the one on screen ticked. Picking another shows it.
	local function openGraphChooser()
		if graphChooser == nil then
			return
		end

		local items = {}
		local graphs = Graphs.inPlace()

		if #graphs == 0 then
			table.insert(items, { text = "No ScatterGraphs in this place." })
		else
			for _, candidate in graphs do
				local isCurrent = candidate == graph
				table.insert(items, {
					text = candidate.Name,
					icon = if isCurrent then "\u{2714}" else nil,
					activate = function()
						if candidate ~= graph then
							self.show(candidate)
						end
					end,
				})
			end
		end

		overlay.openDropdown(graphChooser, items)
	end

	-- Slides the frames the seam is drawn across to wherever the fraction now
	-- sits. Scale-based throughout, so the split holds its proportions as the
	-- window is resized.
	local function applyPaneSplit()
		if canvas == nil then
			return
		end

		local left = 1 - paramColumn
		canvas.Size = UDim2.new(left, 0, 1, -PANE_TOP)
		dividerFrame.Position = UDim2.new(left, 0, 0, PANE_TOP)
		dividerGrip.Position = UDim2.new(left, 0, 0, PANE_TOP)
		paramPane.Position = UDim2.new(left, 1, 0, PANE_TOP)
		paramPane.Size = UDim2.new(paramColumn, -1, 1, -PANE_TOP)
	end

	-- The seam brightens while it is hovered or grabbed, the cue that it moves,
	-- since a plugin cannot readily swap in a resize cursor.
	local function highlightDivider(on: boolean)
		if dividerFrame == nil then
			return
		end

		local accent =
			color(if on then Enum.StudioStyleGuideColor.LinkText else Enum.StudioStyleGuideColor.Border)
		dividerFrame.BackgroundColor3 = accent

		if dividerHandle ~= nil then
			dividerHandle.BorderColor3 = accent
			local dots =
				color(if on then Enum.StudioStyleGuideColor.LinkText else Enum.StudioStyleGuideColor.DimmedText)
			for _, dot in dividerHandle:GetChildren() do
				if dot:IsA("Frame") then
					dot.BackgroundColor3 = dots
				end
			end
		end
	end

	local function stopDividerDrag()
		if not draggingDivider then
			return
		end
		draggingDivider = false
		highlightDivider(false)
	end

	-- Turns where the pointer sits across the window into the panel's share of
	-- it, held back from either end so neither pane can be squeezed shut. The
	-- release is left to the InputEnded handlers, the same way a node drag ends;
	-- checking the button state here instead stopped the drag before it began,
	-- since a plugin widget does not keep UserInputService's mouse state current.
	local function dragDivider(input: InputObject)
		if not draggingDivider or root == nil then
			return
		end

		local width = root.AbsoluteSize.X
		if width <= 0 then
			return
		end

		local x = input.Position.X - root.AbsolutePosition.X
		paramColumn = math.clamp(1 - x / width, PARAM_COLUMN_MIN, PARAM_COLUMN_MAX)
		applyPaneSplit()
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

		-- Two ribbon rows, mirroring the Spreadsheet view: the top makes and
		-- unmakes whole graphs and chooses which one is shown, the one below adds
		-- and deletes the nodes inside it.
		local function makeRibbonRow(y: number): (Frame, Frame)
			local ribbon = Instance.new("Frame")
			ribbon.Position = UDim2.fromOffset(0, y)
			ribbon.Size = UDim2.new(1, 0, 0, RIBBON_HEIGHT)
			ribbon.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Titlebar)
			ribbon.BorderSizePixel = 0
			ribbon.Parent = rootFrame

			-- The buttons flow from the left out of this holder rather than off the
			-- row itself, so a control positioned on the row -- the graph chooser --
			-- can sit at the right without the layout dragging it into the flow. The
			-- holder is transparent and not Active, so it never swallows a click.
			local buttons = Instance.new("Frame")
			buttons.Size = UDim2.fromScale(1, 1)
			buttons.BackgroundTransparency = 1
			buttons.Parent = ribbon

			local layout = Instance.new("UIListLayout")
			layout.FillDirection = Enum.FillDirection.Horizontal
			layout.VerticalAlignment = Enum.VerticalAlignment.Center
			layout.SortOrder = Enum.SortOrder.LayoutOrder
			layout.Padding = UDim.new(0, 4)
			layout.Parent = buttons

			local padding = Instance.new("UIPadding")
			padding.PaddingLeft = UDim.new(0, PADDING)
			padding.Parent = buttons

			return ribbon, buttons
		end

		local function makeEdge(y: number)
			local edge = Instance.new("Frame")
			edge.Position = UDim2.fromOffset(0, y)
			edge.Size = UDim2.new(1, 0, 0, 1)
			edge.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Border)
			edge.BorderSizePixel = 0
			edge.Parent = rootFrame
		end

		table.clear(ribbonButtons)

		local _, graphButtons = makeRibbonRow(0)
		makeEdge(RIBBON_HEIGHT)
		local nodeRibbon, nodeButtons = makeRibbonRow(RIBBON_HEIGHT + 1)

		addRibbonButton({
			icon = "\u{1F517}",
			label = "New Graph",
			tooltip = "Adds an empty graph to ReplicatedStorage.ScatterGraphs and shows it here. Rename it in "
				.. "the Explorer: a scatter volume names the graph it uses.",
			requires = "none",
			activate = createGraph,
		}).Parent = graphButtons

		addRibbonButton({
			icon = "\u{274C}",
			label = "Delete Graph",
			tooltip = "Deletes the graph on screen and every rule in it. Volumes pointing at it place nothing "
				.. "until they are pointed somewhere else. Undo brings it back.",
			requires = "graph",
			activate = deleteGraph,
		}).Parent = graphButtons

		addRibbonButton({
			icon = "\u{1F332}",
			label = "Evaluate Graph",
			tooltip = "Places the graph on screen, in every enabled volume pointed at it. Only this graph is "
				.. "run: what other graphs have placed is left standing, and their record of it is left "
				.. "alone. The toolbar's Evaluate does the whole place at once.",
			requires = "graph",
			activate = evaluateCurrentGraph,
		}).Parent = graphButtons

		local addButton
		addButton = addRibbonButton({
			icon = "\u{2795}",
			label = "Add Node",
			tooltip = "Adds a whole rule, or a single unwired node, in the middle of the view. Right-click the "
				.. "canvas to add one where the pointer is instead. Drag from a node's right-hand port to feed "
				.. "something with it.",
			requires = "graph",
			activate = function()
				-- No heading: the button it hangs from is already labelled.
				overlay.openDropdown(addButton, addMenuItems(viewMiddle()))
			end,
		})
		addButton.Parent = nodeButtons

		addRibbonButton({
			icon = "\u{274C}",
			label = "Delete Node",
			tooltip = "Deletes every selected node and empties the wires that fed from them. The nodes feeding "
				.. "them stay where they are, and an Output in the selection is left alone.",
			requires = "node",
			activate = deleteSelected,
		}).Parent = nodeButtons

		addRibbonButton({
			icon = "\u{1F50D}",
			label = "Frame All",
			tooltip = "Zooms out far enough to show every node and centres them, for when panning or zooming "
				.. "has left the graph off screen. It never zooms in past actual size.",
			requires = "graph",
			activate = frameAll,
		}).Parent = nodeButtons

		-- The graph chooser, right-aligned on the node row so it lines up with the
		-- window's edge the way the Spreadsheet view's list column does. Sits on
		-- the row rather than in its button holder, so the layout leaves it be. It
		-- is added after the holder, so it draws on top and takes the click.
		graphChooser = Instance.new("TextButton")
		graphChooser.AnchorPoint = Vector2.new(1, 0.5)
		graphChooser.Position = UDim2.new(1, -PADDING, 0.5, 0)
		graphChooser.Size = UDim2.new(0, 200, 0, BUTTON_HEIGHT)
		graphChooser.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Button)
		graphChooser.BorderSizePixel = 0
		graphChooser.Font = Enum.Font.SourceSans
		graphChooser.TextSize = 14
		graphChooser.TextColor3 = color(Enum.StudioStyleGuideColor.ButtonText)
		graphChooser.TextXAlignment = Enum.TextXAlignment.Left
		graphChooser.TextTruncate = Enum.TextTruncate.AtEnd
		graphChooser.Text = ""

		local chooserPadding = Instance.new("UIPadding")
		chooserPadding.PaddingLeft = UDim.new(0, PADDING)
		chooserPadding.PaddingRight = UDim.new(0, PADDING)
		chooserPadding.Parent = graphChooser

		graphChooser.Parent = nodeRibbon
		graphChooser.Activated:Connect(openGraphChooser)
		overlay.watchForTooltip(
			graphChooser,
			"Every ScatterGraph in the place -- the same list the Spreadsheet view's first column shows. Pick "
				.. "one to show it here."
		)

		local paneTop = (RIBBON_HEIGHT + 1) * 2
		makeEdge(paneTop - 1)

		canvas = Instance.new("Frame")
		canvas.Position = UDim2.fromOffset(0, paneTop)
		canvas.Size = UDim2.new(1 - paramColumn, 0, 1, -paneTop)
		canvas.BackgroundColor3 = color(Enum.StudioStyleGuideColor.ViewPortBackground)
		canvas.BorderSizePixel = 0
		-- Everything on the canvas is positioned in graph pixels and may sit
		-- well outside the visible corner of it. This holds the cards and the
		-- box to the canvas; the wires cut themselves to it, being turned frames,
		-- which clipping does not reach.
		canvas.ClipsDescendants = true
		canvas.Parent = rootFrame

		-- The canvas grows and shrinks with the window, and so do how much of any
		-- given wire fits inside it and how far the grid has to reach.
		canvas:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			refreshGrid()
			layoutWires()
		end)

		-- Under everything else on the canvas, and drawn by repeating one tile
		-- rather than by a frame per dot, which at ten pixels apart would be
		-- thousands of them.
		gridLayer = Instance.new("ImageLabel")
		gridLayer.BackgroundTransparency = 1
		gridLayer.BorderSizePixel = 0
		gridLayer.ScaleType = Enum.ScaleType.Tile
		-- Zooming stretches the tile, and a dot one pixel across is a smear once
		-- it has been filtered; this keeps it a dot.
		gridLayer.ResampleMode = Enum.ResamplerMode.Pixelated
		gridLayer.ZIndex = 0
		gridLayer.Visible = false
		gridLayer.Parent = canvas

		-- The interface is rebuilt on a theme change, and the tile the old one was
		-- drawn from went with it.
		gridTileSize = nil

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
				grabKeyboard()
				beginMarquee(input)
			end
		end)

		-- The canvas holds the keyboard for as long as the pointer is over it, so
		-- the shortcuts are armed while the author works there and the keyboard is
		-- handed back the moment the pointer moves off it -- onto the parameters,
		-- say, where a field then takes it. This is watched on the canvas frame
		-- rather than the background button so that moving onto a node card, which
		-- sits over the background, still counts as being on the canvas. Grabbing
		-- is refused while a field is focused (see grabKeyboard), so passing over
		-- the canvas while editing a note does not snatch the keys from the note.
		canvas.MouseEnter:Connect(function()
			pointerOverCanvas = true
			grabKeyboard()
		end)
		canvas.MouseLeave:Connect(function()
			pointerOverCanvas = false
			releaseKeyboard()
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
		divider.Size = UDim2.new(0, 1, 1, -paneTop)
		divider.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Border)
		divider.BorderSizePixel = 0
		divider.Parent = rootFrame
		dividerFrame = divider

		local pane = Instance.new("Frame")
		pane.BackgroundTransparency = 1
		pane.Parent = rootFrame
		paramPane = pane

		-- The hairline is too thin to hit, so a wider invisible strip straddles it
		-- and takes the drag. Centred on the line so half of it laps onto each
		-- side, and above the canvas background so a press starts a resize rather
		-- than a marquee.
		local grip = Instance.new("TextButton")
		grip.AnchorPoint = Vector2.new(0.5, 0)
		grip.Size = UDim2.new(0, 12, 1, -paneTop)
		grip.BackgroundTransparency = 1
		grip.Text = ""
		grip.AutoButtonColor = false
		grip.ZIndex = 5
		grip.Parent = rootFrame
		dividerGrip = grip

		-- A raised pill of three dots, centred on the line, so the seam reads as
		-- something to grab rather than just an edge between two panes. A child of
		-- the grip, so it rides along as the seam moves, and not Active, so the
		-- grip beneath it still takes the press.
		local handle = Instance.new("Frame")
		handle.AnchorPoint = Vector2.new(0.5, 0.5)
		handle.Position = UDim2.new(0.5, 0, 0.5, 0)
		handle.Size = UDim2.fromOffset(7, 34)
		handle.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Button)
		handle.BorderColor3 = color(Enum.StudioStyleGuideColor.Border)
		handle.BorderSizePixel = 1
		handle.ZIndex = 6
		handle.Parent = grip
		dividerHandle = handle

		local handleCorner = Instance.new("UICorner")
		handleCorner.CornerRadius = UDim.new(0, 3)
		handleCorner.Parent = handle

		local dotLayout = Instance.new("UIListLayout")
		dotLayout.FillDirection = Enum.FillDirection.Vertical
		dotLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		dotLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		dotLayout.SortOrder = Enum.SortOrder.LayoutOrder
		dotLayout.Padding = UDim.new(0, 3)
		dotLayout.Parent = handle

		for i = 1, 3 do
			local dot = Instance.new("Frame")
			dot.Size = UDim2.fromOffset(3, 3)
			dot.BackgroundColor3 = color(Enum.StudioStyleGuideColor.DimmedText)
			dot.BorderSizePixel = 0
			dot.LayoutOrder = i
			dot.ZIndex = 7
			dot.Parent = handle

			local dotCorner = Instance.new("UICorner")
			dotCorner.CornerRadius = UDim.new(1, 0)
			dotCorner.Parent = dot
		end

		grip.MouseEnter:Connect(function()
			highlightDivider(true)
		end)
		grip.MouseLeave:Connect(function()
			if not draggingDivider then
				highlightDivider(false)
			end
		end)
		grip.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				draggingDivider = true
				highlightDivider(true)
			end
		end)

		-- Movement and release come from the GUI objects the pointer is actually
		-- over, not from UserInputService, which a plugin widget does not feed:
		-- the grip while the seam keeps up with the pointer, and the canvas or the
		-- root frame when a quick drag outruns it. dragDivider ignores a move made
		-- when no drag is under way, so these are harmless when idle.
		local function onDividerMove(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				dragDivider(input)
			end
		end
		local function onDividerRelease(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				stopDividerDrag()
			end
		end

		grip.InputChanged:Connect(onDividerMove)
		grip.InputEnded:Connect(onDividerRelease)
		background.InputChanged:Connect(onDividerMove)
		background.InputEnded:Connect(onDividerRelease)
		rootFrame.InputChanged:Connect(onDividerMove)
		rootFrame.InputEnded:Connect(onDividerRelease)

		-- Sizes and places all of the above from the fraction it currently holds.
		applyPaneSplit()

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

		-- A parameter field reports its focus so the catcher can step aside for it
		-- (see setFieldFocused); without this the catcher, being a focused text box
		-- that eats every key, would swallow what is typed into the field.
		inspector.onFieldFocus = setFieldFocused

		-- The keyboard-focus holder behind the view's shortcuts (see the upvalue).
		-- Parked off the top-left corner so its caret never shows, and invisible
		-- besides. Focus is set in code, so where it sits does not matter to it.
		local catcher = Instance.new("TextBox")
		keyCatcher = catcher
		catcher.Position = UDim2.fromOffset(-100, -100)
		catcher.Size = UDim2.fromOffset(1, 1)
		catcher.BackgroundTransparency = 1
		catcher.TextTransparency = 1
		catcher.ClearTextOnFocus = false
		catcher.MultiLine = false
		catcher.TextEditable = true
		catcher.ZIndex = 0
		catcher.Parent = rootFrame
		reseedKeyCatcher()

		-- Each key the author presses while the view holds focus edits this text.
		-- The handler reads which key it was from how the text changed, then puts
		-- the seed back; this is what stands in for the InputBegan a focused
		-- TextBox does not raise for these keys. The seed is reset before every
		-- grab rather than on focus lost, so nothing sets the catcher's text (and
		-- risks stealing focus back to it) while a field is being edited.
		catcher:GetPropertyChangedSignal("Text"):Connect(readKeyCatcher)

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

	-- A backstop for the divider, matching the one above: a release out over the
	-- 3D view or another window, which the grip and the frames never see, still
	-- ends the drag. Movement is read from those frames rather than from here,
	-- since a plugin widget does not feed UserInputService its pointer moves.
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			stopDividerDrag()
		end
	end)

	-- The view takes the keyboard when the author turns to the canvas -- hovering
	-- it or clicking in it (see background and the cards) -- rather than the
	-- moment the window comes to the front. Grabbing it on WindowFocused stole
	-- focus out of a parameter field the instant it was clicked, since focusing a
	-- field is itself what brings the window forward, leaving the field
	-- uneditable. Hover and click arm the shortcuts before a node is ever picked,
	-- so nothing is lost by waiting for them.
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

	-- Which graph the toolbar button opens. The selection is asked first, so
	-- picking a graph out and clicking the button always shows that one; with
	-- nothing selected the window comes back showing what it showed before, and
	-- a window that has yet to show anything takes the first graph in the place.
	local function graphToShow(): Instance?
		local selected = Graphs.selected()
		if selected ~= nil then
			return selected
		end

		if graph ~= nil and graph:IsDescendantOf(game) then
			return graph
		end

		return Graphs.inPlace()[1]
	end

	function self.show(newGraph: Instance)
		local changed = newGraph ~= graph

		graph = newGraph

		if changed then
			table.clear(selection)
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

	function self.attach(button: PluginToolbarButton)
		button.Click:Connect(function()
			if widget.Enabled then
				widget.Enabled = false
				return
			end

			local wanted = graphToShow()
			if wanted ~= nil then
				self.show(wanted)
			else
				-- Nothing to show, but the window still opens: it is where the
				-- reason why is written.
				widget.Enabled = true
			end
		end)

		widget:GetPropertyChangedSignal("Enabled"):Connect(function()
			button:SetActive(widget.Enabled)
		end)

		button:SetActive(widget.Enabled)

		-- Studio restores whether the window was open, which can put it up before
		-- anything has chosen a graph for it.
		if widget.Enabled then
			local wanted = graphToShow()
			if wanted ~= nil then
				self.show(wanted)
			elseif root == nil then
				buildInterface()
				rebuild()
			end
		end
	end

	return self
end

-- The button owns the window: clicking it opens the graph the selection names,
-- or closes the window if it is already up.
function GraphView.install(pluginRef: Plugin, button: PluginToolbarButton, evaluateGraph: ((Instance) -> ())?)
	if view == nil then
		view = create(pluginRef, evaluateGraph)
	end

	view.attach(button)
end

return GraphView
