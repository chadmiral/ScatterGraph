--[[
	TerrainCurvatureNode

	How the ground bends, as a [Texture2D]: the rate the slope itself changes, which
	is the second derivative of height and tells convex ground from concave. Ridges,
	hilltops and the lips of banks come out one way; gullies, hollows and the feet of
	slopes the other. Ground that is flat, and ground on an even hillside however
	steep, both come out as nothing -- an even slope does not bend.

	Positive is convex, which is the way round every map reads it and the opposite of
	the arithmetic: the second difference of height is negative at a hilltop. Kernel
	is the distance the bend is measured over, and it changes what the picture is of
	more than it does on a slope -- a cell either way finds every stone, ten cells
	either way finds the hill the stones are on.

	The value is in reciprocal studs and runs either side of zero, and a texture runs
	0 to 1, so Normalize decides how one becomes the other:

	- On, which is the default, puts no bend at mid grey and spreads the greys either
	  side of it: convex ground lighter, concave darker. It is a picture of where the
	  ground bends rather than of how much, since the scale comes from this biome's
	  own ground and nothing else -- the same hillside reads differently beside a
	  cliff than beside a lawn.
	- Off gives the curvature itself, and since a texture cannot hold a negative,
	  every concave cell in the place reads 0. Real ground bends by a hundredth of a
	  reciprocal stud or so, so what is left is nearly black as well. That is the
	  honest reading of an unnormalised signed quantity in an unsigned picture, and
	  it is only useful for reading numbers back out of a cell.

	Wired into a Density slot, normalised, this is the difference between what
	collects in a hollow -- leaf litter, ferns, standing water -- and what stands on
	an edge.
]]

local TerrainHeightfield = require(script.Parent.Parent:WaitForChild("TerrainHeightfield"))
local TerrainTextureNode = require(script.Parent:WaitForChild("TerrainTextureNode"))

local TerrainCurvatureNode = TerrainTextureNode:new()
TerrainCurvatureNode.name = "TerrainCurvatureNode"
TerrainCurvatureNode._type = "TerrainCurvatureNode"
TerrainCurvatureNode.measures = "how the ground bends"
TerrainCurvatureNode.usesKernel = true

-- Where no bend sits once the range is spread over the greys: the middle of them,
-- so that either sign has the same room and flat ground is the same shade wherever
-- it is.
local NO_BEND = 0.5

-- What fraction of the ground is allowed to be sharper than the greys can show, and
-- so to come out flat white or flat black.
--
-- Spreading the greys to the very sharpest bend in a biome does not work: terrain
-- has a handful of cells -- the lip of a quarry, the seam where two sculpted
-- patches meet, a single voxel spike -- that bend ten times as hard as any hillside
-- around them, and measured against one of those the whole place comes out mid
-- grey. Over the Elwynn terrain that is the difference between a picture using 0.39
-- to 0.61 of its range and one using nearly all of it. So the scale is the bend all
-- but the sharpest hundredth of the ground stays inside of, and that hundredth
-- saturates.
local OUTLIERS = 0.01

-- Bins the bends are counted into to find that scale, which is a pass over them
-- rather than a sort of them: a biome is tens of thousands of cells and may be
-- millions. A thousandth of the sharpest bend is a finer scale than the greys
-- themselves can hold.
local BINS = 1024

--[[
	How far either side of mid grey the greys reach, in reciprocal studs: the bend
	that all but `OUTLIERS` of the measured ground is gentler than.

	Counted into bins by size and then walked up until that much of the ground is
	behind, so what comes back is a bin edge rather than a cell's exact bend. That is
	as close as it needs to be -- it is deciding a contrast, not reporting a
	measurement.
]]
local function spreadOf(bends: { number }, found: { boolean }, cells: number, widest: number): number
	local counts = table.create(BINS, 0)
	local measured = 0

	for at = 1, cells do
		if found[at] then
			local bin = math.min(BINS, math.floor(math.abs(bends[at]) / widest * BINS) + 1)
			counts[bin] += 1
			measured += 1
		end
	end

	local inside = measured * (1 - OUTLIERS)
	local behind = 0

	for bin = 1, BINS do
		behind += counts[bin]

		if behind >= inside then
			return bin / BINS * widest
		end
	end

	return widest
end

TerrainCurvatureNode.valuesFrom = function(field: TerrainHeightfield.Field, node: Instance, kernel: number): { number }
	local countX, countZ = field.layout.resolution.X, field.layout.resolution.Y
	local normalize = node:GetAttribute("Normalize")
	-- Anything but a Boolean of false, including the attribute never having been
	-- set, means normalised: the raw form is a deliberate choice rather than a
	-- default to fall into.
	local spread = normalize ~= false

	local values = table.create(field.cells, if spread then NO_BEND else 0)
	local bends = table.create(field.cells, 0)
	local widest = 0
	local at = 1

	for k = 0, countZ - 1 do
		for i = 0, countX - 1 do
			if field.found[at] then
				local bend = TerrainHeightfield.bendAt(field, i, k, kernel)
				bends[at] = bend
				widest = math.max(widest, math.abs(bend))
			end

			at += 1
		end
	end

	if not spread then
		return bends
	end

	if widest <= 0 then
		-- Nothing bends anywhere, so there is no range to spread and every cell is
		-- already the mid grey the array was filled with.
		return values
	end

	local spread = spreadOf(bends, field.found, field.cells, widest)

	for index = 1, field.cells do
		if field.found[index] then
			values[index] = NO_BEND + NO_BEND * bends[index] / spread
		end
	end

	return values
end

return TerrainCurvatureNode
