--[[
	GridLayout2D

	Where a flat grid sits over the ground being scattered, how finely it is
	divided, and how a value is read back out of one.

	Two kinds of thing are measured onto such a grid -- a distance field, and a
	density texture -- and they have to agree about where their cells are, so where
	the cells are lives here rather than in either of them. Everything in the plane
	is a Vector2 of world X and Z: read the `Y` of one of these as the world's Z,
	and nothing here has a height at all.

	The rectangle comes from the volumes being scattered: `layoutFor` settles it
	before any node runs and the evaluator hands it down the graph, so what a field
	or a texture covers answers to the ground being scattered rather than to
	whichever node happens to measure it. How finely that rectangle is divided is
	the one part a node may ask for, since two grids of different cell sizes still
	cover the same ground and are still read the same way -- by sampling a world
	position, not an index.
]]

local GridLayout2D = {}

-- Where a grid sits and how finely it is divided, without anything measured onto
-- it: the part that is decided before anything is measured at all, and so the part
-- that can be settled once and shared. Anything measured onto a layout carries
-- these same three fields, so a grid is a layout as far as reading it goes.
export type Layout = {
	-- World X and Z of the centre of the cell at (0, 0).
	origin: Vector2,
	-- The edge length of one cell, in studs, after the budget below has had its
	-- say. Not necessarily the size that was asked for.
	voxelSize: number,
	-- How many cells across X and Z. Whole numbers, at least two.
	resolution: Vector2,
}

-- How far past the region of interest a grid reaches, in cells. Two is enough that
-- a sample just outside it still lands between measured cells rather than against
-- the edge of the grid.
local PADDING_CELLS = 2

-- Below this a cell is finer than any placement decision could use, and the count
-- of them climbs as the square of it.
local MIN_VOXEL_SIZE = 0.1

-- Terrain is stored on a four stud grid and reads back at that and nothing else,
-- so a grid over the world starts there. It is the finest a material boundary is
-- known to, and no amount of grid would invent more.
local TERRAIN_VOXEL = 4

GridLayout2D.TERRAIN_VOXEL = TERRAIN_VOXEL

-- The most cells one grid may hold. Ten million is a few hundred megabytes and
-- some seconds while a graph is being evaluated. Flat, that is a great deal of
-- ground -- twelve thousand studs square at terrain's own four studs -- so this is
-- a backstop against a mistyped parameter rather than a limit anything real meets.
local MAX_CELLS = 10000000

-- The ground a layout covers: everything the volume group reaches in X and Z,
-- snapped out to whole cells of the size being measured at, and padded by a couple
-- of them so the grid carries on a little way past the ground being scattered.
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
	The grid over a volume group: the ground the volumes cover, divided into cells
	`voxelSize` across -- terrain's own four studs, where the caller has no opinion.

	Cells double -- to eight studs, then sixteen -- until the grid fits the budget,
	with a warning saying so. Doubling rather than scaling keeps whatever alignment
	with the terrain grid the size asked for had.
]]
function GridLayout2D.layoutFor(volumes, requested: number?): Layout
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
			-- default layout is settled for every run whether anything is measured
			-- over it or not, and has nobody to tell.
			if requested ~= nil and voxelSize > asked then
				warn(
					string.format(
						"ScatterGraph: %s covers %.0f x %.0f studs, too much ground to measure over at a %g "
							.. "stud cell within the %d one grid may hold, so it was measured at %g studs "
							.. "instead. Raise Voxel Size to choose the resolution yourself.",
						volumes.name,
						span.X,
						span.Y,
						asked,
						MAX_CELLS,
						voxelSize
					)
				)
			end

			-- A grid holds its values at cell centres, so it begins half a cell in
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
function GridLayout2D.corner(layout: Layout): Vector2
	local half = layout.voxelSize * 0.5
	return layout.origin - Vector2.new(half, half)
end

-- How much of the world the cell centres span, in studs: the distance from the
-- first centre to the last, each way.
function GridLayout2D.dimensions(layout: Layout): Vector2
	return Vector2.new((layout.resolution.X - 1) * layout.voxelSize, (layout.resolution.Y - 1) * layout.voxelSize)
end

-- Is this a table measured onto a layout at all? What was measured is the caller's
-- to check; this is only the shape of the grid it sits on.
function GridLayout2D.isLaidOut(value: any): boolean
	return typeof(value) == "table" and typeof(value.origin) == "Vector2" and typeof(value.resolution) == "Vector2"
end

--[[
	Reads `values` -- one number per cell of `layout`, X fastest -- at a world
	position, between the four cell centres around it so it reads smoothly rather
	than in steps of a cell. The position's height is not read: the grid is flat.

	A position past the edge of the grid is answered at the nearest place the grid
	was measured, so the edge cells carry on outwards. A grid is padded a couple of
	cells past the ground being scattered, so that only comes up for a point well
	outside the volumes.
]]
function GridLayout2D.read(layout: Layout, values: { number }, point: Vector3): number
	local resolution = layout.resolution
	local lastX, lastZ = resolution.X - 1, resolution.Y - 1

	-- Where the point sits in cells from the origin, brought inside the grid.
	local x = math.clamp((point.X - layout.origin.X) / layout.voxelSize, 0, lastX)
	local z = math.clamp((point.Z - layout.origin.Y) / layout.voxelSize, 0, lastZ)

	local x0, z0 = math.floor(x), math.floor(z)
	local x1, z1 = math.min(x0 + 1, lastX), math.min(z0 + 1, lastZ)
	local tx, tz = x - x0, z - z0

	local countX = resolution.X

	local function valueAt(i: number, k: number): number
		return values[1 + i + k * countX]
	end

	local function lerp(a: number, b: number, t: number): number
		return a + (b - a) * t
	end

	local low = lerp(valueAt(x0, z0), valueAt(x1, z0), tx)
	local high = lerp(valueAt(x0, z1), valueAt(x1, z1), tx)

	return lerp(low, high, tz)
end

return GridLayout2D
