--[[
	SDFGrid2D

	A shape on the ground, measured onto a grid: a rectangle of cells covering it,
	each holding how far its centre is from the nearest edge of the shape, negative
	inside. A field like this answers "how close is this spot to that shape" in
	constant time however complicated the shape -- which is what lets a whole biome
	be shaped around water, or a road, at the cost of measuring it once.

	The field is flat, and sits on a [GridLayout2D] like everything else measured
	over the ground being scattered. It travels between nodes as one value, carrying
	that layout along with the distances, so a node handed one needs nothing else to
	read it: cell by cell, as [SDFThreshold2DNode] does when it cuts one into a
	density texture, or at a world position through `GridLayout2D.read`.

	`fromCells` fills one from a region already marked off cell by cell -- terrain
	material, say, which is only ever known that coarsely -- and works the distances
	out from the marks themselves.
]]

local GridLayout2D = require(script.Parent:WaitForChild("GridLayout2D"))

local SDFGrid2D = {}

export type Grid = {
	-- Where the field sits and how finely it is measured.
	origin: Vector2,
	voxelSize: number,
	resolution: Vector2,
	-- How much ground the cell centres span, in studs.
	dimensions: Vector2,
	-- The signed distance at every cell centre, X fastest, then Z.
	distances: { number },
	-- What the field was measured from -- the terrain -- so anything reading one
	-- can say where it came from.
	source: Instance?,
}

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
function SDFGrid2D.fromCells(layout: GridLayout2D.Layout, marked: { boolean }, source: Instance?): Grid
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
		dimensions = GridLayout2D.dimensions(layout),
		distances = distances,
		source = source,
	}
end

-- Is this what a node produced when a field was expected? A wire can be pointed at
-- any node from the Explorer, so a slot may be fed points, or a texture, or
-- nothing.
function SDFGrid2D.is(value: any): boolean
	return GridLayout2D.isLaidOut(value) and typeof(value.distances) == "table"
end

return SDFGrid2D
