--[[
	TerrainHeightfield

	How high the ground is at every cell of a [GridLayout2D], and the shape that
	follows from it: which way it leans, how steeply, and whether it bends over or
	under.

	One thing measured once, because four nodes want it -- height, slope, aspect and
	curvature are all this and some arithmetic -- and measuring it is the expensive
	part. It is held for the length of a run and keyed by the grid it was measured
	on, so several nodes on one cell size share a single pass over the ground, and a
	node asking at a different resolution gets its own. Cleared when a run begins:
	the terrain does not move while one is in flight, and does between them.

	Measured by looking down, one ray a cell, from the top of the volumes to the
	bottom of them. Rays rather than voxels because a ray reports the surface the
	terrain actually renders -- terrain is smoothed between voxels, and a slope read
	off voxel occupancy would be the shape of the data rather than the shape of the
	hill -- and because it is the same measure the per-point slope filter takes, so
	a slope texture and a SlopeFilter agree about which way is up.

	Ground with a hollow under it is measured as ground: the first thing the ray
	meets is the surface, which is what looking down at it says. A cell with no
	terrain under it at all is not ground and is marked as such, since a hole in a
	biome should not read as a cliff at its edge.
]]

local GridLayout2D = require(script.Parent:WaitForChild("GridLayout2D"))

local TerrainHeightfield = {}

export type Field = {
	-- The grid this was measured on, which may be coarser than the one asked for:
	-- see the budget below.
	layout: GridLayout2D.Layout,
	-- Surface height at every cell centre, X fastest, then Z. Where no ground was
	-- found this is the floor of the volumes, so that arithmetic over it stays
	-- arithmetic; `found` is what says whether to believe it.
	heights: { number },
	found: { boolean },
	-- The heights of the lowest and highest ground found, which is the range a
	-- heightmap is normalised against. Both the floor where nothing was found.
	lowest: number,
	highest: number,
	-- How many cells found ground, out of how many there are.
	hits: number,
	cells: number,
}

-- The most rays one field is measured with. A ray is a few microseconds, so this
-- is a couple of seconds of measuring -- long, but a thing an author asked for by
-- choosing a resolution. Ten million, which is what a grid may hold, would be
-- minutes and would read as a hang.
local MAX_SAMPLES = 1000000

-- Measured fields by the grid they sit on, for the length of a run.
local held: { [string]: Field } = {}

local function signature(layout: GridLayout2D.Layout): string
	return string.format(
		"%g|%g|%g|%d|%d",
		layout.origin.X,
		layout.origin.Y,
		layout.voxelSize,
		layout.resolution.X,
		layout.resolution.Y
	)
end

-- Drops every measured field, so the next run measures the ground as it now is.
function TerrainHeightfield.clear()
	held = {}
end

--[[
	The ground under a volume group, measured onto `layout` -- or onto a coarser
	grid over the same ground, where that one would take more rays than the budget
	allows, which is said out loud when it happens.

	Measured once per grid per run: the second node to ask for the same thing gets
	the first one's answer.
]]
function TerrainHeightfield.of(volumes, terrain: Terrain, layout: GridLayout2D.Layout): Field
	local budgeted = layout

	while budgeted.resolution.X * budgeted.resolution.Y > MAX_SAMPLES do
		local coarser = GridLayout2D.layoutFor(volumes, budgeted.voxelSize * 2)
		warn(
			string.format(
				"ScatterGraph: reading the ground over %s at a %g stud cell would take %d rays, past the %d "
					.. "one measure allows, so it was read at %g studs instead. Raise Voxel Size to choose "
					.. "the resolution yourself.",
				volumes.name,
				budgeted.voxelSize,
				budgeted.resolution.X * budgeted.resolution.Y,
				MAX_SAMPLES,
				coarser.voxelSize
			)
		)
		budgeted = coarser
	end

	local key = signature(budgeted)
	local already = held[key]
	if already ~= nil then
		return already
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { terrain }

	-- The whole vertical span of the volumes, as the point snap uses: taller than
	-- any one volume's Size.Y once it is rotated.
	local top, length = volumes:verticalBounds()
	local floor = top - length
	local down = Vector3.new(0, -length, 0)

	local countX, countZ = budgeted.resolution.X, budgeted.resolution.Y
	local voxelSize = budgeted.voxelSize
	local origin = budgeted.origin

	local heights = table.create(countX * countZ, floor)
	local found = table.create(countX * countZ, false)
	local lowest, highest = math.huge, -math.huge
	local hits = 0
	local at = 1

	for k = 0, countZ - 1 do
		local z = origin.Y + k * voxelSize

		for i = 0, countX - 1 do
			local hit = workspace:Raycast(Vector3.new(origin.X + i * voxelSize, top, z), down, params)

			if hit ~= nil then
				local height = hit.Position.Y
				heights[at] = height
				found[at] = true
				hits += 1
				lowest = math.min(lowest, height)
				highest = math.max(highest, height)
			end

			at += 1
		end
	end

	if hits == 0 then
		lowest, highest = floor, floor
	end

	local field: Field = {
		layout = budgeted,
		heights = heights,
		found = found,
		lowest = lowest,
		highest = highest,
		hits = hits,
		cells = countX * countZ,
	}

	held[key] = field
	return field
end

-- Where a cell sits in the flat array, brought inside the grid: out of it is
-- answered at its edge, the way reading a value out of one is.
local function indexOf(field: Field, i: number, k: number): number
	local resolution = field.layout.resolution
	local x = math.clamp(i, 0, resolution.X - 1)
	local z = math.clamp(k, 0, resolution.Y - 1)

	return 1 + x + z * resolution.X
end

-- The height at a cell, and whether there was any ground there to measure.
function TerrainHeightfield.at(field: Field, i: number, k: number): (number, boolean)
	local index = indexOf(field, i, k)
	return field.heights[index], field.found[index]
end

--[[
	The height at a cell, standing in `instead` for it where there was no ground
	there.

	What the two derivatives below difference against, and the reason they do:
	nothing measured is not the same as ground at the floor of the volumes, and
	differencing against the floor would put a cliff the height of the biome around
	every hole in the terrain. Standing the middle of the kernel in instead reads a
	hole as flat, which says the same as "there is nothing here to slope".
]]
local function heightOr(field: Field, i: number, k: number, instead: number): number
	local index = indexOf(field, i, k)
	return if field.found[index] then field.heights[index] else instead
end

--[[
	How much the ground rises per stud at a cell, along X and along Z, taken from
	the cells `kernel` away on either side. One is the neighbouring cells, which
	reads every bump; larger reads the shape a hill has rather than what is lying
	on it.

	A cell near the edge of the grid is differenced against as much of the kernel
	as there is and divided by how far that actually reached, so an edge reads the
	slope it has rather than a shallower one. A grid carries a couple of cells past
	the ground being scattered, so this only comes up outside the volumes.
]]
function TerrainHeightfield.gradientAt(field: Field, i: number, k: number, kernel: number): (number, number)
	local resolution = field.layout.resolution
	local voxelSize = field.layout.voxelSize
	local middle = heightOr(field, i, k, field.lowest)

	local function differenceAlong(index: number, count: number, sampleAt: (number) -> number): number
		local low = math.max(index - kernel, 0)
		local high = math.min(index + kernel, count - 1)
		local span = (high - low) * voxelSize

		if span <= 0 then
			return 0
		end

		return (sampleAt(high) - sampleAt(low)) / span
	end

	local alongX = differenceAlong(i, resolution.X, function(index: number): number
		return heightOr(field, index, k, middle)
	end)
	local alongZ = differenceAlong(k, resolution.Y, function(index: number): number
		return heightOr(field, i, index, middle)
	end)

	return alongX, alongZ
end

--[[
	How the ground bends at a cell: the rate the slope itself changes, summed over
	both axes, in reciprocal studs. Positive where the ground is convex -- a ridge,
	a hilltop, the lip of a bank -- and negative where it is concave, which is a
	gully, a hollow, or the foot of a slope.

	That sign is the way round every map reads it, and is the opposite of the second
	difference of height, which is negative at a hilltop. So it is taken and then
	turned over rather than reported as the arithmetic falls out.

	Unlike a slope, this needs the same distance either side of the cell to mean
	anything at all: differenced against one side twice, an even hillside reads as a
	fierce bend rather than as none. So a cell nearer the edge of the grid than the
	kernel reaches reports the bend of the nearest cell that has room for it, the way
	reading a value off the edge of a grid reads the edge cell. Left to difference
	one-sidedly, the rim of every grid would come out as the sharpest bend in the
	place -- and since the curvature node spreads its greys over the largest bend it
	found, that one false reading would flatten the whole picture towards grey.
]]
function TerrainHeightfield.bendAt(field: Field, i: number, k: number, kernel: number): number
	local resolution = field.layout.resolution
	local voxelSize = field.layout.voxelSize

	local function bendAlong(index: number, count: number, heightAt: (number, number) -> number): number
		-- As much kernel as this axis has room for on both sides at once, which is
		-- all of it on any grid worth measuring: a couple of cells is the smallest
		-- grid there is, and a kernel is one cell by default.
		local reach = math.min(kernel, math.floor((count - 1) * 0.5))

		if reach < 1 then
			return 0
		end

		local anchor = math.clamp(index, reach, count - 1 - reach)
		local step = reach * voxelSize
		local middle = heightAt(anchor, field.lowest)

		return (heightAt(anchor + reach, middle) - 2 * middle + heightAt(anchor - reach, middle)) / (step * step)
	end

	local alongX = bendAlong(i, resolution.X, function(index: number, instead: number): number
		return heightOr(field, index, k, instead)
	end)
	local alongZ = bendAlong(k, resolution.Y, function(index: number, instead: number): number
		return heightOr(field, i, index, instead)
	end)

	return -(alongX + alongZ)
end

return TerrainHeightfield
