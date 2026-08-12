--[[
	Point

	One point of a cloud: where it is, which way it faces, and how big whatever
	lands on it should be.

	A point used to be a bare Vector3, and a position is still the only part of
	one the scattering and filtering nodes care about -- a density is read off the
	ground it stands over, a slope filter off the ground under it, an exclusion
	volume off whether it is inside. What the rotation and the scale are for is
	the far end of the chain: they are how a rule says that these particular
	points face this way and stand this tall, worked out per point by a node
	rather than drawn per instance by the terminal.

	They start at nothing happening -- no turn, and full size -- so a chain
	without any of the nodes that set them places nothing turned or resized.

	Scale is one number rather than three because Roblox scales a model about its
	pivot, evenly, and there is no such thing as a model stretched along one axis.
	A vector here would be two thirds a value that could never be honoured.
]]

local Rotation = require(script.Parent:WaitForChild("Rotation"))

local Point = {}

export type Point = {
	position: Vector3,
	rotation: Rotation.Rotation,
	scale: number,
}

-- Full size, which is what a point that has never been scaled is.
local UNSCALED = 1

function Point.new(position: Vector3, rotation: Rotation.Rotation?, scale: number?): Point
	return {
		position = position,
		rotation = rotation or Rotation.identity,
		scale = scale or UNSCALED,
	}
end

-- A point where nothing has happened to it yet: the one every scatter makes.
function Point.at(position: Vector3): Point
	return { position = position, rotation = Rotation.identity, scale = UNSCALED }
end

-- Is this a point? Asked of what came up a wire, which may be anything a node
-- can produce -- a number, a texture, a list of instances -- since a wire can be
-- aimed at any node from the Explorer whatever the canvas would allow.
function Point.is(value: any): boolean
	return typeof(value) == "table" and typeof(value.position) == "Vector3"
end

-- The same point somewhere else, facing another way, or at another size. Each
-- returns a new point rather than editing the one it is given: a cloud may be
-- read by two chains, and one of them turning every point would otherwise turn
-- them for the other as well.
function Point.movedTo(point: Point, position: Vector3): Point
	return { position = position, rotation = point.rotation, scale = point.scale }
end

function Point.turnedTo(point: Point, rotation: Rotation.Rotation): Point
	return { position = point.position, rotation = rotation, scale = point.scale }
end

function Point.sizedTo(point: Point, scale: number): Point
	return { position = point.position, rotation = point.rotation, scale = scale }
end

-- Where and which way, as one thing to place geometry with. The scale is not in
-- it: a CFrame cannot carry one, and the terminal applies it separately.
function Point.cframe(point: Point): CFrame
	return CFrame.new(point.position) * Rotation.toCFrame(point.rotation)
end

return Point
