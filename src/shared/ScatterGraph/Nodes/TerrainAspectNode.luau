--[[
	TerrainAspectNode

	Which way the ground faces, as a [Texture2D]: the compass bearing a slope runs
	down, once round the compass over the range of the texture. North is 0, east a
	quarter, south a half, west three quarters, and north again 1 -- so both ends of
	the range are the same direction, which is what a bearing is and not a mistake.

	North is negative Z and east is positive X, which is the compass Studio's own
	camera starts out facing along and the one every other tool here assumes. There
	is no north in a Roblox place to be right or wrong about; this is the convention,
	stated so a rule can be written against it.

	What it is for is the difference between the two sides of a hill: a south face
	takes the sun, dries out, and grows different things from the north face above
	the same valley. Wired into a Density slot through a curve, that is a scatter
	that knows which side of the ridge it is on.

	Two things to know about it. Flat ground has no direction to face, and reads 0
	like true north -- so anything using this seriously wants a slope texture
	alongside to say where a direction means anything. And a bearing wraps where the
	picture does not: a cell facing a little east of north sits next to one facing a
	little west of north, 0.02 beside 0.98, and reading between them passes through
	south. It is a seam one cell wide along every north-facing slope, and it is in
	the nature of flattening a circle onto a number.
]]

local TerrainHeightfield = require(script.Parent.Parent:WaitForChild("TerrainHeightfield"))
local TerrainTextureNode = require(script.Parent:WaitForChild("TerrainTextureNode"))

local TerrainAspectNode = TerrainTextureNode:new()
TerrainAspectNode.name = "TerrainAspectNode"
TerrainAspectNode._type = "TerrainAspectNode"
TerrainAspectNode.measures = "which way the ground faces"
TerrainAspectNode.usesKernel = true

local TURN = math.pi * 2

-- Where a bearing is flat ground's, which has none. North, for want of anywhere
-- else in the range to put it.
local NO_DIRECTION = 0

TerrainAspectNode.valuesFrom = function(field: TerrainHeightfield.Field, _node: Instance, kernel: number): { number }
	local countX, countZ = field.layout.resolution.X, field.layout.resolution.Y
	local values = table.create(field.cells, NO_DIRECTION)
	local at = 1

	for k = 0, countZ - 1 do
		for i = 0, countX - 1 do
			if field.found[at] then
				local alongX, alongZ = TerrainHeightfield.gradientAt(field, i, k, kernel)

				if alongX ~= 0 or alongZ ~= 0 then
					-- A gradient runs uphill and a slope faces down it, so the
					-- direction wanted is the other one. North being negative Z is
					-- what puts the sign on the northward part.
					local eastward = -alongX
					local northward = alongZ

					-- Clockwise from north, which is how a bearing is quoted and the
					-- opposite way round from how an angle is usually taken: east
					-- first, north second, and atan2 turns the pair into the turn
					-- from the second towards the first.
					local bearing = math.atan2(eastward, northward)
					if bearing < 0 then
						bearing += TURN
					end

					values[at] = bearing / TURN
				end
			end

			at += 1
		end
	end

	return values
end

return TerrainAspectNode
