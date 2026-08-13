--[[
	TerrainHeightNode

	How high the ground is, as a [Texture2D]: a heightmap of the terrain under the
	volumes being scattered, black at the lowest ground and white at the highest.

	The range is the ground's own -- the lowest and highest terrain found under the
	volumes, not the volumes' height and not the world's -- so the picture uses all
	of its greys over whatever relief is actually there. A gentle biome and an alpine
	one both run black to white; what differs is how many studs a shade is worth.
	That makes it a mask for "high ground" and "low ground" in the terms of this
	place, which is almost always what a rule means, and makes it worth nothing at
	all for comparing two places.

	Wired into a Density slot it thins a scatter with altitude, which is most of
	what altitude does to what grows: white keeps everything at the top and black
	nothing at the bottom. Turned over -- a heightmap read the other way -- is a
	valley-floor mask, and that is a thing to build in the graph rather than a
	parameter here.
]]

local TerrainHeightfield = require(script.Parent.Parent:WaitForChild("TerrainHeightfield"))
local TerrainTextureNode = require(script.Parent:WaitForChild("TerrainTextureNode"))

local TerrainHeightNode = TerrainTextureNode:new()
TerrainHeightNode.name = "TerrainHeightNode"
TerrainHeightNode._type = "TerrainHeightNode"
TerrainHeightNode.measures = "how high the ground is"

-- Height is what the cell itself measured, so there is nothing to compare it
-- against and no kernel to do it across.
TerrainHeightNode.usesKernel = false

-- What ground of no relief at all reads as. Its one height is the top of its range
-- as much as the bottom, so either end could be argued; white is the end that does
-- not quietly delete a scatter that is masked against it.
local FLAT_GROUND = 1

TerrainHeightNode.valuesFrom = function(field: TerrainHeightfield.Field, node: Instance, _kernel: number): { number }
	local range = field.highest - field.lowest
	local values = table.create(field.cells, 0)

	if field.hits > 0 and range <= 0 then
		warn(
			string.format(
				"ScatterGraph %s: every bit of ground under it is at %.1f studs, so there is no range of "
					.. "heights to spread across the greys and the whole texture reads as %g.",
				node.Name,
				field.highest,
				FLAT_GROUND
			)
		)
	end

	for at = 1, field.cells do
		if not field.found[at] then
			-- No ground under this cell, which is lower than the lowest ground
			-- rather than level with it.
			values[at] = 0
		elseif range <= 0 then
			values[at] = FLAT_GROUND
		else
			values[at] = (field.heights[at] - field.lowest) / range
		end
	end

	return values
end

return TerrainHeightNode
