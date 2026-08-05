--[[
	VolumeGroup

	The set of scatter volumes that share one biome definition, treated as a
	single region. Overlapping volumes in a group behave as a union rather than
	scattering twice over the same ground: the graph is evaluated once for the
	whole group, and these queries answer for the group as a whole.

	Volumes in a group need not touch. A group of far-apart patches is fine,
	which is why the footprint is exposed as a per-volume list of bounds rather
	than as one rectangle around everything.

	Volumes pointing at *different* biome definitions stay independent, so two
	different biomes still overlap and interleave the way they always have.
]]

local VolumeShape = require(script.Parent:WaitForChild("VolumeShape"))

local VolumeGroup = {}
VolumeGroup.__index = VolumeGroup

-- The bounding-box rejections below are only a fast path in front of the exact
-- shape tests, so they are widened past VolumeShape's own surface tolerance. A
-- point sitting on a volume's floor must never be lost to rounding here.
local BOUNDS_MARGIN = 0.01

export type Bounds = {
	minX: number,
	maxX: number,
	minY: number,
	maxY: number,
	minZ: number,
	maxZ: number,
}

function VolumeGroup.new(parts: { BasePart })
	local self = setmetatable({}, VolumeGroup)

	self.parts = parts
	self.name = if #parts == 1 then parts[1].Name else parts[1].Name .. " (+" .. (#parts - 1) .. " more)"

	-- Per-part queries are built once: a part's CFrame and Size are read when the
	-- closure is made, and a graph evaluation is a single pass. Each part's
	-- bounding box is kept alongside so the group's queries, which run per grid
	-- cell, can reject a distant volume with a few comparisons.
	self._bounds = {} :: { Bounds }
	self._footprints = {}
	self._containers = {}

	local top, bottom = -math.huge, math.huge
	for _, part in parts do
		local minX, maxX, minZ, maxZ = VolumeShape.footprintBounds(part)
		local partTop, partHeight = VolumeShape.verticalBounds(part)
		local partBottom = partTop - partHeight

		table.insert(self._bounds, {
			minX = minX,
			maxX = maxX,
			minY = partBottom,
			maxY = partTop,
			minZ = minZ,
			maxZ = maxZ,
		})
		table.insert(self._footprints, VolumeShape.footprintFunction(part))
		table.insert(self._containers, VolumeShape.containsPointFunction(part))

		top = math.max(top, partTop)
		bottom = math.min(bottom, partBottom)
	end

	self._top = top
	self._bottom = bottom

	return self
end

-- World-space bounds of each volume, for callers that walk the ground area the
-- group covers.
function VolumeGroup:footprintBoundsList(): { Bounds }
	return self._bounds
end

-- Is the vertical world-space line through (x, z) inside *any* volume? This is
-- what makes the group a union: ground covered by two volumes is still just
-- covered, not covered twice.
function VolumeGroup:footprintFunction(): (number, number) -> boolean
	local bounds = self._bounds
	local footprints = self._footprints

	return function(x: number, z: number)
		for index, box in bounds do
			if
				x >= box.minX - BOUNDS_MARGIN
				and x <= box.maxX + BOUNDS_MARGIN
				and z >= box.minZ - BOUNDS_MARGIN
				and z <= box.maxZ + BOUNDS_MARGIN
			then
				if footprints[index](x, z) then
					return true
				end
			end
		end

		return false
	end
end

-- Is a world-space point inside any volume?
function VolumeGroup:containsPointFunction(): (Vector3) -> boolean
	local bounds = self._bounds
	local containers = self._containers

	return function(point: Vector3)
		for index, box in bounds do
			if
				point.X >= box.minX - BOUNDS_MARGIN
				and point.X <= box.maxX + BOUNDS_MARGIN
				and point.Y >= box.minY - BOUNDS_MARGIN
				and point.Y <= box.maxY + BOUNDS_MARGIN
				and point.Z >= box.minZ - BOUNDS_MARGIN
				and point.Z <= box.maxZ + BOUNDS_MARGIN
			then
				if containers[index](point) then
					return true
				end
			end
		end

		return false
	end
end

-- Height to start a downward ray from, and the length that covers every volume
-- in the group.
function VolumeGroup:verticalBounds(): (number, number)
	return self._top, self._top - self._bottom
end

-- Middle of the group's vertical span: where unsnapped points sit.
function VolumeGroup:centerHeight(): number
	return (self._top + self._bottom) * 0.5
end

return VolumeGroup
