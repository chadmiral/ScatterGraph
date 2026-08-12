--[[
	PlacementLedger

	A durable record, per rule, of what the system placed and where. A deletion
	can only ever be seen as an absence, and an absence means nothing unless we
	wrote down what used to be there, so the run keeps a small book of every
	point it owns.

	One StringValue per rule lives at
	Workspace.ScatterGraphRecords/<graph>/<rule>, holding base64 of packed
	entries -- ten bytes each: x and z in millimetres as signed 32-bit ints, an
	occurrence byte, and a state byte. Height is never in the key: it comes from
	the terrain or from the volume group's vertical span, never from the author,
	and both move for reasons that are not edits. X and Z are the stable half of
	a point; the occurrence index tells apart two placements of one rule that
	happen to share them.

	Three states:
	  placed    -- the system owns a live instance at this point.
	  promoted  -- a hand-edited instance now claims it; the system keeps clear.
	  removed   -- the author deleted it; never place here again.

	A run reconciles at its start (the sweep) and prunes at its end (finishRun).
	It may be narrowed to a single graph, which is what the button in each window
	that evaluates the graph on screen does: both ends of the run then pass over
	every placement belonging to another graph, so what those graphs put in the
	world and wrote down about it comes through untouched.
	Only `placed` entries are ever pruned; `promoted` and `removed` are kept
	across runs, so raising a volume onto a new plane, or nudging one sideways
	and back, never resurrects a prop the author threw away. They grow only when
	the author edits, and Forget Edits clears them.

	Records live in the Workspace rather than on the graph on purpose: a graph
	can be shared between places or loaded from an asset id, but a hole is a fact
	about this place.
]]

local CollectionService = game:GetService("CollectionService")

local PlacementStamp = require(script.Parent:WaitForChild("PlacementStamp"))

local PlacementLedger = {}

local RECORDS_FOLDER = "ScatterGraphRecords"
local PROMOTED_FOLDER = "ScatterGraphPromoted"
local INSTANCE_TAG = "ScatterGraphInstance"
local PROMOTED_TAG = "ScatterGraphPromoted"

local PLACED, PROMOTED, REMOVED = 1, 2, 3

-- A rule losing this many placements at once, and more than this fraction of
-- them, is more likely a folder deleted by hand than instance-by-instance
-- editing, and worth a word on the Output.
local WARN_MINIMUM = 20
local WARN_FRACTION = 0.5

-- The radius a promoted instance falls back to when it carries no ScatterRadius
-- of its own; matches the terminal node's own default.
local DEFAULT_RADIUS = 5

-- Base64, because a StringValue full of raw packed bytes does not survive the
-- trip through an XML place file intact, while base64 does.
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DECODE = {}
for index = 1, #ALPHABET do
	DECODE[string.byte(ALPHABET, index)] = index - 1
end

local function base64Encode(data: string): string
	local pieces = {}
	for i = 1, #data, 3 do
		local b1 = string.byte(data, i)
		local b2 = string.byte(data, i + 1)
		local b3 = string.byte(data, i + 2)
		local n = b1 * 65536 + (b2 or 0) * 256 + (b3 or 0)
		local c1 = math.floor(n / 262144) % 64
		local c2 = math.floor(n / 4096) % 64
		local c3 = math.floor(n / 64) % 64
		local c4 = n % 64
		if b3 then
			table.insert(pieces, ALPHABET:sub(c1 + 1, c1 + 1) .. ALPHABET:sub(c2 + 1, c2 + 1)
				.. ALPHABET:sub(c3 + 1, c3 + 1) .. ALPHABET:sub(c4 + 1, c4 + 1))
		elseif b2 then
			table.insert(pieces, ALPHABET:sub(c1 + 1, c1 + 1) .. ALPHABET:sub(c2 + 1, c2 + 1)
				.. ALPHABET:sub(c3 + 1, c3 + 1) .. "=")
		else
			table.insert(pieces, ALPHABET:sub(c1 + 1, c1 + 1) .. ALPHABET:sub(c2 + 1, c2 + 1) .. "==")
		end
	end
	return table.concat(pieces)
end

local function base64Decode(text: string): string
	local bytes = {}
	local accumulator, bits = 0, 0
	for i = 1, #text do
		local value = DECODE[string.byte(text, i)]
		if value ~= nil then
			accumulator = accumulator * 64 + value
			bits += 6
			if bits >= 8 then
				bits -= 8
				local divisor = 2 ^ bits
				table.insert(bytes, string.char(math.floor(accumulator / divisor) % 256))
				accumulator = accumulator % divisor
			end
		end
	end
	return table.concat(bytes)
end

local function keyOf(xmm: number, zmm: number, occ: number): string
	return string.format("%d,%d,%d", xmm, zmm, occ)
end

local function serialize(entries): string
	local pieces = {}
	for _, entry in entries do
		table.insert(pieces, string.pack("<i4i4BB", entry.xmm, entry.zmm, entry.occ, entry.state))
	end
	return base64Encode(table.concat(pieces))
end

local function deserialize(text: string?)
	local entries = {}
	if text == nil or text == "" then
		return entries
	end
	local data = base64Decode(text)
	local position = 1
	while position + 9 <= #data do
		local xmm, zmm, occ, state, nextPosition = string.unpack("<i4i4BB", data, position)
		entries[keyOf(xmm, zmm, occ)] = { xmm = xmm, zmm = zmm, occ = occ, state = state }
		position = nextPosition
	end
	return entries
end

local function ensureFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing == nil then
		existing = Instance.new("Folder")
		existing.Name = name
		existing.Parent = parent
	end
	return existing
end

-- The point of a placement, rounded the same way everywhere so a sweep and a
-- placement agree on which entry they are talking about.
function PlacementLedger.qmm(value: number): number
	return math.round(value * 1000)
end

-- The folder name records for a graph live under. In-place graphs are keyed by
-- name; the client keys asset-loaded graphs by their id, since those have no
-- lasting instance.
function PlacementLedger.graphKey(graph: Instance): string
	return graph.Name
end

-- The stable identity of a rule and its readable name, given the Output entry
-- that names it. New rules carry a RuleId that survives renaming a node; older
-- ones fall back to the entry's own name.
function PlacementLedger.ruleKey(outputWire: Instance): (string, string)
	local ruleName = outputWire.Name
	local terminal = if outputWire:IsA("ObjectValue") then outputWire.Value else nil
	local id = if terminal ~= nil then terminal:GetAttribute("RuleId") else nil
	local key = if typeof(id) == "string" and id ~= "" then id else ruleName
	return key, ruleName
end

-- ---------------------------------------------------------------------------
-- A run
-- ---------------------------------------------------------------------------

local Run = {}
Run.__index = Run

-- `onlyGraph` narrows the run to one graph's placements, for the button in each
-- window that evaluates the graph on screen and nothing else. Every other
-- graph's instances and books are then left exactly as the run found them: the
-- sweep passes them over, and the pruning at the end never opens a book the run
-- had no business reading. Left nil, the run covers the whole place, which is
-- what the toolbar's Evaluate does.
function PlacementLedger.beginRun(onlyGraph: string?)
	local self = setmetatable({}, Run)
	self.rules = {}
	self.claimsByGraph = {}
	self.recordsRoot = workspace:FindFirstChild(RECORDS_FOLDER)
	self.promotedRoot = nil
	self.onlyGraph = onlyGraph
	return self
end

-- Is this placement one of the ones the run is allowed to touch? An instance
-- the system cannot identify belongs to no graph in particular, so a run
-- narrowed to one leaves it be rather than acting on another graph's behalf --
-- a whole-place run still destroys it as the foreign thing it is.
function Run:_inScope(identity): boolean
	if self.onlyGraph == nil then
		return true
	end
	return identity ~= nil and identity.graphKey == self.onlyGraph
end

-- Loads a rule's book on first mention and keeps it in memory for the rest of
-- the run, so the sweep and the placement pass share one view of it.
function Run:_rule(graphKey: string, ruleKey: string, ruleName: string?)
	local mapKey = graphKey .. "\0" .. ruleKey
	local rule = self.rules[mapKey]
	if rule ~= nil then
		if ruleName ~= nil then
			rule.ruleName = ruleName
		end
		return rule
	end

	rule = {
		graphKey = graphKey,
		ruleKey = ruleKey,
		ruleName = ruleName or ruleKey,
		entries = {},
		stringValue = nil,
		evaluated = false,
		placedAtLoad = 0,
		tombstonedThisRun = 0,
	}

	if self.recordsRoot ~= nil then
		local graphFolder = self.recordsRoot:FindFirstChild(graphKey)
		if graphFolder ~= nil then
			local found = nil
			for _, child in graphFolder:GetChildren() do
				if child:IsA("StringValue") and child:GetAttribute("RuleId") == ruleKey then
					found = child
					break
				end
			end
			-- A legacy record, written before RuleIds, is found by name instead.
			if found == nil and ruleName ~= nil then
				local byName = graphFolder:FindFirstChild(ruleName)
				if byName ~= nil and byName:IsA("StringValue") and byName:GetAttribute("RuleId") == nil then
					found = byName
				end
			end
			if found ~= nil then
				rule.stringValue = found
				rule.entries = deserialize(found.Value)
			end
		end
	end

	for _, entry in rule.entries do
		if entry.state == PLACED then
			rule.placedAtLoad += 1
		end
	end

	self.rules[mapKey] = rule
	return rule
end

function Run:_promotedFolder(): Folder
	if self.promotedRoot == nil then
		self.promotedRoot = ensureFolder(workspace, PROMOTED_FOLDER)
	end
	return self.promotedRoot
end

local function readIdentity(instance: Instance)
	local graphKey = instance:GetAttribute("ScatterGraph")
	local ruleKey = instance:GetAttribute("ScatterRule")
	local origin = instance:GetAttribute("ScatterOrigin")
	local occ = instance:GetAttribute("ScatterOccurrence")
	if typeof(graphKey) ~= "string" or typeof(ruleKey) ~= "string" or typeof(origin) ~= "Vector3" then
		return nil
	end
	return {
		graphKey = graphKey,
		ruleKey = ruleKey,
		origin = origin,
		occ = if typeof(occ) == "number" then occ else 0,
	}
end

-- Walked at the start of every run, before anything is placed.
--   Unchanged system instances are destroyed, as they always were, and their
--   entry is marked as having been alive so the placement pass knows to put it
--   back rather than reading its absence as a deletion.
--   Edited ones are promoted: untagged, retagged, reparented, their entry
--   turned to `promoted`.
-- A second pass over the promoted folder rebuilds the claims -- so a promotion
-- from an earlier run keeps asserting its point -- and registers each as a
-- solid footprint at where it actually sits now.
function Run:sweep()
	for _, instance in CollectionService:GetTagged(INSTANCE_TAG) do
		local storedStamp = instance:GetAttribute("ScatterStamp")
		local identity = readIdentity(instance)

		if not self:_inScope(identity) then
			continue
		end

		if identity == nil or typeof(storedStamp) ~= "number" then
			-- Legacy or foreign: destroyed as it was before any of this existed,
			-- so the first run after this lands is a clean reset.
			instance:Destroy()
			continue
		end

		local rule = self:_rule(identity.graphKey, identity.ruleKey)
		local key = keyOf(
			PlacementLedger.qmm(identity.origin.X),
			PlacementLedger.qmm(identity.origin.Z),
			identity.occ
		)
		local entry = rule.entries[key]

		if PlacementStamp.stamp(instance) == storedStamp then
			if entry ~= nil then
				entry.seenLive = true
			end
			instance:Destroy()
		else
			if entry == nil then
				entry = {
					xmm = PlacementLedger.qmm(identity.origin.X),
					zmm = PlacementLedger.qmm(identity.origin.Z),
					occ = identity.occ,
					state = PROMOTED,
				}
				rule.entries[key] = entry
			end
			entry.state = PROMOTED
			CollectionService:RemoveTag(instance, INSTANCE_TAG)
			CollectionService:AddTag(instance, PROMOTED_TAG)
			-- No longer the system's to compare.
			instance:SetAttribute("ScatterStamp", nil)
			instance.Parent = self:_promotedFolder()
		end
	end

	for _, instance in CollectionService:GetTagged(PROMOTED_TAG) do
		local identity = readIdentity(instance)
		if identity ~= nil and self:_inScope(identity) then
			local rule = self:_rule(identity.graphKey, identity.ruleKey)
			local key = keyOf(
				PlacementLedger.qmm(identity.origin.X),
				PlacementLedger.qmm(identity.origin.Z),
				identity.occ
			)
			local entry = rule.entries[key]
			if entry == nil then
				entry = {
					xmm = PlacementLedger.qmm(identity.origin.X),
					zmm = PlacementLedger.qmm(identity.origin.Z),
					occ = identity.occ,
					state = PROMOTED,
				}
				rule.entries[key] = entry
			end
			entry.state = PROMOTED
			entry.claimed = true

			local radius = instance:GetAttribute("ScatterRadius")
			local position = if instance:IsA("PVInstance") then instance:GetPivot().Position else identity.origin
			local claims = self.claimsByGraph[identity.graphKey]
			if claims == nil then
				claims = {}
				self.claimsByGraph[identity.graphKey] = claims
			end
			table.insert(claims, {
				x = position.X,
				z = position.Z,
				radius = if typeof(radius) == "number" then radius else DEFAULT_RADIUS,
				ruleKey = identity.ruleKey,
			})
		end
	end
end

-- The promoted footprints of one graph, for the run's OccupancyStore to treat
-- as solids so AvoidIntersections rules keep clear of where the author put them.
function Run:promotedClaims(graphKey: string)
	return self.claimsByGraph[graphKey] or {}
end

-- A rule counts as evaluated once its terminal runs, even with no points, so
-- its stale `placed` entries are pruned rather than merely dropped.
function Run:markEvaluated(graphKey: string, ruleKey: string, ruleName: string?)
	self:_rule(graphKey, ruleKey, ruleName).evaluated = true
end

-- Whether the placement pass should clone at this point. A claimed or removed
-- point is skipped; a placed point whose instance was found live is put back;
-- a placed point whose instance is gone was deleted by the author, so it is
-- tombstoned here and skipped from now on.
function Run:shouldPlace(graphKey: string, ruleKey: string, xmm: number, zmm: number, occ: number): boolean
	local rule = self:_rule(graphKey, ruleKey)
	local entry = rule.entries[keyOf(xmm, zmm, occ)]
	if entry == nil then
		return true
	end
	if entry.state == REMOVED or entry.state == PROMOTED then
		return false
	end
	if entry.seenLive then
		return true
	end
	entry.state = REMOVED
	rule.tombstonedThisRun += 1
	return false
end

function Run:recordPlaced(graphKey: string, ruleKey: string, xmm: number, zmm: number, occ: number)
	local rule = self:_rule(graphKey, ruleKey)
	local key = keyOf(xmm, zmm, occ)
	local entry = rule.entries[key]
	if entry == nil then
		entry = { xmm = xmm, zmm = zmm, occ = occ }
		rule.entries[key] = entry
	end
	entry.state = PLACED
	entry.placedThisRun = true
end

function Run:_save(rule)
	local count = 0
	for _ in rule.entries do
		count += 1
	end

	if count == 0 then
		if rule.stringValue ~= nil then
			rule.stringValue:Destroy()
			rule.stringValue = nil
		end
		return
	end

	local stringValue = rule.stringValue
	if stringValue == nil then
		self.recordsRoot = ensureFolder(workspace, RECORDS_FOLDER)
		local graphFolder = ensureFolder(self.recordsRoot, rule.graphKey)
		stringValue = Instance.new("StringValue")
		stringValue.Name = rule.ruleName
		stringValue:SetAttribute("RuleId", rule.ruleKey)
		stringValue.Parent = graphFolder
		rule.stringValue = stringValue
	else
		if stringValue.Name ~= rule.ruleName then
			stringValue.Name = rule.ruleName
		end
		if stringValue:GetAttribute("RuleId") == nil then
			stringValue:SetAttribute("RuleId", rule.ruleKey)
		end
	end
	stringValue.Value = serialize(rule.entries)
end

-- Prunes and writes every book the run touched.
--   promoted   -- kept while a claim backs it; tombstoned to removed if the
--                 author has since deleted what they promoted.
--   removed    -- kept forever.
--   placed     -- kept only if placed again this run. On an evaluated rule the
--                 rest is pruned (the rule no longer wants it); on a rule that
--                 was not evaluated -- a disabled or deleted volume -- all of
--                 it is dropped, so the next run does not read a whole quiet
--                 rule as a field of deletions.
function Run:finishRun()
	for _, rule in self.rules do
		-- Nothing outside a narrowed run's graph should have been read in the
		-- first place, since the sweep passed those instances over. Checked
		-- again here because this is where a book is rewritten, and a rule the
		-- run never evaluated is one this would prune every live point from.
		if self.onlyGraph ~= nil and rule.graphKey ~= self.onlyGraph then
			continue
		end

		local kept = {}
		for key, entry in rule.entries do
			if entry.state == REMOVED then
				kept[key] = entry
			elseif entry.state == PROMOTED then
				if entry.claimed then
					kept[key] = entry
				else
					entry.state = REMOVED
					kept[key] = entry
				end
			elseif entry.state == PLACED then
				if rule.evaluated and entry.placedThisRun then
					kept[key] = entry
				end
			end
		end
		rule.entries = kept
		self:_save(rule)

		if rule.evaluated
			and rule.placedAtLoad >= WARN_MINIMUM
			and rule.tombstonedThisRun >= rule.placedAtLoad * WARN_FRACTION
		then
			warn(string.format(
				"ScatterGraph: rule '%s' lost %d of %d placements since the last run and treated each "
					.. "as a deletion. If a whole folder was deleted by hand rather than props edited one "
					.. "by one, run Forget Edits on the rule to place them again.",
				rule.ruleName,
				rule.tombstonedThisRun,
				rule.placedAtLoad
			))
		end
	end
end

-- ---------------------------------------------------------------------------
-- Standalone maintenance, outside a run
-- ---------------------------------------------------------------------------

-- Clear Instances, and any rule the run never reaches, must drop `placed`
-- entries while keeping `promoted` and `removed`: the instances are gone, so
-- without this the next run would read every one of them as a hand deletion.
function PlacementLedger.wipePlaced()
	local root = workspace:FindFirstChild(RECORDS_FOLDER)
	if root == nil then
		return
	end
	for _, graphFolder in root:GetChildren() do
		for _, stringValue in graphFolder:GetChildren() do
			if stringValue:IsA("StringValue") then
				local kept = {}
				local any = false
				for key, entry in deserialize(stringValue.Value) do
					if entry.state ~= PLACED then
						kept[key] = entry
						any = true
					end
				end
				if any then
					stringValue.Value = serialize(kept)
				else
					stringValue:Destroy()
				end
			end
		end
		if #graphFolder:GetChildren() == 0 then
			graphFolder:Destroy()
		end
	end
end

-- Keep these instances whatever the stamp says: the explicit escape hatch.
-- Promotes every ScatterGraphInstance among the given instances and their
-- descendants, and records the claim so the next run keeps clear. Returns how
-- many were promoted.
function PlacementLedger.promoteSelection(instances: { Instance }): number
	local run = PlacementLedger.beginRun()
	local promotedFolder = nil
	local promoted = 0

	local function promoteOne(instance: Instance)
		local identity = readIdentity(instance)
		if identity == nil then
			return
		end
		local rule = run:_rule(identity.graphKey, identity.ruleKey)
		local key = keyOf(
			PlacementLedger.qmm(identity.origin.X),
			PlacementLedger.qmm(identity.origin.Z),
			identity.occ
		)
		local entry = rule.entries[key]
		if entry == nil then
			entry = {
				xmm = PlacementLedger.qmm(identity.origin.X),
				zmm = PlacementLedger.qmm(identity.origin.Z),
				occ = identity.occ,
			}
			rule.entries[key] = entry
		end
		entry.state = PROMOTED
		entry.claimed = true

		CollectionService:RemoveTag(instance, INSTANCE_TAG)
		CollectionService:AddTag(instance, PROMOTED_TAG)
		instance:SetAttribute("ScatterStamp", nil)
		if promotedFolder == nil then
			promotedFolder = ensureFolder(workspace, PROMOTED_FOLDER)
		end
		instance.Parent = promotedFolder
		promoted += 1
	end

	for _, top in instances do
		if CollectionService:HasTag(top, INSTANCE_TAG) then
			promoteOne(top)
		end
		for _, descendant in top:GetDescendants() do
			if CollectionService:HasTag(descendant, INSTANCE_TAG) then
				promoteOne(descendant)
			end
		end
	end

	for _, rule in run.rules do
		run:_save(rule)
	end

	return promoted
end

-- Drop a rule's book and discard its promotions, so it regenerates from
-- nothing on the next run.
function PlacementLedger.forget(graphKey: string, ruleKey: string)
	local root = workspace:FindFirstChild(RECORDS_FOLDER)
	if root ~= nil then
		local graphFolder = root:FindFirstChild(graphKey)
		if graphFolder ~= nil then
			for _, child in graphFolder:GetChildren() do
				if child:IsA("StringValue")
					and (child:GetAttribute("RuleId") == ruleKey or child.Name == ruleKey)
				then
					child:Destroy()
				end
			end
			if #graphFolder:GetChildren() == 0 then
				graphFolder:Destroy()
			end
		end
	end

	for _, instance in CollectionService:GetTagged(PROMOTED_TAG) do
		if instance:GetAttribute("ScatterGraph") == graphKey
			and instance:GetAttribute("ScatterRule") == ruleKey
		then
			instance:Destroy()
		end
	end
end

-- Forget every rule in the place at once: drop all books and discard every
-- promotion, so the next run rebuilds everything from nothing. The full reset
-- behind the toolbar's Forget Edits, which has no one rule to act on.
function PlacementLedger.forgetAll()
	local root = workspace:FindFirstChild(RECORDS_FOLDER)
	if root ~= nil then
		root:Destroy()
	end

	for _, instance in CollectionService:GetTagged(PROMOTED_TAG) do
		instance:Destroy()
	end
end

return PlacementLedger
