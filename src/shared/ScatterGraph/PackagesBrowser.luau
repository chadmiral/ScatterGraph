--[[
	PackagesBrowser

	A picker for a published asset id, opened from the GeometryAssetID field: the
	packages this place uses, listed by name, with a search box over them.

	Nobody knows a package's asset id by heart, and a plugin cannot ask Roblox
	which packages an author or their group own. HttpService refuses every Roblox
	domain outright, and no engine API lists a creator's inventory. What is
	readable from in here is the place itself: every package instance carries a
	PackageLink naming the package it came from, and GetProductInfo turns that id
	into a published name and an owner without going near HttpService. So the
	list is the packages the place already contains, narrowed to the ones the
	signed-in author or the experience's group own -- which, for a place being
	decorated, is very nearly the library an author wants anyway. Packages that
	came from somewhere else are counted rather than listed, so it is clear the
	list is not everything found.

	A name is a web lookup apiece, so they are read one at a time in the
	background with rows appearing as they land, and kept for the rest of the
	session: a second visit to the browser is immediate. The search box takes an
	id as well as a name, which is what keeps a known id typeable now that the
	field itself opens this window instead of a caret.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local StudioService = game:GetService("StudioService")

local GraphUi = require(script.Parent:WaitForChild("GraphUi"))

local PackagesBrowser = {}

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
local userId = nil

local widget = nil
local ui = nil
local state = nil
-- Bumped to abandon a scan whose window has been closed, reopened, or asked for
-- a different place's packages since.
local scanToken = 0

local render

local function signedInUser(): number?
	if userId == nil then
		local ok, result = pcall(function()
			return StudioService:GetUserId()
		end)
		userId = if ok then result else nil
	end

	return userId
end

-- Every package the place holds, by id, with the name of an instance it is
-- attached to and how many copies there are. The instance name is a stand-in
-- until the published name arrives, and worth showing on its own: it is what an
-- author sees in the Explorer.
local function scanPlace()
	local byId = {}
	local found = {}

	for _, thing in game:GetDescendants() do
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
		local creator = info.Creator or {}
		detail = {
			name = info.Name,
			ownerType = creator.CreatorType,
			ownerId = creator.CreatorTargetId,
			ownerName = creator.Name,
		}
	else
		detail = { failed = true }
	end

	details[id] = detail
	return detail
end

-- Whose packages are worth listing: the author's own, and the ones belonging to
-- the group the experience is under. A place can hold packages from anywhere --
-- a model taken from the marketplace brings its own along -- and those are not
-- what an author is reaching for here.
local function ownedByUs(detail): boolean
	if detail.failed or detail.ownerId == nil then
		return false
	end

	if detail.ownerType == "User" then
		return detail.ownerId == signedInUser()
	elseif detail.ownerType == "Group" then
		return game.CreatorType == Enum.CreatorType.Group and detail.ownerId == game.CreatorId
	end

	return false
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

	-- Gathered before anything is drawn, because whether digits in the box are a
	-- search or an id worth offering depends on what the search turned up.
	local shown = {}
	local pending, elsewhere = 0, 0

	for _, entry in state.entries do
		local detail = details[entry.id]

		if detail == nil then
			pending += 1
		elseif not ownedByUs(detail) then
			elsewhere += 1
		else
			local name = detail.name or entry.sample
			local matches = query == ""
				or string.find(string.lower(name), query, 1, true) ~= nil
				or string.find(string.lower(entry.sample), query, 1, true) ~= nil
				or string.find(tostring(entry.id), query, 1, true) ~= nil

			if matches then
				table.insert(shown, { entry = entry, name = name, detail = detail })
			end
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

	-- An id typed in full, for a package this place has never held. Offered only
	-- when the digits are long enough to be an id or found nothing to filter,
	-- since a few digits typed to narrow the list by id are not an id themselves.
	local typed = if string.match(query, "^%d+$") ~= nil then tonumber(query) else nil
	if typed ~= nil and details[typed] == nil and (#query >= ID_DIGITS or #shown == 0) then
		order += 1
		addRow(string.format("Use %d", typed), "not in this place", order, false, function()
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

	-- Where the list came from and what it left out, since a list of packages
	-- that is not an author's whole inventory should say so rather than look
	-- like one.
	local status
	if #state.entries == 0 then
		status = "No packages in this place yet. Insert one, or type its id above."
	elseif pending > 0 then
		status = string.format("%d shown, reading %d more name%s...", #shown, pending, if pending == 1 then "" else "s")
	elseif #shown == 0 and query ~= "" then
		status = "Nothing here matches. Type an id to use one from outside this place."
	else
		status = string.format("%d package%s in this place", #shown, if #shown == 1 then "" else "s")
		if elsewhere > 0 then
			status ..= string.format(", %d owned by someone else and not shown", elsewhere)
		end
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
		-- Scanned per open rather than kept: a package inserted since the last
		-- visit should be in the list, and the walk is the cheap half of this.
		entries = scanPlace(),
	}

	build()
	render()
	readNames()
	widget.Enabled = true
end

return PackagesBrowser
