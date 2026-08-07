--[[
	PackagesBrowser

	A picker for a published asset id, opened from the Asset field: the packages
	kept in the palette folder, listed by name, with a search box over them.

	The palette is a folder at ReplicatedStorage.ScatterGraphPalette where an
	author gathers the assets a graph draws from. Every package there carries a
	PackageLink naming the package it came from, so the browser walks that folder,
	takes the id off each PackageLink, and lists them all -- the palette is the
	curated set on purpose, so nothing is filtered out.

	A name is a web lookup apiece: GetProductInfo turns an id into its published
	name without going near HttpService, which refuses every Roblox domain. Names
	are read one at a time in the background with rows appearing as they land --
	each row shows the palette instance's own name until then -- and kept for the
	rest of the session, so a second visit to the browser is immediate. The
	search box takes an id as well as a name, which keeps a known id typeable now
	that the field itself opens this window instead of a caret.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GraphUi = require(script.Parent:WaitForChild("GraphUi"))

local PackagesBrowser = {}

-- The folder the palette lives in, under ReplicatedStorage.
local PALETTE_NAME = "ScatterGraphPalette"

local PADDING = GraphUi.PADDING
local ROW_HEIGHT = GraphUi.ROW_HEIGHT
local HEADER_HEIGHT = GraphUi.HEADER_HEIGHT

local color = GraphUi.color
local indent = GraphUi.indent
local makeLabel = GraphUi.makeLabel

local SEARCH_LABEL_WIDTH = 52
local STATUS_HEIGHT = 20
-- How much of a row the id and the count of copies take, leaving the rest to the
-- name.
local ID_COLUMN = 0.4
-- How many names to read before showing what has arrived. Every one is a web
-- call, and redrawing the list after each would rebuild every row already in it.
local NAMES_PER_REFRESH = 4
-- How long a run of digits has to be before it reads as an id someone means to
-- use rather than a few characters typed to narrow the list down.
local ID_DIGITS = 8

-- What GetProductInfo said about an id, by id, kept for the session: the answer
-- cannot change while Studio is open, and it costs a web call to ask.
local details = {}

local widget = nil
local ui = nil
local state = nil
-- Bumped to abandon a scan whose window has been closed, reopened, or asked for
-- a different place's packages since.
local scanToken = 0

local render

-- Every package in the palette folder, by id, with the name of an instance it
-- is attached to and how many copies there are. The instance name is a stand-in
-- until the published name arrives, and worth showing on its own: it is what an
-- author sees in the Explorer. An empty result means the folder is missing or
-- holds nothing that is a package.
local function scanPalette()
	local byId = {}
	local found = {}

	local palette = ReplicatedStorage:FindFirstChild(PALETTE_NAME)
	if palette == nil then
		return found
	end

	for _, thing in palette:GetDescendants() do
		if thing:IsA("PackageLink") then
			local id = tonumber(string.match(tostring(thing.PackageId), "%d+"))

			if id ~= nil then
				local entry = byId[id]

				if entry == nil then
					local owner = thing.Parent
					entry = { id = id, copies = 0, sample = if owner ~= nil then owner.Name else "?" }
					byId[id] = entry
					table.insert(found, entry)
				end

				entry.copies += 1
			end
		end
	end

	return found
end

-- One web call, once per id per session. A failure is remembered too, so a
-- package that has been taken down is not asked about again on every keystroke.
local function readDetail(id: number)
	if details[id] ~= nil then
		return details[id]
	end

	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(id, Enum.InfoType.Asset)
	end)

	local detail
	if ok and type(info) == "table" then
		detail = { name = info.Name }
	else
		detail = { failed = true }
	end

	details[id] = detail
	return detail
end

-- The name to show for an id, if it has already been read. Nothing is looked up
-- here: this is for a caller drawing a row that cannot afford to wait.
function PackagesBrowser.nameFor(id: number): string?
	local detail = details[id]
	return if detail ~= nil and not detail.failed then detail.name else nil
end

-- Reads a name in the background and hands it over when it lands, for a field
-- that would rather say what it is pointing at than show an id alone. The
-- callback does not run if the name cannot be read.
function PackagesBrowser.resolveName(id: number, hand: (string) -> ())
	local known = PackagesBrowser.nameFor(id)

	if known ~= nil then
		hand(known)
		return
	end

	task.spawn(function()
		local detail = readDetail(id)
		if not detail.failed and detail.name ~= nil then
			hand(detail.name)
		end
	end)
end

local function choose(id: number?)
	local commit = if state ~= nil then state.commit else nil

	if widget ~= nil then
		widget.Enabled = false
	end

	scanToken += 1
	state = nil

	if commit ~= nil then
		commit(id)
	end
end

local function addRow(text: string, note: string, order: number, dim: boolean, activate: (() -> ())?)
	local row = Instance.new("TextButton")
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.LayoutOrder = order
	row.BackgroundColor3 = color(Enum.StudioStyleGuideColor.TableItem)
	row.BorderSizePixel = 0
	row.AutoButtonColor = activate ~= nil
	row.Text = ""
	row.Parent = ui.list

	local name = makeLabel(
		text,
		color(if dim then Enum.StudioStyleGuideColor.DimmedText else Enum.StudioStyleGuideColor.MainText),
		false
	)
	name.Position = UDim2.fromOffset(PADDING, 0)
	name.Size = UDim2.new(1 - ID_COLUMN, -PADDING, 1, 0)
	name.Parent = row

	local trailing = makeLabel(note, color(Enum.StudioStyleGuideColor.DimmedText), false)
	trailing.Position = UDim2.new(1 - ID_COLUMN, 0, 0, 0)
	trailing.Size = UDim2.new(ID_COLUMN, -PADDING, 1, 0)
	trailing.TextXAlignment = Enum.TextXAlignment.Right
	trailing.Parent = row

	if activate ~= nil then
		row.Activated:Connect(activate)
	end
end

render = function()
	if ui == nil or state == nil then
		return
	end

	for _, child in ui.list:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end

	local query = string.lower(string.match(state.query, "^%s*(.-)%s*$") or "")

	-- Every package in the palette is shown; the list is the curated set on
	-- purpose. A row reads by its published name once that lands and by the
	-- palette instance's own name until then, and a name still loading is
	-- counted for the status line.
	local shown = {}
	local pending = 0

	for _, entry in state.entries do
		local detail = details[entry.id]

		if detail == nil then
			pending += 1
		end

		local name = (if detail ~= nil and not detail.failed then detail.name else nil) or entry.sample
		local matches = query == ""
			or string.find(string.lower(name), query, 1, true) ~= nil
			or string.find(string.lower(entry.sample), query, 1, true) ~= nil
			or string.find(tostring(entry.id), query, 1, true) ~= nil

		if matches then
			table.insert(shown, { entry = entry, name = name })
		end
	end

	table.sort(shown, function(a, b)
		if a.name == b.name then
			return a.entry.id < b.entry.id
		end
		return string.lower(a.name) < string.lower(b.name)
	end)

	local order = 0

	-- What the field is pointing at now, and the way back to pointing at
	-- nothing: the attribute is optional, and emptying the field is no longer a
	-- gesture that exists now that clicking it opens this.
	if state.current ~= nil then
		order += 1
		addRow("(not set)", "clear this field", order, true, function()
			choose(nil)
		end)
	end

	-- An id typed in full, for an asset the palette does not hold. Offered only
	-- when the digits are long enough to be an id or found nothing to filter,
	-- since a few digits typed to narrow the list by id are not an id themselves.
	local typed = if string.match(query, "^%d+$") ~= nil then tonumber(query) else nil
	if typed ~= nil and details[typed] == nil and (#query >= ID_DIGITS or #shown == 0) then
		order += 1
		addRow(string.format("Use %d", typed), "not in the palette", order, false, function()
			choose(typed)
		end)
	end

	for _, item in shown do
		local entry = item.entry
		local note = string.format("%d", entry.id)
		if entry.copies > 1 then
			note ..= string.format("  x%d", entry.copies)
		end

		order += 1
		addRow(
			if entry.id == state.current then item.name .. "  (current)" else item.name,
			note,
			order,
			false,
			function()
				choose(entry.id)
			end
		)
	end

	-- Where the list came from: the palette folder, named so an empty list reads
	-- as an empty folder rather than a browser that failed to find anything.
	local status
	if #state.entries == 0 then
		status = "No packages in ReplicatedStorage." .. PALETTE_NAME .. ". Add some there, or type an id above."
	elseif pending > 0 then
		status = string.format("%d shown, reading %d more name%s...", #shown, pending, if pending == 1 then "" else "s")
	elseif #shown == 0 and query ~= "" then
		status = "Nothing in the palette matches. Type an id to use one anyway."
	else
		status = string.format("%d package%s in the palette", #shown, if #shown == 1 then "" else "s")
	end

	ui.status.Text = status
end

local function build()
	if ui ~= nil and ui.root ~= nil then
		ui.root:Destroy()
	end

	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = color(Enum.StudioStyleGuideColor.MainBackground)
	root.BorderSizePixel = 0
	root.Parent = widget

	local header = Instance.new("Frame")
	header.Size = UDim2.new(1, 0, 0, HEADER_HEIGHT)
	header.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Titlebar)
	header.BorderSizePixel = 0
	header.Parent = root

	local searchLabel = makeLabel("Search", color(Enum.StudioStyleGuideColor.MainText), false)
	searchLabel.Position = UDim2.fromOffset(PADDING, 0)
	searchLabel.Size = UDim2.fromOffset(SEARCH_LABEL_WIDTH, HEADER_HEIGHT)
	searchLabel.Parent = header

	local search = Instance.new("TextBox")
	search.Position = UDim2.fromOffset(PADDING + SEARCH_LABEL_WIDTH, 3)
	search.Size = UDim2.new(1, -(PADDING * 2 + SEARCH_LABEL_WIDTH), 0, HEADER_HEIGHT - 6)
	search.BackgroundColor3 = color(Enum.StudioStyleGuideColor.InputFieldBackground)
	search.BorderColor3 = color(Enum.StudioStyleGuideColor.InputFieldBorder)
	search.Font = Enum.Font.SourceSans
	search.TextSize = 14
	search.TextColor3 = color(Enum.StudioStyleGuideColor.MainText)
	search.TextXAlignment = Enum.TextXAlignment.Left
	search.PlaceholderText = "name, or an asset id"
	search.PlaceholderColor3 = color(Enum.StudioStyleGuideColor.DimmedText)
	search.ClearTextOnFocus = false
	search.Text = if state ~= nil then state.query else ""
	indent(search)
	search.Parent = header

	-- Filtered as it is typed rather than on Enter: the list is short enough that
	-- narrowing it is the same gesture as reading it.
	search:GetPropertyChangedSignal("Text"):Connect(function()
		if state ~= nil then
			state.query = search.Text
			render()
		end
	end)

	local list = Instance.new("ScrollingFrame")
	list.Position = UDim2.fromOffset(0, HEADER_HEIGHT)
	list.Size = UDim2.new(1, 0, 1, -(HEADER_HEIGHT + STATUS_HEIGHT))
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollBarThickness = 8
	list.Parent = root

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	local status = makeLabel("", color(Enum.StudioStyleGuideColor.DimmedText), false)
	status.Position = UDim2.new(0, 0, 1, -STATUS_HEIGHT)
	status.Size = UDim2.new(1, -PADDING * 2, 0, STATUS_HEIGHT)
	status.TextTruncate = Enum.TextTruncate.AtEnd
	indent(status)
	status.Parent = root

	ui = { root = root, list = list, status = status, search = search }
end

-- Reads the names the list is missing, a few at a time, so the window is usable
-- while it fills in rather than after.
local function readNames()
	scanToken += 1
	local token = scanToken

	task.spawn(function()
		local read = 0

		for _, entry in state.entries do
			if token ~= scanToken then
				return
			end

			if details[entry.id] == nil then
				readDetail(entry.id)
				read += 1

				if read % NAMES_PER_REFRESH == 0 then
					if token ~= scanToken then
						return
					end
					render()
				end
			end
		end

		if token == scanToken then
			render()
		end
	end)
end

-- `title` names what is being set, `current` is the id it is set to now, and
-- `commit` is handed the chosen id, or nil for a field cleared.
function PackagesBrowser.open(pluginRef: Plugin, title: string, current: number?, commit: (number?) -> ())
	-- A plugin that reloaded on top of an open window, or a failed reload,
	-- can leave the cached widget destroyed while its reference lingers here.
	-- Re-enabling a dead window shows nothing, so a widget whose host is gone
	-- is treated as absent and built again rather than reused.
	if widget ~= nil and widget.Parent == nil then
		widget = nil
		ui = nil
	end

	if widget == nil then
		local info = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, true, 420, 460, 280, 200)
		widget = pluginRef:CreateDockWidgetPluginGui("ScatterGraphPackagesBrowser", info)
		widget.Name = "ScatterGraphPackagesBrowser"
		widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

		settings().Studio.ThemeChanged:Connect(function()
			if state ~= nil and widget.Enabled then
				build()
				render()
			end
		end)

		-- A window closed with its own button is finished with: nothing is picked,
		-- and the names still being read are no longer worth reading.
		widget:GetPropertyChangedSignal("Enabled"):Connect(function()
			if not widget.Enabled then
				scanToken += 1
				state = nil
			end
		end)
	end

	widget.Title = "ScatterGraph Packages Browser - " .. title
	state = {
		query = "",
		current = current,
		commit = commit,
		-- Scanned per open rather than kept: a package added to the palette since
		-- the last visit should be in the list, and the walk is the cheap half.
		entries = scanPalette(),
	}

	build()
	render()
	readNames()
	widget.Enabled = true
end

return PackagesBrowser
