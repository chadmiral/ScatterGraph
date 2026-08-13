--[[
	TextureMathNode

	What the four nodes that do arithmetic on two [Texture2D]s have in common: Add,
	Subtract, Multiply and Divide. Cell by cell, A against B, out as a third texture.

	This is how the several things a rule cares about become one mask. Multiply is
	the everyday one -- two textures multiplied is *both of these*, and it is what
	wiring two densities onto two nodes of a chain already did, said in one place
	instead. Add is *either of these*, subtract is *this but not that*, and divide is
	mostly there to scale one texture by the reciprocal of another.

	Three things worth knowing, all of them consequences of a texture being a shade
	from 0 to 1 rather than a number:

	- **The result is clamped where it leaves the node.** A sum past white comes out
	  white, and a difference below black comes out black. A chain that dips below
	  black and means to come back up does not come back: the information is gone at
	  the node that lost it, not at the end of the chain.
	- **A Number may be wired to either side**, and is read as a texture of that one
	  shade. Multiplying by a Number of 0.5 halves a mask everywhere, which is the
	  cheapest way to say *half as much of this, wherever it is*.
	- **An empty side reads as the operation's identity** -- nothing for a sum, one
	  for a product -- so a node with only A wired hands A on unchanged rather than
	  producing nothing. It says so, since a half-wired node is usually half-built
	  rather than deliberate. On subtract and divide it is the B side that leaves the
	  other alone: an empty A is nothing minus B, which is black, or one over B,
	  which is white nearly everywhere. Both are what the arithmetic says rather than
	  anything chosen, and both are meant to look wrong.

	Both sides are read on their own grids and the result is laid out on A's, with B
	sampled at A's cell centres. Two textures made at one Voxel Size line up cell for
	cell and nothing is resampled; one made at another is read between its cells, the
	way anything reads a texture at a position.
]]

local GraphNode = require(script.Parent:WaitForChild("GraphNode"))
local GridLayout2D = require(script.Parent.Parent:WaitForChild("GridLayout2D"))
local Helpers = require(script.Parent.Parent:WaitForChild("ScatterGraphHelpers"))
local Texture2D = require(script.Parent.Parent:WaitForChild("Texture2D"))

local TextureMathNode = GraphNode:new()
TextureMathNode.name = "TextureMathNode"
TextureMathNode._type = "TextureMathNode"

-- What this does to the two of them, as it would be said out loud: only used to
-- explain the node in a warning.
TextureMathNode.does = "reads"

-- What an empty side stands at, which is the value that leaves the other side
-- alone: nothing to add, or one to multiply by.
TextureMathNode.identity = 0

-- Whether the two sides may be swapped without changing the answer, which is what
-- decides whether an empty A is as harmless as an empty B.
TextureMathNode.commutes = true

-- What an empty A does to a node whose sides cannot be swapped, said in the
-- warning about it: there is no value that leaves B alone, so the identity goes in
-- and something odd but explicable comes out. Only the two that do not commute
-- need one.
TextureMathNode.withoutA = "which is odd but not an error"

-- What the node makes of one cell of each side.
TextureMathNode.combine = function(_a: number, _b: number): number
	return 0
end

-- Anything the node wants to say about the whole texture once it is worked out,
-- which is where dividing by black gets mentioned. Nothing to say, for three of
-- the four.
TextureMathNode.report = function(_node: Instance, _cells: number) end

-- Are these two textures the same cells over the same ground? Then B is read
-- straight out of its array rather than sampled between its cells, which is both
-- exact and quicker -- and it is the usual case, every texture in a graph being
-- laid out over the volumes at the same Voxel Size unless something said otherwise.
local function alike(a: Texture2D.Texture, b: Texture2D.Texture): boolean
	return a.origin == b.origin and a.voxelSize == b.voxelSize and a.resolution == b.resolution
end

-- Is there a wire on this slot pointing at anything at all? A slot with none is a
-- node half built, and worth saying so. A slot whose wire came back with something
-- that is not a texture has already been complained about where it was read, and
-- calling that side empty as well would contradict the complaint.
local function pointsAtAnything(node: Instance, slot: string): boolean
	local wire = Helpers.wireNamed(node, slot)
	return wire ~= nil and wire.Value ~= nil
end

function TextureMathNode:evaluate(volumes, terrain, ctx)
	local n = ctx.node

	-- Every rule reading this node asks it for the same texture, and it is the
	-- textures upstream of it that cost anything.
	local cache = ctx.fieldCache
	if cache ~= nil and cache[n] ~= nil then
		return cache[n]
	end

	local sides = { A = nil, B = nil }
	for _, slot in { "A", "B" } do
		sides[slot] = Helpers.readTexture(
			n,
			slot,
			volumes,
			terrain,
			ctx,
			string.format("the %s side was read as %g everywhere", slot, self.identity)
		)
	end

	local a, b = sides.A, sides.B

	if a == nil and b == nil then
		-- Said whichever way it happened, since the reads above promise each side
		-- will stand at the identity and neither of them can: with nothing on the
		-- other side there is not even a grid to stand it on.
		local why = if pointsAtAnything(n, "A") or pointsAtAnything(n, "B")
			then "neither side of it could be read"
			else "nothing is wired to either side of it"

		warn(
			string.format(
				"ScatterGraph %s: %s, so it %s nothing and produces nothing. Wire a texture to A and "
					.. "another to B.",
				n.Name,
				why,
				self.does
			)
		)

		return nil
	end

	local empty = if a == nil then "A" elseif b == nil then "B" else nil

	if empty ~= nil and not pointsAtAnything(n, empty) then
		-- An empty side standing at the identity leaves the other alone -- except
		-- on the two that do not commute, where that is only true of B, and where
		-- what an empty A leaves instead is the node's own to say.
		local outcome = if self.commutes or empty == "B"
			then "which hands the other side on unchanged"
			else self.withoutA

		warn(
			string.format(
				"ScatterGraph %s: nothing is wired to its %s, so that side was read as %g everywhere, %s.",
				n.Name,
				empty,
				self.identity,
				outcome
			)
		)
	end

	-- The result sits where A does, since that is the side being operated on. With
	-- A empty there is no such grid, so it sits on B's; with both empty there is
	-- nothing to sit on at all, which is the case above.
	local layout: GridLayout2D.Layout = (a or b) :: any
	a = a or Texture2D.uniform(layout, self.identity)
	b = b or Texture2D.uniform(layout, self.identity)

	local countX, countZ = layout.resolution.X, layout.resolution.Y
	local voxelSize = layout.voxelSize
	local origin = layout.origin
	local cells = countX * countZ
	local values = table.create(cells)
	local combine = self.combine
	local sameCells = alike(a, b)
	local at = 1

	for k = 0, countZ - 1 do
		local z = origin.Y + k * voxelSize

		for i = 0, countX - 1 do
			local right = if sameCells
				then b.values[at]
				else Texture2D.sample(b, Vector3.new(origin.X + i * voxelSize, 0, z))

			values[at] = combine(a.values[at], right)
			at += 1
		end
	end

	local texture = Texture2D.fromCells(layout, values)
	self.report(n, cells)

	if cache ~= nil then
		cache[n] = texture
	end

	return texture
end

return TextureMathNode
