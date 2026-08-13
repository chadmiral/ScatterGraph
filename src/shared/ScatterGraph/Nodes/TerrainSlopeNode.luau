--[[
	TerrainSlopeNode

	How steep the ground is, as a [Texture2D]: black on the flat, white on a wall,
	and the greys between in proportion to the angle.

	The angle over ninety degrees, so a shade is a slope you can name -- a thirty
	degree bank reads a third, forty-five reads a half. That is deliberately not the
	measure `SnapPointsToTerrain`'s SlopeFilter uses, which is one minus the cosine
	of the same angle and so spends most of its range on the steep end: forty-five
	degrees reads 0.29 there. A filter curve is drawn by eye against what it does to
	a scatter, where that hardly matters; a texture is read as a number and wired
	into arithmetic, where a shade meaning half the angle rather than some cosine of
	it matters a great deal.

	Steepness is a thing the ground has across a distance rather than at a point, so
	Kernel is the distance: the cells to each side the height is compared across. One
	cell either way is the finest the grid can say and reads every bump; a larger
	kernel reads the hillside a bump sits on. A scatter that wants to keep off cliffs
	wants a small kernel, and one that wants to keep to the valley floor a large one.

	Wired into a Density slot with a curve upstream of nothing at all, this is the
	usual way to keep trees off the crags and scree on them.
]]

local TerrainHeightfield = require(script.Parent.Parent:WaitForChild("TerrainHeightfield"))
local TerrainTextureNode = require(script.Parent:WaitForChild("TerrainTextureNode"))

local TerrainSlopeNode = TerrainTextureNode:new()
TerrainSlopeNode.name = "TerrainSlopeNode"
TerrainSlopeNode._type = "TerrainSlopeNode"
TerrainSlopeNode.measures = "how steep the ground is"
TerrainSlopeNode.usesKernel = true

-- The angle a wall stands at, which is what the range is measured against: ground
-- cannot lean past it, since past it is the same slope facing the other way.
local UPRIGHT = math.pi * 0.5

TerrainSlopeNode.valuesFrom = function(field: TerrainHeightfield.Field, _node: Instance, kernel: number): { number }
	local countX, countZ = field.layout.resolution.X, field.layout.resolution.Y
	local values = table.create(field.cells, 0)
	local at = 1

	for k = 0, countZ - 1 do
		for i = 0, countX - 1 do
			if field.found[at] then
				local alongX, alongZ = TerrainHeightfield.gradientAt(field, i, k, kernel)

				-- The steepest rise at this cell, whichever way it runs: the length
				-- of the gradient is the tangent of the angle the ground leans at,
				-- so this reads back as an angle rather than as studs per stud.
				local rise = math.sqrt(alongX * alongX + alongZ * alongZ)
				values[at] = math.atan(rise) / UPRIGHT
			end

			at += 1
		end
	end

	return values
end

return TerrainSlopeNode
