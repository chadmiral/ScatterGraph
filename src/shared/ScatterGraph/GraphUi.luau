--[[
	GraphUi

	What the plugin's windows are built out of, kept in one place so the
	Spreadsheet view and the Graph view look and behave alike.

	Roblox provides neither a tooltip nor a dropdown, so both are drawn here as
	panels floated over the window that asked for one. An Overlay owns that pair
	for a single window, which is what keeps only one of each on screen at a
	time and gives every window one thing to tear down when it rebuilds.

	Also here: Studio's theme colours, the way a value is spelled out for
	display, and `recorded`, which every edit to a graph goes through so ctrl-Z
	undoes it like any other Studio change.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")

local GraphUi = {}

GraphUi.PADDING = 6
GraphUi.ROW_HEIGHT = 22
GraphUi.SECTION_HEIGHT = 24
GraphUi.HEADER_HEIGHT = 26
GraphUi.RIBBON_HEIGHT = 30
GraphUi.BUTTON_HEIGHT = 22
-- How much of an attribute row the name takes, leaving the rest to the editor.
GraphUi.NAME_COLUMN = 0.45
GraphUi.TOOLTIP_WIDTH = 280
-- Long enough that sweeping the pointer across a panel does not flash a tooltip
-- at everything on the way past.
GraphUi.TOOLTIP_DELAY = 0.4

local PADDING = GraphUi.PADDING
local ROW_HEIGHT = GraphUi.ROW_HEIGHT
local SECTION_HEIGHT = GraphUi.SECTION_HEIGHT
local TOOLTIP_WIDTH = GraphUi.TOOLTIP_WIDTH
local TOOLTIP_DELAY = GraphUi.TOOLTIP_DELAY
-- What a menu opened at the pointer is given to work with, having no button
-- underneath it to take its width from.
local MENU_WIDTH = 168
-- A divider is a line with a little air either side of it, so the groups it
-- separates read as groups rather than as a list with a stripe through it.
local DIVIDER_HEIGHT = 7

-- How tall a row is, by what the row is: a heading over a group, a line between
-- two groups, or something to pick. A list's height is the sum of these rather
-- than its item count times a row, now that not every row is a row.
local function rowHeight(item): number
	if item.kind == "header" then
		return SECTION_HEIGHT
	elseif item.kind == "divider" then
		return DIVIDER_HEIGHT
	end

	return ROW_HEIGHT
end

local function listHeight(items): number
	local height = 0

	for _, item in items do
		height += rowHeight(item)
	end

	return height
end

function GraphUi.color(guideColor: Enum.StudioStyleGuideColor, modifier: Enum.StudioStyleGuideModifier?): Color3
	return settings().Studio.Theme:GetColor(guideColor, modifier)
end

function GraphUi.indent(gui: GuiObject)
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, PADDING)
	padding.Parent = gui
end

function GraphUi.makeLabel(text: string, textColor: Color3, bold: boolean): TextLabel
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

-- Values shown as-is where tostring already reads well, and spelled out where it
-- does not: a NumberSequence stringifies to something unreadable, and an
-- Instance's name alone is ambiguous across a graph.
function GraphUi.formatValue(value: any): string
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
		return string.format(
			"#%02X%02X%02X",
			math.round(value.R * 255),
			math.round(value.G * 255),
			math.round(value.B * 255)
		)
	elseif valueType == "Vector2" then
		return string.format("%g, %g", value.X, value.Y)
	elseif valueType == "Vector3" then
		return string.format("%g, %g, %g", value.X, value.Y, value.Z)
	elseif valueType == "Instance" then
		return value:GetFullName()
	end

	return tostring(value)
end

-- Studio's undo stack only records what happens between these calls, so every
-- edit either window makes has to run inside one.
--
-- Note for anything that removes an instance: unparent it rather than calling
-- Destroy. Destroy locks the Parent property, and the undo that follows then
-- cannot put the instance back.
function GraphUi.recorded(name: string, edit: () -> ()): boolean
	local recording = ChangeHistoryService:TryBeginRecording(name)
	local ok, err = pcall(edit)

	if recording ~= nil then
		ChangeHistoryService:FinishRecording(
			recording,
			if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
		)
	end

	if not ok then
		warn("ScatterGraph: " .. name .. " failed -- " .. tostring(err))
	end

	return ok
end

-- A wire is a child ObjectValue of a given name: how a node points at another
-- node, or at the geometry it places.
function GraphUi.findWire(node: Instance, name: string): ObjectValue?
	local wire = node:FindFirstChild(name)
	return if wire ~= nil and wire:IsA("ObjectValue") then wire else nil
end

-- The floating panels for one window. `attach` hands it the frame they are
-- parented to and positioned within, which a window calls again every time it
-- rebuilds that frame.
function GraphUi.newOverlay()
	local overlay = {}

	local root: GuiObject? = nil
	local tooltip: Frame? = nil
	-- Tells a tooltip still waiting out its delay whether the pointer is still
	-- where it was when the wait started.
	local tooltipToken = 0
	local dropdown: GuiObject? = nil

	function overlay.attach(newRoot: GuiObject)
		root = newRoot
		tooltip = nil
		dropdown = nil
	end

	function overlay.hideTooltip()
		tooltipToken += 1

		if tooltip ~= nil then
			tooltip:Destroy()
			tooltip = nil
		end
	end

	-- Pinned to the thing that asked for it, and sitting below that rather than
	-- under the pointer: a frame beneath the pointer takes the hover from
	-- whatever raised it, and the two then flicker against each other.
	function overlay.showTooltip(anchor: GuiObject, text: string)
		overlay.hideTooltip()

		if root == nil then
			return
		end

		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromOffset(TOOLTIP_WIDTH, 0)
		frame.AutomaticSize = Enum.AutomaticSize.Y
		frame.BackgroundColor3 = GraphUi.color(Enum.StudioStyleGuideColor.Titlebar)
		frame.BorderColor3 = GraphUi.color(Enum.StudioStyleGuideColor.Border)
		frame.ZIndex = 20
		tooltip = frame

		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, PADDING)
		padding.PaddingRight = UDim.new(0, PADDING)
		padding.PaddingTop = UDim.new(0, 4)
		padding.PaddingBottom = UDim.new(0, 4)
		padding.Parent = frame

		local label = GraphUi.makeLabel(text, GraphUi.color(Enum.StudioStyleGuideColor.MainText), false)
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
		-- decision to hang the panel below the anchor or above it is made again
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
	-- has moved on or the anchor has been rebuilt in the meantime.
	function overlay.watchForTooltip(anchor: GuiObject, text: string)
		anchor.MouseEnter:Connect(function()
			tooltipToken += 1
			local token = tooltipToken

			task.delay(TOOLTIP_DELAY, function()
				if token == tooltipToken and anchor.Parent ~= nil then
					overlay.showTooltip(anchor, text)
				end
			end)
		end)

		anchor.MouseLeave:Connect(overlay.hideTooltip)
	end

	function overlay.closeDropdown()
		if dropdown ~= nil then
			dropdown:Destroy()
			dropdown = nil
		end
	end

	-- A list floated over the window on a full-window backdrop that dismisses it
	-- when clicked, at a place already worked out. Items are
	-- { text, activate, enabled, icon, kind }; an item without an action, or with
	-- enabled false, is a line of text the menu shows but does not offer.
	--
	-- A kind of "header" is a heading over the rows below it and a "divider" is a
	-- line between two groups of them; neither is pickable. An icon is drawn
	-- ahead of the text the way the ribbon draws one, which is what marks a row
	-- out as doing more than the plain rows around it.
	local function openList(items, at: Vector2, width: number)
		overlay.closeDropdown()

		if root == nil then
			return
		end

		local backdrop = Instance.new("TextButton")
		backdrop.Size = UDim2.fromScale(1, 1)
		backdrop.BackgroundTransparency = 1
		backdrop.Text = ""
		backdrop.ZIndex = 10
		backdrop.Parent = root
		backdrop.Activated:Connect(overlay.closeDropdown)
		dropdown = backdrop

		-- A right-click dismisses it as well, since the gesture that opens a
		-- menu at the pointer is the one most likely to be aimed elsewhere next.
		backdrop.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				overlay.closeDropdown()
			end
		end)

		local list = Instance.new("Frame")
		list.Size = UDim2.fromOffset(width, listHeight(items))
		list.Position = UDim2.fromOffset(at.X, at.Y)
		list.BackgroundColor3 = GraphUi.color(Enum.StudioStyleGuideColor.MainBackground)
		list.BorderColor3 = GraphUi.color(Enum.StudioStyleGuideColor.Border)
		list.ZIndex = 11
		list.Parent = backdrop

		local layout = Instance.new("UIListLayout")
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = list

		for index, item in items do
			if item.kind == "header" then
				local header = GraphUi.makeLabel(item.text, GraphUi.color(Enum.StudioStyleGuideColor.BrightText), true)
				header.Size = UDim2.new(1, 0, 0, SECTION_HEIGHT)
				header.LayoutOrder = index
				header.BackgroundColor3 = GraphUi.color(Enum.StudioStyleGuideColor.Titlebar)
				header.BackgroundTransparency = 0
				header.BorderSizePixel = 0
				header.ZIndex = 11
				GraphUi.indent(header)
				header.Parent = list
			elseif item.kind == "divider" then
				-- The line sits in a taller empty row rather than being the row,
				-- which is where the air either side of it comes from.
				local gap = Instance.new("Frame")
				gap.Size = UDim2.new(1, 0, 0, DIVIDER_HEIGHT)
				gap.LayoutOrder = index
				gap.BackgroundTransparency = 1
				gap.BorderSizePixel = 0
				gap.ZIndex = 11
				gap.Parent = list

				local line = Instance.new("Frame")
				line.Position = UDim2.fromOffset(0, math.floor(DIVIDER_HEIGHT / 2))
				line.Size = UDim2.new(1, 0, 0, 1)
				line.BackgroundColor3 = GraphUi.color(Enum.StudioStyleGuideColor.Border)
				line.BorderSizePixel = 0
				line.ZIndex = 11
				line.Parent = gap
			else
				local enabled = item.activate ~= nil and item.enabled ~= false

				local button = Instance.new("TextButton")
				button.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
				button.LayoutOrder = index
				button.BackgroundColor3 = GraphUi.color(Enum.StudioStyleGuideColor.TableItem)
				button.BorderSizePixel = 0
				button.AutoButtonColor = enabled
				button.Font = Enum.Font.SourceSans
				button.TextSize = 14
				button.TextColor3 = GraphUi.color(
					if enabled then Enum.StudioStyleGuideColor.MainText else Enum.StudioStyleGuideColor.DimmedText
				)
				button.TextXAlignment = Enum.TextXAlignment.Left
				button.TextTruncate = Enum.TextTruncate.AtEnd
				button.Text = if item.icon ~= nil then item.icon .. "  " .. item.text else item.text
				button.ZIndex = 11
				GraphUi.indent(button)
				button.Parent = list

				button.Activated:Connect(function()
					if not enabled then
						return
					end

					overlay.closeDropdown()
					item.activate()
				end)
			end
		end
	end

	-- Hung below the button that asked for it, and as wide as that button so the
	-- two read as one control.
	function overlay.openDropdown(anchor: GuiObject, items)
		if root == nil then
			return
		end

		local height = listHeight(items)
		local offset = anchor.AbsolutePosition - root.AbsolutePosition
		local below = offset.Y + anchor.AbsoluteSize.Y

		-- Flips above the anchor when there is no room beneath it, which in a
		-- short window there often is not.
		local y = if below + height <= root.AbsoluteSize.Y then below else math.max(0, offset.Y - height)

		openList(items, Vector2.new(offset.X, y), math.max(anchor.AbsoluteSize.X, 120))
	end

	-- A menu at a point rather than at a control: what a right-click opens. `at`
	-- is in the window's own pixels.
	function overlay.openMenuAt(at: Vector2, items)
		if root == nil then
			return
		end

		local height = listHeight(items)
		local size = root.AbsoluteSize

		-- Falls down and to the right of the pointer, and the other way at the
		-- edges of the window, so the whole menu is always on screen.
		local x = if at.X + MENU_WIDTH <= size.X then at.X else math.max(0, at.X - MENU_WIDTH)
		local y = if at.Y + height <= size.Y then at.Y else math.max(0, at.Y - height)

		openList(items, Vector2.new(x, y), MENU_WIDTH)
	end

	return overlay
end

return GraphUi
