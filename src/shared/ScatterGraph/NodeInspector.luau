--[[
	NodeInspector

	The attribute panel: every value of every node it is given, as a row with an
	editor suited to the kind of value it is. AttributeSchema decides which
	editor each one gets and what the row says on hover. Two values are too big
	for a row and open a window of their own: a sequence in the SequenceEditor,
	and a published asset id in the PackagesBrowser.

	A row's value is usually an attribute, but it can also be a child ObjectValue
	-- that is how PlaceGeometryOnPoints points at the geometry it places -- and
	both kinds read and write the same way from here.

	Both windows use one of these. The Spreadsheet view shows the chain of nodes
	feeding one output; the Graph view shows whichever node is selected on the
	canvas. What to show is given as a function rather than a list, because a
	rewire changes which nodes belong on screen and the panel rebuilds itself
	whenever anything it is watching changes.
]]

local Selection = game:GetService("Selection")

local AttributeSchema = require(script.Parent:WaitForChild("AttributeSchema"))
local GraphUi = require(script.Parent:WaitForChild("GraphUi"))
local PackagesBrowser = require(script.Parent:WaitForChild("PackagesBrowser"))
local SequenceEditor = require(script.Parent:WaitForChild("SequenceEditor"))

local NodeInspector = {}

local PADDING = GraphUi.PADDING
local ROW_HEIGHT = GraphUi.ROW_HEIGHT
local SECTION_HEIGHT = GraphUi.SECTION_HEIGHT
local NAME_COLUMN = GraphUi.NAME_COLUMN

local color = GraphUi.color
local indent = GraphUi.indent
local makeLabel = GraphUi.makeLabel
local formatValue = GraphUi.formatValue
local recorded = GraphUi.recorded
local findWire = GraphUi.findWire

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

-- pluginRef is for the sequence popout; overlay hosts the tooltips and menus
-- the rows raise.
function NodeInspector.new(pluginRef: Plugin, overlay)
	local inspector = {}

	local list: ScrollingFrame? = nil
	-- A value shown here can also be changed from the Properties pane or by an
	-- undo, so the panel listens to the nodes it is showing to stay current.
	local connections: { RBXScriptConnection } = {}
	local provider: (() -> { Instance })? = nil
	local emptyMessage: string? = nil

	-- Called after something the panel was watching changed, for a host that
	-- draws the same graph elsewhere and needs to keep up.
	inspector.onChanged = nil

	local render

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

	-- `asField` dresses the button as one of the input boxes above instead of a
	-- button, for a value that is still typed in spirit but is picked from a
	-- window rather than typed into the row.
	local function makeValueButton(text: string, unset: boolean, asField: boolean?): TextButton
		local button = Instance.new("TextButton")
		button.Position = UDim2.fromOffset(0, 2)
		button.Size = UDim2.new(1, 0, 1, -4)
		button.BackgroundColor3 = color(
			if asField
				then Enum.StudioStyleGuideColor.InputFieldBackground
				else Enum.StudioStyleGuideColor.Button
		)
		button.BorderColor3 = color(
			if asField then Enum.StudioStyleGuideColor.InputFieldBorder else Enum.StudioStyleGuideColor.ButtonBorder
		)
		button.Font = Enum.Font.SourceSans
		button.TextSize = 14
		button.TextColor3 = color(
			if unset
				then Enum.StudioStyleGuideColor.DimmedText
				elseif asField then Enum.StudioStyleGuideColor.MainText
				else Enum.StudioStyleGuideColor.ButtonText
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

	-- A published asset id, picked from the Packages browser rather than typed:
	-- an id is fourteen digits nobody carries in their head, and the browser
	-- knows the names. It still looks like the field it replaces, since it is
	-- the same value being set, and the browser's search box takes an id for
	-- when there is one to hand.
	local function makePackageEditor(node: Instance, descriptor, value: any): Frame
		local container = makeEditorContainer()

		local function caption(name: string?): string
			if value == nil then
				return "(not set)"
			end
			return if name ~= nil then name .. "  (" .. string.format("%d", value) .. ")" else string.format("%d", value)
		end

		local button = makeValueButton(caption(PackagesBrowser.nameFor(value)), value == nil, true)
		button.Parent = container

		-- The name behind an id is a web lookup, so the field shows the id now and
		-- says what it is once that lands -- if this row is still on screen by
		-- then, since the panel rebuilds on every change.
		if value ~= nil then
			PackagesBrowser.resolveName(value, function(name)
				if button.Parent ~= nil then
					button.Text = caption(name)
				end
			end)
		end

		button.Activated:Connect(function()
			PackagesBrowser.open(pluginRef, node.Name .. "." .. descriptor.name, value, function(id)
				commitValue(node, descriptor, id)
			end)
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
			overlay.openDropdown(button, items)
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

			overlay.openDropdown(button, items)
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
		if descriptor.browser == "packages" then
			return makePackageEditor(node, descriptor, value)
		elseif descriptor.kind == "number" or descriptor.kind == "string" then
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
			overlay.watchForTooltip(nameLabel, descriptor.description)
		end

		local editor = makeEditor(node, descriptor, readDescriptorValue(node, descriptor))
		if superseded then
			local box = editor:FindFirstChildOfClass("TextBox")
			local button = editor:FindFirstChildOfClass("TextButton")

			if box ~= nil then
				box.PlaceholderText = "(" .. descriptor.supersededBy .. " is set)"
			elseif button ~= nil and button.Text == "(not set)" then
				-- A field that opens a picker has no placeholder to say it with.
				button.Text = "(" .. descriptor.supersededBy .. " is set)"
			end
		end
		editor.Parent = row

		row.Parent = list
	end

	-- Full-width prose, for the cases where there are no attributes to lay out in
	-- two columns.
	local function addMessage(text: string, order: number)
		local label = makeLabel(text, color(Enum.StudioStyleGuideColor.DimmedText), false)
		label.Size = UDim2.new(1, -PADDING * 2, 0, ROW_HEIGHT)
		label.LayoutOrder = order
		label.TextTruncate = Enum.TextTruncate.None
		label.TextWrapped = true
		label.AutomaticSize = Enum.AutomaticSize.Y
		indent(label)
		label.Parent = list
	end

	local function addSection(node: Instance, order: number)
		local nodeType = node:GetAttribute("NodeType")

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
		section.Parent = list

		-- Reveals the node in the Explorer and the Properties pane, for the parts
		-- of it this panel does not show.
		section.Activated:Connect(function()
			Selection:Set({ node })
		end)

		overlay.watchForTooltip(
			section,
			"Click to select this node in the Explorer, where the Properties pane shows what this window "
				.. "leaves out."
		)
	end

	local function teardown()
		overlay.hideTooltip()
		overlay.closeDropdown()

		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)

		if list == nil then
			return
		end

		for _, child in list:GetChildren() do
			if not child:IsA("UIListLayout") then
				child:Destroy()
			end
		end
	end

	-- A row's value may live in an attribute or in a child ObjectValue, and
	-- either can be changed from here, from the Properties pane, or by an undo,
	-- so the panel watches both. Rewiring also changes which nodes belong on
	-- screen at all, which is why the whole panel is rebuilt rather than the
	-- one row.
	local function watch(node: Instance)
		local function rebuild()
			render()

			if inspector.onChanged ~= nil then
				inspector.onChanged()
			end
		end

		table.insert(connections, node.AttributeChanged:Connect(rebuild))
		table.insert(connections, node.ChildAdded:Connect(rebuild))
		table.insert(connections, node.ChildRemoved:Connect(rebuild))

		for _, child in node:GetChildren() do
			if child:IsA("ObjectValue") then
				table.insert(connections, child.Changed:Connect(rebuild))
			end
		end
	end

	render = function()
		teardown()

		if list == nil or provider == nil then
			return
		end

		local nodes = provider()

		if #nodes == 0 then
			if emptyMessage ~= nil then
				addMessage(emptyMessage, 0)
			end
			return
		end

		local order = 0
		for _, node in nodes do
			order += 1
			addSection(node, order)

			local rows = AttributeSchema.rowsFor(node)
			if #rows == 0 then
				order += 1
				addMessage("(no attributes)", order)
			end

			for _, descriptor in rows do
				order += 1
				addAttributeRow(node, descriptor, order)
			end

			watch(node)
		end
	end

	-- The ScrollingFrame rows go into. Set again whenever the window rebuilds
	-- its interface, since the old frame goes with it.
	function inspector.setList(scroll: ScrollingFrame)
		list = scroll
	end

	-- What to show, as a function so that a rebuild after a rewire asks again
	-- rather than redrawing the nodes that used to be there.
	function inspector.show(nodesProvider: () -> { Instance }, message: string?)
		provider = nodesProvider
		emptyMessage = message
		render()
	end

	function inspector.clear()
		provider = nil
		emptyMessage = nil
		teardown()
	end

	return inspector
end

return NodeInspector
