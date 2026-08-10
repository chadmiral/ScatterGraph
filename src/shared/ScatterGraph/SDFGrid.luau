--[[
	SDFGrid

	A part's surface, measured onto a grid: a box of voxels covering the part,
	each holding how far its centre is from the nearest point on that surface,
	negative inside. A field like this answers "how close is this point to that
	shape" in constant time however complicated the shape, which is what lets a
	scatter of tens of thousands of points be masked around one.

	The grid travels between nodes as one value, so it carries what is needed to
	read it as well as the distances themselves: where it starts, how big a voxel
	is, and how many of them it holds along each axis. A node handed one needs
	nothing else to sample it.

	The box is the part's world-axis-aligned bounding box, grown by a couple of
	voxels so the field is measured a little way outside the part as well as
	within it. Sampling further out than that is still answered, and answered
	safely: the field is read at the nearest place it was measured and then pushed
	out by however far the point actually is from there. Distance to a surface
	changes no faster than distance itself, so that can only ever overstate how
	far away a point is -- it never claims a point is closer to the surface than
	it is, and for a box, the shape a bounding box fits exactly, it is exact.

	Voxels are counted before they are filled: a fine voxel size over a large
	part is millions of them, so a budget coarsens the field rather than letting
	a stray parameter hang Studio.
]]

local VolumeShape = require(script.Parent:WaitForChild("VolumeShape"))

local SDFGrid = {}

export type Grid = {
	-- World position of the centre of the voxel at (0, 0, 0).
	origin: Vector3,
	-- The edge length of one voxel, in studs, after the budget below has had its
	-- say. Not necessarily the size that was asked for.
	voxelSize: number,
	-- How many voxels along each axis. Whole numbers, at least two.
	resolution: Vector3,
	-- How much of the world the voxel centres span, in studs: the distance from
	-- the first centre to the last along each axis.
	dimensions: Vector3,
	-- The signed distance at every voxel centre, X fastest, then Y, then Z.
	distances: { number },
	-- The part the field was measured from, so anything reading one can say where
	-- it came from.
	source: BasePart,
}

-- How far past the part's bounding box the field is measured, in voxels. Two is
-- enough that a sample just outside the part still lands between measured
-- voxels rather than against the edge of the grid.
local PADDING_VOXELS = 2

-- Below this a voxel is finer than any placement decision could use, and the
-- count of them climbs as the cube of it.
local MIN_VOXEL_SIZE = 0.1

-- The most voxels one field may hold. A million is a few tens of megabytes while
-- a graph is being evaluated, and enough for a 100 x 100 x 100 stud volume at a
-- one stud voxel.
local MAX_VOXELS = 1000000

-- The voxel size the part actually gets: the one asked for, coarsened until the
-- field fits the budget. Scaling by the cube root of the overrun lands within a
-- voxel of the budget in one step, and the loop then walks off the rounding.
local function affordableVoxelSize(part: BasePart, span: Vector3, voxelSize: number): number
	voxelSize = math.max(voxelSize, MIN_VOXEL_SIZE)

	local function countAt(size: number): number
		local x = math.ceil(span.X / size) + 1 + PADDING_VOXELS * 2
		local y = math.ceil(span.Y / size) + 1 + PADDING_VOXELS * 2
		local z = math.ceil(span.Z / size) + 1 + PADDING_VOXELS * 2
		return x * y * z
	end

	local count = countAt(voxelSize)
	if count <= MAX_VOXELS then
		return voxelSize
	end

	local coarsened = voxelSize * (count / MAX_VOXELS) ^ (1 / 3)
	while countAt(coarsened) > MAX_VOXELS do
		coarsened *= 1.1
	end

	warn(
		string.format(
			"ScatterGraph: a voxel size of %g over %s would be %d voxels, past the %d one field may hold, so "
				.. "the field was measured at %g instead. Raise Voxel Size to choose the resolution yourself.",
			voxelSize,
			part.Name,
			count,
			MAX_VOXELS,
			coarsened
		)
	)

	return coarsened
end

-- Measures `part` onto a grid of voxels `voxelSize` across.
function SDFGrid.fromPart(part: BasePart, voxelSize: number): Grid
	local low, high = VolumeShape.worldBounds(part)
	local size = affordableVoxelSize(part, high - low, voxelSize)

	local padding = size * PADDING_VOXELS
	local origin = low - Vector3.new(padding, padding, padding)
	local span = (high + Vector3.new(padding, padding, padding)) - origin

	-- Counting centres rather than cells, and at least two along every axis, so
	-- there is always a pair to interpolate between however flat the part is.
	local countX = math.max(2, math.ceil(span.X / size) + 1)
	local countY = math.max(2, math.ceil(span.Y / size) + 1)
	local countZ = math.max(2, math.ceil(span.Z / size) + 1)

	local distanceTo = VolumeShape.signedDistanceFunction(part)
	local distances = table.create(countX * countY * countZ)
	local at = 1

	for k = 0, countZ - 1 do
		local z = origin.Z + k * size

		for j = 0, countY - 1 do
			local y = origin.Y + j * size

			for i = 0, countX - 1 do
				distances[at] = distanceTo(Vector3.new(origin.X + i * size, y, z))
				at += 1
			end
		end
	end

	return {
		origin = origin,
		voxelSize = size,
		resolution = Vector3.new(countX, countY, countZ),
		dimensions = Vector3.new((countX - 1) * size, (countY - 1) * size, (countZ - 1) * size),
		distances = distances,
		source = part,
	}
end

-- Is this what a node produced when a grid was expected? A wire can be pointed
-- at any node from the Explorer, so a mask input may be fed points, or nothing.
function SDFGrid.is(value: any): boolean
	return typeof(value) == "table" and typeof(value.origin) == "Vector3" and typeof(value.distances) == "table"
end

-- How far the given world point is from the measured surface, negative inside
-- it. Read between the eight voxel centres around the point, so the field reads
-- as a smooth distance rather than in steps of a voxel.
function SDFGrid.sample(grid: Grid, point: Vector3): number
	local resolution = grid.resolution
	local lastX, lastY, lastZ = resolution.X - 1, resolution.Y - 1, resolution.Z - 1

	-- Where the point sits in voxels from the origin, and where in the grid that
	-- is once it has been brought inside it.
	local at = (point - grid.origin) / grid.voxelSize
	local x = math.clamp(at.X, 0, lastX)
	local y = math.clamp(at.Y, 0, lastY)
	local z = math.clamp(at.Z, 0, lastZ)

	local x0, y0, z0 = math.floor(x), math.floor(y), math.floor(z)
	local x1, y1, z1 = math.min(x0 + 1, lastX), math.min(y0 + 1, lastY), math.min(z0 + 1, lastZ)
	local tx, ty, tz = x - x0, y - y0, z - z0

	local distances = grid.distances
	local strideY = resolution.X
	local strideZ = resolution.X * resolution.Y

	local function distanceAt(i: number, j: number, k: number): number
		return distances[1 + i + j * strideY + k * strideZ]
	end

	local function lerp(a: number, b: number, t: number): number
		return a + (b - a) * t
	end

	local lowZ = lerp(
		lerp(distanceAt(x0, y0, z0), distanceAt(x1, y0, z0), tx),
		lerp(distanceAt(x0, y1, z0), distanceAt(x1, y1, z0), tx),
		ty
	)
	local highZ = lerp(
		lerp(distanceAt(x0, y0, z1), distanceAt(x1, y0, z1), tx),
		lerp(distanceAt(x0, y1, z1), distanceAt(x1, y1, z1), tx),
		ty
	)

	-- Whatever bringing the point inside the grid moved it by is distance the
	-- point is from the surface as surely as the field it landed on.
	local beyond = (at - Vector3.new(x, y, z)).Magnitude * grid.voxelSize

	return lerp(lowZ, highZ, tz) + beyond
end

return SDFGrid
