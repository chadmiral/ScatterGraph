--[[
	TerrainTextureNode

	What the four nodes that read the ground and hand back a [Texture2D] have in
	common: Terrain Height, Terrain Slope, Terrain Aspect and Terrain Curvature.

	Each of them is one pass over a [TerrainHeightfield] and some arithmetic per
	cell, so all that is here is getting to that heightfield -- the resolution to
	measure at, the grid to measure onto, the kernel to difference across, the
	cache, and the complaint when there is no ground under the volumes at all. A
	node built on this says what it measures and fills in the values; nothing else.

	None of them take a wire. What they measure is the ground under the volumes
	being scattered, which the run knows before the graph is walked, so there is
	nothing upstream of one of these -- they are where a graph starts, the way the
	noise texture is.
]]

local GraphNode = require(script.Parent:WaitForChild("GraphNode"))
local GridLayout2D = require(script.Parent.Parent:WaitForChild("GridLayout2D"))
local TerrainHeightfield = require(script.Parent.Parent:WaitForChild("TerrainHeightfield"))
local Texture2D = require(script.Parent.Parent:WaitForChild("Texture2D"))

local TerrainTextureNode = GraphNode:new()
TerrainTextureNode.name = "TerrainTextureNode"
TerrainTextureNode._type = "TerrainTextureNode"

-- What this reads off the ground, as it would be said in a sentence: only used to
-- explain the node in a warning.
TerrainTextureNode.measures = "the ground"

-- Whether the arithmetic compares one cell against others, and so whether the
-- Kernel attribute means anything on this node. A heightmap is a cell on its own;
-- everything derived from the lie of the ground is not.
TerrainTextureNode.usesKernel = false

-- Cells to each side that a kernel reaches by default. One is the neighbouring
-- cells: the finest reading the grid can give, and the shape of the ground itself
-- rather than of anything smoothed over it.
local DEFAULT_KERNEL = 1

-- What this node makes of the ground, cell by cell, as one value per cell of
-- `field.layout` -- X fastest, then Z, each between 0 and 1. The node is handed in
-- because parameters past the kernel are its own business.
TerrainTextureNode.valuesFrom = function(_field: TerrainHeightfield.Field, _node: Instance, _kernel: number): { number }
	return {}
end

local function numberOr(node: Instance, name: string, fallback: number): number
	local value = node:GetAttribute(name)
	return if typeof(value) == "number" then value else fallback
end

-- Cells to each side, as a whole number of at least one. A fraction of a cell is
-- not a thing the grid can difference across, and nothing is what a kernel of zero
-- would measure.
local function kernelOf(node: Instance): number
	local asked = numberOr(node, "Kernel", DEFAULT_KERNEL)
	local settled = math.max(1, math.round(asked))

	if settled ~= asked then
		warn(
			string.format(
				"ScatterGraph %s: Kernel is %g, which is not a whole number of cells to each side, so the "
					.. "ground was compared across %d instead.",
				node.Name,
				asked,
				settled
			)
		)
	end

	return settled
end

function TerrainTextureNode:evaluate(volumes, terrain, ctx)
	local n = ctx.node

	-- Every rule masking against this node asks it for the same texture, and
	-- reading the ground is the expensive part of making one.
	local cache = ctx.fieldCache
	if cache ~= nil and cache[n] ~= nil then
		return cache[n]
	end

	local voxelSize = numberOr(n, "VoxelSize", GridLayout2D.TERRAIN_VOXEL)
	local layout = ctx.gridLayout
	if layout == nil or layout.voxelSize ~= voxelSize then
		layout = GridLayout2D.layoutFor(volumes, voxelSize)
	end

	local field = TerrainHeightfield.of(volumes, terrain, layout)

	if field.hits == 0 then
		warn(
			string.format(
				"ScatterGraph %s: there is no terrain anywhere under %s, so %s is nothing everywhere and "
					.. "this texture is black. Check the volume is over the ground it means to be.",
				n.Name,
				volumes.name,
				self.measures
			)
		)
	end

	local kernel = if self.usesKernel then kernelOf(n) else DEFAULT_KERNEL
	local texture = Texture2D.fromCells(field.layout, self.valuesFrom(field, n, kernel))

	if cache ~= nil then
		cache[n] = texture
	end

	return texture
end

return TerrainTextureNode
