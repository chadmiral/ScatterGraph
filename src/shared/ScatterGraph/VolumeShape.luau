--[[
	VolumeShape

	Shape-aware geometry queries for the parts used as scatter volumes and
	exclusion volumes. Every Roblox primitive is convex, so each one is described
	in the part's object space as a set of half-spaces (n . p <= d, with unit
	normals) plus an optional sphere or cylinder radius:

	* Block       -- the six box faces.
	* Ball        -- a sphere at the center. Roblox never stretches a ball into
	                 an ellipsoid: the diameter is the smallest Size component.
	* Cylinder    -- a circular cylinder whose axis runs along X (the Roblox
	                 convention); the diameter is the smaller of Size.Y and Size.Z.
	* Wedge       -- the box, cut by the slanted face that runs from the top of
	                 the +Z edge down to the bottom of the -Z edge.
	* CornerWedge -- the box, cut by two slanted faces that meet over the
	                 (+X, -Z) corner.

	Anything else (MeshPart, unions, truss) falls back to its bounding box.

	Queries are exposed as closure factories so the per-part constants are built
	once and reused across the thousands of points a graph produces.

	The queries are whether a point or a vertical line is inside the shape, which
	is what confines a scatter to its volumes, and the bounds of the shape, which
	is what says where to look for either.
]]

local VolumeShape = {}

export type Shape = "Block" | "Ball" | "Cylinder" | "Wedge" | "CornerWedge"

type Plane = { normal: Vector3, distance: number }

type Solid = {
	planes: { Plane },
	sphereRadius: number?,
	cylinderRadius: number?,
}

-- Points that land exactly on a volume's surface -- a terrain hit on the floor
-- of a block, for instance -- must count as inside, so tests are widened by a
-- small distance (studs).
local MARGIN = 1e-3

-- Below this a dot product counts as zero: a line parallel to a plane, or a
-- vertical line parallel to a cylinder's axis.
local PARALLEL_EPSILON = 1e-9

local WORLD_UP = Vector3.new(0, 1, 0)

function VolumeShape.getShape(part: BasePart): Shape
	if part:IsA("WedgePart") then
		return "Wedge"
	elseif part:IsA("CornerWedgePart") then
		return "CornerWedge"
	elseif part:IsA("Part") then
		if part.Shape == Enum.PartType.Ball then
			return "Ball"
		elseif part.Shape == Enum.PartType.Cylinder then
			return "Cylinder"
		elseif part.Shape == Enum.PartType.Wedge then
			return "Wedge"
		elseif part.Shape == Enum.PartType.CornerWedge then
			return "CornerWedge"
		end
	end

	return "Block"
end

local function boxPlanes(halfX: number, halfY: number, halfZ: number): { Plane }
	return {
		{ normal = Vector3.new(1, 0, 0), distance = halfX },
		{ normal = Vector3.new(-1, 0, 0), distance = halfX },
		{ normal = Vector3.new(0, 1, 0), distance = halfY },
		{ normal = Vector3.new(0, -1, 0), distance = halfY },
		{ normal = Vector3.new(0, 0, 1), distance = halfZ },
		{ normal = Vector3.new(0, 0, -1), distance = halfZ },
	}
end

-- All slanted faces pass through the part's center, so their planes have a
-- distance of zero.
local function buildSolid(part: BasePart): Solid
	local shape = VolumeShape.getShape(part)
	local size = part.Size
	local halfX, halfY, halfZ = size.X * 0.5, size.Y * 0.5, size.Z * 0.5

	if shape == "Ball" then
		return {
			planes = {},
			sphereRadius = math.min(size.X, size.Y, size.Z) * 0.5,
		}
	elseif shape == "Cylinder" then
		return {
			planes = {
				{ normal = Vector3.new(1, 0, 0), distance = halfX },
				{ normal = Vector3.new(-1, 0, 0), distance = halfX },
			},
			cylinderRadius = math.min(size.Y, size.Z) * 0.5,
		}
	end

	local planes = boxPlanes(halfX, halfY, halfZ)

	if shape == "Wedge" then
		table.insert(planes, { normal = Vector3.new(0, halfZ, -halfY).Unit, distance = 0 })
	elseif shape == "CornerWedge" then
		table.insert(planes, { normal = Vector3.new(0, halfZ, halfY).Unit, distance = 0 })
		table.insert(planes, { normal = Vector3.new(-halfY, halfX, 0).Unit, distance = 0 })
	end

	return { planes = planes }
end

local function solidContains(solid: Solid, point: Vector3): boolean
	for _, plane in solid.planes do
		if plane.normal:Dot(point) > plane.distance + MARGIN then
			return false
		end
	end

	if solid.sphereRadius then
		local radius = solid.sphereRadius + MARGIN
		if point:Dot(point) > radius * radius then
			return false
		end
	end

	if solid.cylinderRadius then
		local radius = solid.cylinderRadius + MARGIN
		if point.Y * point.Y + point.Z * point.Z > radius * radius then
			return false
		end
	end

	return true
end

-- Does the infinite line through `origin` along `direction` touch the solid?
-- The line is clipped against every half-space to a [tMin, tMax] interval, then
-- against the quadric if the shape has one.
local function solidIntersectsLine(solid: Solid, origin: Vector3, direction: Vector3): boolean
	local tMin, tMax = -math.huge, math.huge

	for _, plane in solid.planes do
		local denominator = plane.normal:Dot(direction)
		local numerator = plane.distance + MARGIN - plane.normal:Dot(origin)

		if math.abs(denominator) < PARALLEL_EPSILON then
			if numerator < 0 then
				return false
			end
		else
			local t = numerator / denominator
			if denominator > 0 then
				tMax = math.min(tMax, t)
			else
				tMin = math.max(tMin, t)
			end

			if tMin > tMax then
				return false
			end
		end
	end

	local quadricOrigin, quadricDirection, radius
	if solid.sphereRadius then
		quadricOrigin, quadricDirection = origin, direction
		radius = solid.sphereRadius + MARGIN
	elseif solid.cylinderRadius then
		-- The cylinder's axis is local X, so only the YZ components matter.
		quadricOrigin = Vector3.new(0, origin.Y, origin.Z)
		quadricDirection = Vector3.new(0, direction.Y, direction.Z)
		radius = solid.cylinderRadius + MARGIN
	else
		return true
	end

	local a = quadricDirection:Dot(quadricDirection)
	local c = quadricOrigin:Dot(quadricOrigin) - radius * radius

	if a < PARALLEL_EPSILON then
		-- The line runs along the axis: it either stays inside the radius or
		-- never enters it.
		return c <= 0
	end

	local b = 2 * quadricOrigin:Dot(quadricDirection)
	local discriminant = b * b - 4 * a * c
	if discriminant < 0 then
		return false
	end

	local root = math.sqrt(discriminant)
	tMin = math.max(tMin, (-b - root) / (2 * a))
	tMax = math.min(tMax, (-b + root) / (2 * a))

	return tMin <= tMax
end

-- Returns a predicate reporting whether a world-space point is inside the
-- part's geometry.
function VolumeShape.containsPointFunction(part: BasePart): (Vector3) -> boolean
	local solid = buildSolid(part)
	local cframe = part.CFrame

	return function(point: Vector3)
		return solidContains(solid, cframe:PointToObjectSpace(point))
	end
end

-- Returns a predicate reporting whether the vertical world-space line through
-- (x, z) passes through the part. This is the part's footprint: the set of
-- ground positions a downward ray can hit it from, which is what point
-- scattering and terrain snapping care about.
function VolumeShape.footprintFunction(part: BasePart): (number, number) -> boolean
	local solid = buildSolid(part)
	local cframe = part.CFrame
	local baseY = cframe.Position.Y
	local direction = cframe:VectorToObjectSpace(WORLD_UP)

	return function(x: number, z: number)
		local origin = cframe:PointToObjectSpace(Vector3.new(x, baseY, z))
		return solidIntersectsLine(solid, origin, direction)
	end
end

-- World-space half extents of the part's bounding box. Each world axis picks up
-- a contribution from all three local axes once the part is rotated, so a volume
-- laid on its side is as wide as its Size.Y, not its Size.X.
local function worldHalfExtents(part: BasePart): Vector3
	local cframe = part.CFrame
	local size = part.Size

	local xEdge = cframe:VectorToWorldSpace(Vector3.new(size.X * 0.5, 0, 0))
	local yEdge = cframe:VectorToWorldSpace(Vector3.new(0, size.Y * 0.5, 0))
	local zEdge = cframe:VectorToWorldSpace(Vector3.new(0, 0, size.Z * 0.5))

	return Vector3.new(
		math.abs(xEdge.X) + math.abs(yEdge.X) + math.abs(zEdge.X),
		math.abs(xEdge.Y) + math.abs(yEdge.Y) + math.abs(zEdge.Y),
		math.abs(xEdge.Z) + math.abs(yEdge.Z) + math.abs(zEdge.Z)
	)
end

-- World-space X/Z bounds of the part's bounding box: the area its footprint can
-- possibly cover.
function VolumeShape.footprintBounds(part: BasePart): (number, number, number, number)
	local extents = worldHalfExtents(part)
	local center = part.CFrame.Position

	return center.X - extents.X, center.X + extents.X, center.Z - extents.Z, center.Z + extents.Z
end

-- World-space Y span of the part's bounding box, as the height to start a
-- downward ray from and the length that ray needs. The bounding box is used
-- rather than the exact shape: an overlong ray is harmless because hits are
-- still tested against the solid itself.
function VolumeShape.verticalBounds(part: BasePart): (number, number)
	local halfHeight = worldHalfExtents(part).Y

	return part.CFrame.Position.Y + halfHeight, halfHeight * 2
end

return VolumeShape
