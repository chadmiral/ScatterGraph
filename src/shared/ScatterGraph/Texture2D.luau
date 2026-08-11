--[[
	Texture2D

	A greyscale image laid over the ground, one value per cell, read at a world
	position. Projected straight down like a heightmap: a point is measured by the
	ground it stands over, whatever its height.

	Values run from 0 to 1, and what they mean is up to whatever reads one. As a
	density -- the only thing that reads one today -- a value is the chance a
	candidate point there survives: white keeps everything, black keeps nothing, and
	grey is a coin toss. That way a texture thins a scatter out rather than cutting
	it off, and several of them can shape one scatter without any of them having the
	last word.

	A texture sits on a [GridLayout2D], the same rectangle of cells a distance field
	does, so where its cells are answers to the ground being scattered rather than
	to the node that filled it. Reading between cells means an edge in a texture is
	soft by about a cell: where black meets white, the chance of survival runs
	through the greys between them rather than snapping from one to the other, which
	dithers a boundary rather than drawing a line across the scatter.
]]

local GridLayout2D = require(script.Parent:WaitForChild("GridLayout2D"))

local Texture2D = {}

export type Texture = {
	-- Where the texture sits and how finely it is divided.
	origin: Vector2,
	voxelSize: number,
	resolution: Vector2,
	-- How much ground the cell centres span, in studs.
	dimensions: Vector2,
	-- The value at every cell centre, X fastest, then Z. Each between 0 and 1.
	values: { number },
}

-- What a value outside 0 to 1 would mean is nothing, and a density outside it is a
-- certainty dressed as a chance, so filling one clamps rather than trusting the
-- caller's arithmetic.
local function clamped(value: number): number
	if value ~= value then
		-- Not a number at all, which no amount of clamping helps: nothing survives
		-- somewhere nothing can be said about.
		return 0
	end

	return math.clamp(value, 0, 1)
end

-- A texture whose cells are already worked out: `values[1 + i + countX * k]` for
-- cell (i, k). The array is taken over rather than copied, and clamped where it
-- lies -- one number per cell of a biome is not worth duplicating to be tidy.
function Texture2D.fromCells(layout: GridLayout2D.Layout, values: { number }): Texture
	for i = 1, #values do
		values[i] = clamped(values[i])
	end

	return {
		origin = layout.origin,
		voxelSize = layout.voxelSize,
		resolution = layout.resolution,
		dimensions = GridLayout2D.dimensions(layout),
		values = values,
	}
end

--[[
	A texture of one flat shade, which is how a single number reaches something
	that reads an image: a Number wired to a Density slot is that chance over the
	whole of the ground rather than a pattern across it.

	Filled cell by cell rather than kept as the one value it is, so that it is the
	same shape of thing as every other texture. What reads one has no idea where it
	came from, and a flat density is rare enough not to be worth a second kind of
	texture for everything to know about.
]]
function Texture2D.uniform(layout: GridLayout2D.Layout, value: number): Texture
	local everywhere = clamped(value)

	return {
		origin = layout.origin,
		voxelSize = layout.voxelSize,
		resolution = layout.resolution,
		dimensions = GridLayout2D.dimensions(layout),
		values = table.create(layout.resolution.X * layout.resolution.Y, everywhere),
	}
end

-- A texture filled by asking `valueAt` for every cell centre, by world X and Z.
-- The way in for anything that knows its value at a position rather than cell by
-- cell -- noise, say, which has a value everywhere and only becomes an image here.
function Texture2D.fromFunction(layout: GridLayout2D.Layout, valueAt: (number, number) -> number): Texture
	local countX, countZ = layout.resolution.X, layout.resolution.Y
	local voxelSize = layout.voxelSize
	local origin = layout.origin
	local values = table.create(countX * countZ)
	local at = 1

	for k = 0, countZ - 1 do
		local z = origin.Y + k * voxelSize

		for i = 0, countX - 1 do
			values[at] = valueAt(origin.X + i * voxelSize, z)
			at += 1
		end
	end

	return Texture2D.fromCells(layout, values)
end

-- Is this what a node produced when a texture was expected? A wire can be pointed
-- at any node from the Explorer, so a slot may be fed points, or a distance field,
-- or nothing.
function Texture2D.is(value: any): boolean
	return GridLayout2D.isLaidOut(value) and typeof(value.values) == "table"
end

-- The value at the given world point, read between the four cell centres around it.
-- The point's height is not read: the texture hangs over the ground.
function Texture2D.sample(texture: Texture, point: Vector3): number
	return GridLayout2D.read(texture, texture.values, point)
end

return Texture2D
