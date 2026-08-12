--[[
	Rotation

	A turn in space: a unit quaternion, which is what gets applied to anything,
	together with the three angles in degrees it was authored from, which is what
	a range between two turns is taken in.

	Both, rather than either alone, because the two answer different questions and
	neither answers both.

	A quaternion is the turn itself, and is what a placement needs. What it cannot
	say is how far round something went to get there: a full turn about Y and no
	turn at all are the same rotation and so the same four numbers. Taking a range
	between two quaternions therefore makes a range from 0 to 360 degrees a range
	from a thing to itself -- every point comes out unturned -- which is exactly
	the spin an author is most likely to ask a scatter for.

	The angles remember what was asked for, 360 included, so a range can be drawn
	in the space the author typed: each axis between the two ends' angle for that
	axis, independently. That is what every scatter tool means by a rotation
	range, and it makes the two obvious requests work -- a full spin from (0,0,0)
	to (0,360,0), and a lean from (0,0,0) to (20,90,0) that gives every
	combination of pitch and heading in between rather than only those on one arc
	joining the corners.

	The two can disagree, and are meant to: the angles are what was asked for and
	the quaternion is where that lands. (0,360,0) has angles of a full turn and
	the quaternion of none.

	Stored as a plain table rather than as a CFrame so that a rotation on a wire
	is a rotation and nothing else: a CFrame carries a position too, and a type
	whose values half mean something is worse than one more table.
]]

local Rotation = {}

export type Rotation = {
	x: number,
	y: number,
	z: number,
	w: number,
	-- Degrees about X, then Y, then Z, as authored -- unwrapped, so a full turn
	-- is 360 here even though the quaternion beside it is the identity.
	angles: Vector3,
}

-- No turn at all. Every point starts here, and every unwired end of a range
-- stands at it.
local IDENTITY: Rotation = { x = 0, y = 0, z = 0, w = 1, angles = Vector3.zero }

Rotation.identity = IDENTITY

-- Below this two rotations are the same turn to within the arithmetic's own
-- error.
local PARALLEL = 1 - 1e-6

-- Is this one of ours? A quaternion is the only table here with all four of x, y,
-- z and w on it, and a Vector3 is not a table at all, so nothing else in a graph
-- answers to this by accident.
function Rotation.is(value: any): boolean
	return typeof(value) == "table"
		and typeof(value.x) == "number"
		and typeof(value.y) == "number"
		and typeof(value.z) == "number"
		and typeof(value.w) == "number"
end

-- The four components of the rotation part of a CFrame. Shepperd's method: the
-- four ways of reading a quaternion off a rotation matrix each lose precision as
-- their own component approaches zero, so the one whose component is largest is
-- the one used.
local function componentsOf(cf: CFrame): (number, number, number, number)
	local _, _, _, m00, m01, m02, m10, m11, m12, m20, m21, m22 = cf:GetComponents()
	local trace = m00 + m11 + m22

	if trace > 0 then
		local s = math.sqrt(trace + 1) * 2
		return (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, 0.25 * s
	elseif m00 > m11 and m00 > m22 then
		local s = math.sqrt(1 + m00 - m11 - m22) * 2
		return 0.25 * s, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s
	elseif m11 > m22 then
		local s = math.sqrt(1 + m11 - m00 - m22) * 2
		return (m01 + m10) / s, 0.25 * s, (m12 + m21) / s, (m02 - m20) / s
	end

	local s = math.sqrt(1 + m22 - m00 - m11) * 2
	return (m02 + m20) / s, (m12 + m21) / s, 0.25 * s, (m10 - m01) / s
end

-- The rotation part of a CFrame, with its angles read back off it -- so a
-- rotation made this way is wrapped into the usual ranges, having no memory of
-- anything further round to remember.
function Rotation.fromCFrame(cf: CFrame): Rotation
	local x, y, z, w = componentsOf(cf)
	local ex, ey, ez = cf:ToEulerAnglesXYZ()
	return {
		x = x,
		y = y,
		z = z,
		w = w,
		angles = Vector3.new(math.deg(ex), math.deg(ey), math.deg(ez)),
	}
end

-- A turn at the world origin, for composing with a position to place something.
function Rotation.toCFrame(r: Rotation): CFrame
	return CFrame.new(0, 0, 0, r.x, r.y, r.z, r.w)
end

-- Degrees about X, then Y, then Z, which is the order Studio's own Orientation
-- box reads in, so an author can copy a number out of the Properties pane and
-- get the rotation they were looking at. The angles are kept exactly as given
-- rather than as the quaternion would report them back, which is what lets a
-- full turn be told from none.
function Rotation.fromEulerDegrees(angles: Vector3): Rotation
	local x, y, z, w =
		componentsOf(CFrame.fromEulerAnglesXYZ(math.rad(angles.X), math.rad(angles.Y), math.rad(angles.Z)))
	return { x = x, y = y, z = z, w = w, angles = angles }
end

-- The angles a rotation was authored from, for taking a range in. Falls back to
-- reading them off the turn itself for a rotation built without them, which
-- nothing here does but a hand-written table might.
function Rotation.anglesOf(r: Rotation): Vector3
	if typeof(r.angles) == "Vector3" then
		return r.angles
	end

	return Rotation.toEulerDegrees(r)
end

-- The angles of the turn as the quaternion has it: wrapped, and split between
-- the axes however the decomposition sees fit. Not the same as the angles it was
-- authored from -- see anglesOf.
function Rotation.toEulerDegrees(r: Rotation): Vector3
	local x, y, z = Rotation.toCFrame(r):ToEulerAnglesXYZ()
	return Vector3.new(math.deg(x), math.deg(y), math.deg(z))
end

--[[
	A rotation somewhere between these two, one axis at a time: `tx`, `ty` and
	`tz` say how far along each of the three the result sits, nought at `a` and
	one at `b`.

	Each axis drawn on its own is what makes a range mean what an author expects
	of it. A spin is a range from (0,0,0) to (0,360,0) and comes out spread over
	the whole circle. A lean of up to 20 degrees anywhere in a quarter turn is a
	range to (20,90,0) and gives every pairing of the two, rather than only the
	pairs that happen to lie on a single arc from one corner to the other.
]]
function Rotation.mixed(a: Rotation, b: Rotation, tx: number, ty: number, tz: number): Rotation
	local from = Rotation.anglesOf(a)
	local to = Rotation.anglesOf(b)

	return Rotation.fromEulerDegrees(Vector3.new(
		from.X + (to.X - from.X) * tx,
		from.Y + (to.Y - from.Y) * ty,
		from.Z + (to.Z - from.Z) * tz
	))
end

-- Are these the same turn? A quaternion and its negation are, which is why the
-- comparison is of the angle between them rather than of the four numbers. Two
-- rotations authored differently can be the same turn -- no turn and a full one
-- -- so this answers about the turn and not about what was asked for.
function Rotation.equals(a: Rotation, b: Rotation): boolean
	local dot = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
	return math.abs(dot) > PARALLEL
end

return Rotation
