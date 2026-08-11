--[[
	SDFGrid2D

	A shape on the ground, measured onto a grid: a rectangle of cells covering it,
	each holding how far its centre is from the nearest edge of the shape, negative
	inside. A field like this answers "how close is this spot to that shape" in
	constant time however complicated the shape, which is what lets a scatter of
	tens of thousands of points be masked around one.

	The field is flat. Scattering is a top-down business -- points are spread across
	a footprint and dropped onto the ground -- so what a mask needs to know is how
	far a spot is from water or from sand as seen from above, and a plane of cells
	answers that with none of the cost of a box of them. Everything in the plane is
	a Vector2 of world X and Z: read the `Y` of one of these as the world's Z, and
	nothing here has a height at all.

	The grid travels between nodes as one value, so it carries what is needed to
	read it as well as the distances themselves: where it starts, how big a cell is,
	and how many of them it holds each way. A node handed one needs nothing else to
	sample it.

	`fromCells` fills one from a region already marked off cell by cell -- terrain
	material, say, which is only ever known that coarsely -- and works the distances
	out from the marks themselves.

	Where a field sits and how finely it is measured is a `Layout`. The rectangle
	comes from the volumes being scattered -- `layoutFor` settles it and the
	evaluator hands it down the graph, so every field in a run covers the same
	ground -- while how finely that rectangle is divided is the one part the node
	measuring a field may ask for.

	Cells are counted before they are filled, and a budget coarsens the field rather
	than letting a stray parameter hang Studio.
]]

local SDFGrid2D = {}

export type Grid = {
	-- World X and Z of the centre of the cell at (0, 0).
	origin: Vector2,
	-- The edge length of one cell, in studs, after the budget below has had its
	-- say. Not necessarily the size that was asked for.
	voxelSize: number,
	-- How many cells across X and Z. Whole numbers, at least two.
	resolution: Vector2,
	-- How much ground the cell centres span, in studs: the distance from the first
	-- centre to the last, each way.
	dimensions: Vector2,
	-- The signed distance at every cell centre, X fastest, then Z.
	distances: { number },
	-- What the field was measured from -- the terrain -- so anything reading one
	-- can say where it came from.
	source: Instance?,
}

-- Where a field sits and how finely it is measured, without the measurements: the
-- part of a grid that is decided before anything is measured at all, and so the
-- part that can be settled once and shared.
export type Layout = {
	origin: Vector2,
	voxelSize: number,
	resolution: Vector2,
}

-- How far past the region of interest the field is measured, in cells. Two is
-- enough that a sample just outside it still lands between measured cells rather
-- than against the edge of the grid.
local PADDING_CELLS = 2

-- Below this a cell is finer than any placement decision could use, and the count
-- of them climbs as the square of it.
local MIN_VOXEL_SIZE = 0.1

-- Terrain is stored on a four stud grid and reads back at that and nothing else,
-- so a field over the world starts there. It is the finest a material boundary is
-- known to, and no amount of grid would invent more.
local TERRAIN_VOXEL = 4

SDFGrid2D.TERRAIN_VOXEL = TERRAIN_VOXEL

-- The most cells one field may hold. Ten million is a few hundred megabytes and
-- some seconds while a graph is being evaluated. Flat, that is a great deal of
-- ground -- twelve thousand studs square at terrain's own four studs -- so this is
-- a backstop against a mistyped parameter rather than a limit anything real meets.
local MAX_CELLS = 10000000

-- The ground a layout covers: everything the volume group reaches in X and Z,
-- snapped out to whole cells of the size being measured at, and padded by a couple
-- of them so the field carries on a little way past the ground being scattered.
local function rectangleFor(volumes, voxelSize: number): (Vector2, Vector2)
	local low = Vector2.new(math.huge, math.huge)
	local high = Vector2.new(-math.huge, -math.huge)

	for _, box in volumes:footprintBoundsList() do
		low = Vector2.new(math.min(low.X, box.minX), math.min(low.Y, box.minZ))
		high = Vector2.new(math.max(high.X, box.maxX), math.max(high.Y, box.maxZ))
	end

	local padding = voxelSize * PADDING_CELLS

	local function down(value: number): number
		return math.floor(value / voxelSize) * voxelSize
	end

	local function up(value: number): number
		return math.ceil(value / voxelSize) * voxelSize
	end

	return Vector2.new(down(low.X), down(low.Y)) - Vector2.new(padding, padding),
		Vector2.new(up(high.X), up(high.Y)) + Vector2.new(padding, padding)
end

--[[
	The grid a field over a volume group is measured on: the ground the volumes
	cover, divided into cells `voxelSize` across -- terrain's own four studs, where
	the caller has no opinion.

	The rectangle is the group's, not the caller's. It is settled before any node
	runs and handed down the graph as it is evaluated, so that what a field covers
	answers to the ground being scattered rather than to whichever node happens to
	measure it. How finely that rectangle is divided is the one part a node may ask
	for, since two fields of different resolutions still cover the same ground and
	are still read the same way -- by sampling a world position, not an index.

	Cells double -- to eight studs, then sixteen -- until the field fits the budget,
	with a warning saying so. Doubling rather than scaling keeps whatever alignment
	with the terrain grid the size asked for had.
]]
function SDFGrid2D.layoutFor(volumes, requested: number?): Layout
	local asked = math.max(requested or TERRAIN_VOXEL, MIN_VOXEL_SIZE)
	local voxelSize = asked

	while true do
		local low, high = rectangleFor(volumes, voxelSize)
		local span = high - low

		-- The rectangle is a whole number of cells across by construction, so this
		-- is rounding off arithmetic rather than deciding anything.
		local countX = math.max(2, math.round(span.X / voxelSize))
		local countZ = math.max(2, math.round(span.Y / voxelSize))

		if countX * countZ <= MAX_CELLS then
			-- Only worth saying to whoever asked for a size and did not get it. The
			-- default layout is settled for every run whether a field is measured
			-- over it or not, and has nobody to tell.
			if requested ~= nil and voxelSize > asked then
				warn(
					string.format(
						"ScatterGraph: %s covers %.0f x %.0f studs, too much ground to measure a distance "
							.. "field over at a %g stud cell within the %d one field may hold, so the field "
							.. "was measured at %g studs instead. Raise Voxel Size to choose the resolution "
							.. "yourself.",
						volumes.name,
						span.X,
						span.Y,
						asked,
						MAX_CELLS,
						voxelSize
					)
				)
			end

			-- A grid holds distances at cell centres, so it begins half a cell in
			-- from the corner of the rectangle.
			local half = voxelSize * 0.5

			return {
				origin = low + Vector2.new(half, half),
				voxelSize = voxelSize,
				resolution = Vector2.new(countX, countZ),
			}
		end

		voxelSize *= 2
	end
end

-- The corner of the ground a layout covers: half a cell out from the first centre,
-- which is where anything walking the layout against the world has to start.
function SDFGrid2D.corner(layout: Layout): Vector2
	local half = layout.voxelSize * 0.5
	return layout.origin - Vector2.new(half, half)
end

-- A number standing in for "further than anything in this grid". Not math.huge:
-- the transform below subtracts one of these from another, and infinity minus
-- infinity is not a number, where 1e20 minus 1e20 is nothing at all.
local FAR = 1e20

--[[
	The exact squared distance transform of one line of cells, in cells, along a
	stride through the flat grid. Every cell starts at 0 where the thing being
	measured is and FAR where it is not, and ends up holding the squared distance
	to the nearest cell that started at 0.

	Felzenszwalb and Huttenlocher's lower envelope of parabolas. Reading a line as
	one upward parabola per cell -- rooted at that cell, raised by whatever is
	already known there -- the transform of the line is the lowest of those
	parabolas at each point. The first loop walks the cells keeping only the
	parabolas that are lowest somewhere, `parabolas[k]` being the kth of them and
	`boundaries[k]` where it takes over from the one before, and the second reads
	the envelope off at every cell. Both are linear in the length of the line,
	which is what makes the whole grid linear in two passes of this -- X, then Z --
	rather than a search around every cell.

	`line`, `parabolas` and `boundaries` are scratch of at least `count` entries,
	handed in so they are allocated once for the grid rather than once a line.
]]
local function transformLine(
	grid: { number },
	start: number,
	stride: number,
	count: number,
	line: { number },
	parabolas: { number },
	boundaries: { number }
)
	for i = 0, count - 1 do
		line[i] = grid[start + i * stride]
	end

	local k = 0
	parabolas[0] = 0
	boundaries[0] = -FAR
	boundaries[1] = FAR

	for q = 1, count - 1 do
		-- Where this cell's parabola crosses the last one kept. Written out twice
		-- rather than called, because this is the innermost work of the whole
		-- field: two passes of it over every cell.
		local p = parabolas[k]
		local crossing = ((line[q] + q * q) - (line[p] + p * p)) / (2 * (q - p))

		-- It dips under that one before that one even began, so that one is
		-- lowest nowhere and goes.
		while k > 0 and crossing <= boundaries[k] do
			k -= 1
			p = parabolas[k]
			crossing = ((line[q] + q * q) - (line[p] + p * p)) / (2 * (q - p))
		end

		k += 1
		parabolas[k] = q
		boundaries[k] = crossing
		boundaries[k + 1] = FAR
	end

	k = 0
	for q = 0, count - 1 do
		while boundaries[k + 1] < q do
			k += 1
		end

		local offset = q - parabolas[k]
		grid[start + q * stride] = offset * offset + line[parabolas[k]]
	end
end

-- The squared distance, in cells, from every cell to the nearest cell that is
-- marked -- or to the nearest that is not, when `to` is false, which is the same
-- question asked of the ground around the marks.
local function squaredDistances(marked: { boolean }, to: boolean, countX: number, countZ: number)
	local total = countX * countZ
	local grid = table.create(total)

	for i = 1, total do
		grid[i] = if (marked[i] == true) == to then 0 else FAR
	end

	local longest = math.max(countX, countZ)
	local line = table.create(longest)
	local parabolas = table.create(longest)
	local boundaries = table.create(longest + 1)

	for k = 0, countZ - 1 do
		transformLine(grid, 1 + k * countX, 1, countX, line, parabolas, boundaries)
	end

	for i = 0, countX - 1 do
		transformLine(grid, 1 + i, countX, countZ, line, parabolas, boundaries)
	end

	return grid
end

--[[
	Measures a field over `layout` from a rectangle of cells already marked as
	inside the shape or out: `marked[1 + i + countX * k]` is true where cell (i, k)
	is part of it. This is the way in for a shape that is only known cell by cell in
	the first place, terrain material being the case in hand -- there is no outline
	to ask a distance of, only which cells are the material.

	The distance a cell gets is to the boundary *between* the marked cells and the
	unmarked ones, not to the nearest marked centre: that boundary runs along the
	edges they share, half a cell from the centres on either side, so half a cell
	comes off every distance. A cell touching the marked region edge-on then reads
	exactly half a cell out, its marked neighbour exactly half a cell in, and the
	boundary sits at zero between them where it belongs.

	Distances are measured centre to centre, so they are only ever multiples of the
	cell size before that shift. A field this coarse is not the shape of the marked
	region in any fine sense -- it is as much of one as cells can carry.
]]
function SDFGrid2D.fromCells(layout: Layout, marked: { boolean }, source: Instance?): Grid
	local voxelSize = layout.voxelSize
	local countX, countZ = layout.resolution.X, layout.resolution.Y
	local total = countX * countZ

	local outward = squaredDistances(marked, true, countX, countZ)
	local inward = squaredDistances(marked, false, countX, countZ)

	local half = voxelSize * 0.5
	local distances = table.create(total)

	for i = 1, total do
		if marked[i] then
			distances[i] = -(math.sqrt(inward[i]) * voxelSize - half)
		else
			distances[i] = math.sqrt(outward[i]) * voxelSize - half
		end
	end

	return {
		origin = layout.origin,
		voxelSize = voxelSize,
		resolution = layout.resolution,
		dimensions = Vector2.new((countX - 1) * voxelSize, (countZ - 1) * voxelSize),
		distances = distances,
		source = source,
	}
end

-- Is this what a node produced when a grid was expected? A wire can be pointed
-- at any node from the Explorer, so a mask input may be fed points, or nothing.
function SDFGrid2D.is(value: any): boolean
	return typeof(value) == "table" and typeof(value.origin) == "Vector2" and typeof(value.distances) == "table"
end

-- How far the given world point is from the measured boundary, negative inside it.
-- The point's height is not read: the field is flat, and a spot is as near the
-- water below it as the water is to it.
--
-- Read between the four cell centres around the point, so the field reads as a
-- smooth distance rather than in steps of a cell.
--
-- A point past the edge of the grid is still answered, and answered safely: the
-- field is read at the nearest place it was measured and then pushed out by
-- however far the point actually is from there. Distance to a boundary changes no
-- faster than distance itself, so that can only ever overstate how far away a
-- point is -- it never claims a point is closer to the boundary than it is.
function SDFGrid2D.sample(grid: Grid, point: Vector3): number
	local resolution = grid.resolution
	local lastX, lastZ = resolution.X - 1, resolution.Y - 1

	-- Where the point sits in cells from the origin, and where in the grid that is
	-- once it has been brought inside it.
	local atX = (point.X - grid.origin.X) / grid.voxelSize
	local atZ = (point.Z - grid.origin.Y) / grid.voxelSize
	local x = math.clamp(atX, 0, lastX)
	local z = math.clamp(atZ, 0, lastZ)

	local x0, z0 = math.floor(x), math.floor(z)
	local x1, z1 = math.min(x0 + 1, lastX), math.min(z0 + 1, lastZ)
	local tx, tz = x - x0, z - z0

	local distances = grid.distances
	local countX = resolution.X

	local function distanceAt(i: number, k: number): number
		return distances[1 + i + k * countX]
	end

	local function lerp(a: number, b: number, t: number): number
		return a + (b - a) * t
	end

	local low = lerp(distanceAt(x0, z0), distanceAt(x1, z0), tx)
	local high = lerp(distanceAt(x0, z1), distanceAt(x1, z1), tx)

	-- Whatever bringing the point inside the grid moved it by is distance the point
	-- is from the boundary as surely as the field it landed on.
	local beyond = Vector2.new(atX - x, atZ - z).Magnitude * grid.voxelSize

	return lerp(low, high, tz) + beyond
end

return SDFGrid2D
