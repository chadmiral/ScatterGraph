--[[
	NoiseTexture2DNode

	Perlin noise as a [Texture2D]: a field of soft blotches over the ground being
	scattered, mid grey on average, running to white where the noise peaks and black
	where it troughs.

	Wired into a Density slot it breaks a scatter up the way ground cover actually
	grows -- thick in places, thin in others, with no edge anywhere -- which even
	spacing and a uniform count cannot do on their own. Two rules reading one noise
	node thin out together; two noise nodes a Phase apart thin out independently.

	Noise is a function of position rather than a picture, so where the world is has
	nothing to do with where a rule sits in a graph: the same ground gives the same
	blotches every run, and moving a volume moves the scatter through the pattern
	rather than reshuffling it.
]]

local GraphNode = require(script.Parent:WaitForChild("GraphNode"))
local GridLayout2D = require(script.Parent.Parent:WaitForChild("GridLayout2D"))
local Texture2D = require(script.Parent.Parent:WaitForChild("Texture2D"))

local NoiseTexture2DNode = GraphNode:new()
NoiseTexture2DNode.name = "NoiseTexture2DNode"
NoiseTexture2DNode._type = "NoiseTexture2DNode"

-- How wide one blotch is, in studs, where nothing was asked for. Sixty-four is
-- about a clearing: coarse enough to read as patchiness across a biome rather than
-- as texture underfoot.
local DEFAULT_SCALE = 64

-- Below this a scale is finer than the ground can be measured at and the pattern
-- would be noise in the unhelpful sense, a different value every cell.
local MIN_SCALE = 1

-- Perlin noise runs to either side of zero rather than from zero up, so it is
-- shifted into place: flat noise becomes mid grey, and most of the swing either way
-- lands inside the greys. Roblox's noise mostly keeps within half a unit of zero
-- but does overshoot -- a few cells in a hundred, on the ground measured here --
-- and those are clamped, which is what puts the occasional patch of certain black
-- or white in an otherwise probabilistic texture. That is worth having: a scatter
-- wants the odd bare clearing and the odd solid thicket, not a uniform haze.
local NOISE_CENTRE = 0.5

local function numberOr(node: Instance, name: string, fallback: number): number
	local value = node:GetAttribute(name)
	return if typeof(value) == "number" then value else fallback
end

function NoiseTexture2DNode:evaluate(volumes, terrain, ctx)
	local n = ctx.node

	-- Every rule reading this node asks it for the same texture.
	local cache = ctx.fieldCache
	if cache ~= nil and cache[n] ~= nil then
		return cache[n]
	end

	local scale = numberOr(n, "Scale", DEFAULT_SCALE)
	if scale < MIN_SCALE then
		warn(
			string.format(
				"ScatterGraph %s: Scale is %g, finer than the ground is measured at, so the pattern would "
					.. "be a different value every cell rather than blotches. It was read as %g instead.",
				n.Name,
				scale,
				MIN_SCALE
			)
		)
		scale = MIN_SCALE
	end

	-- A third axis through the noise rather than a shift along the ground, so
	-- changing it gives a different pattern over the same place rather than the
	-- same pattern slid sideways.
	local phase = numberOr(n, "Phase", 0)

	local voxelSize = numberOr(n, "VoxelSize", GridLayout2D.TERRAIN_VOXEL)
	local layout = ctx.gridLayout
	if layout == nil or layout.voxelSize ~= voxelSize then
		layout = GridLayout2D.layoutFor(volumes, voxelSize)
	end

	local texture = Texture2D.fromFunction(layout, function(x: number, z: number): number
		return math.noise(x / scale, z / scale, phase) + NOISE_CENTRE
	end)

	if cache ~= nil then
		cache[n] = texture
	end

	return texture
end

return NoiseTexture2DNode
