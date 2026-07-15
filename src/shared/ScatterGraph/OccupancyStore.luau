--[[
	OccupancyStore

	Tracks the footprints of geometry placed during a single graph evaluation so
	that overlaps between parallel branches can be resolved in an
	**order-independent** way.

	Footprints are modeled as circles on the XZ (ground) plane: a center point
	plus a user-supplied radius (the `Radius` attribute on PlaceGeometryOnPoints).
	Two placements are considered intersecting when the horizontal distance
	between their centers is less than the sum of their radii.

	Two kinds of footprints:

	* Solids     -- geometry that is always kept (branches that do NOT opt in to
	                intersection avoidance). Added immediately during evaluation.
	* Candidates -- geometry from branches that opt in (`AvoidIntersections`).
	                These are collected during evaluation and resolved once, after
	                every branch has run, by `resolveDeferred`.

	Because resolution happens after the whole graph is evaluated and processes
	candidates in a fixed global order (by Priority, then a deterministic spatial
	tiebreak), the final result does not depend on the order in which branches
	were evaluated.
]]

local CollectionService = game:GetService("CollectionService")

local OccupancyStore = {}
OccupancyStore.__index = OccupancyStore

local DEFAULT_CELL_SIZE = 16

local function cellKey(cx: number, cz: number): string
	return cx .. "," .. cz
end

function OccupancyStore.new(cellSize: number?)
	local self = setmetatable({}, OccupancyStore)
	self.cellSize = cellSize or DEFAULT_CELL_SIZE
	self.cells = {} :: { [string]: { any } } -- committed footprints (solids)
	self.candidates = {} :: { any } -- deferred, opt-in placements
	return self
end

-- Range of grid cells overlapped by a circle at (x, z) with the given radius.
function OccupancyStore:_cellRange(x: number, z: number, radius: number)
	local cs = self.cellSize
	local minCx = math.floor((x - radius) / cs)
	local maxCx = math.floor((x + radius) / cs)
	local minCz = math.floor((z - radius) / cs)
	local maxCz = math.floor((z + radius) / cs)
	return minCx, maxCx, minCz, maxCz
end

-- Insert a committed footprint into every cell it overlaps. `branchId` lets
-- resolution ignore overlaps between instances of the same branch (so clusters
-- and dense same-rule scatters never reject one another).
function OccupancyStore:addSolid(x: number, z: number, radius: number, branchId)
	local entry = { x = x, z = z, radius = radius, branchId = branchId }
	local minCx, maxCx, minCz, maxCz = self:_cellRange(x, z, radius)
	for cx = minCx, maxCx do
		for cz = minCz, maxCz do
			local key = cellKey(cx, cz)
			local bucket = self.cells[key]
			if not bucket then
				bucket = {}
				self.cells[key] = bucket
			end
			table.insert(bucket, entry)
		end
	end
end

-- True if a circle at (x, z) with the given radius overlaps any committed
-- footprint that does not belong to `ignoreBranchId`.
function OccupancyStore:_intersectsSolid(x: number, z: number, radius: number, ignoreBranchId): boolean
	local minCx, maxCx, minCz, maxCz = self:_cellRange(x, z, radius)
	for cx = minCx, maxCx do
		for cz = minCz, maxCz do
			local bucket = self.cells[cellKey(cx, cz)]
			if bucket then
				for _, other in bucket do
					if other.branchId ~= ignoreBranchId then
						local dx = other.x - x
						local dz = other.z - z
						local sumR = other.radius + radius
						if (dx * dx + dz * dz) < (sumR * sumR) then
							return true
						end
					end
				end
			end
		end
	end
	return false
end

-- Queue an opt-in placement for later resolution.
-- cand = { instance, x, z, radius, priority, branchId }
function OccupancyStore:addCandidate(cand)
	table.insert(self.candidates, cand)
end

-- Deterministic total order over candidates, independent of insertion order:
-- lower Priority wins (0 is the highest priority); ties are broken by a stable
-- spatial key, then branchId.
local function candidateLess(a, b): boolean
	if a.priority ~= b.priority then
		return a.priority < b.priority
	end
	if a.x ~= b.x then
		return a.x < b.x
	end
	if a.z ~= b.z then
		return a.z < b.z
	end
	return tostring(a.branchId) < tostring(b.branchId)
end

-- Resolve all deferred candidates against solids and one another. Because the
-- candidate list is sorted into a fixed global order first (lowest Priority
-- number wins), the surviving set is the same regardless of the order branches
-- were evaluated in. Surviving candidates are tagged and become solids; rejected
-- ones are destroyed.
function OccupancyStore:resolveDeferred()
	table.sort(self.candidates, candidateLess)

	for _, cand in self.candidates do
		if self:_intersectsSolid(cand.x, cand.z, cand.radius, cand.branchId) then
			cand.instance:Destroy()
		else
			CollectionService:AddTag(cand.instance, "ScatterGraphInstance")
			self:addSolid(cand.x, cand.z, cand.radius, cand.branchId)
		end
	end

	self.candidates = {}
end

return OccupancyStore
