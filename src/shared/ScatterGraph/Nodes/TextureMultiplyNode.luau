--[[
	TextureMultiplyNode

	A × B, cell by cell: two [Texture2D]s multiplied into a third. See
	[TextureMathNode] for what the four of these share.

	This is the everyday one. Read as a density, multiplying is *both of these*: a
	point has to survive A and then survive B, and two chances one after another are
	the product of them. It is exactly what wiring two densities onto two nodes of
	one chain already did -- the difference is that here the two are one texture,
	which several rules can share and which draws its own picture on the canvas.

	Nothing here can pass white, both sides being at most white themselves, so unlike
	the other three this one never clamps.

	Multiplying by a Number of 0.5 halves a mask everywhere, which is the cheapest
	way to say *half as much of this, wherever it is*. An empty side reads as one, so
	a half-wired product hands the other side on unchanged.
]]

local TextureMathNode = require(script.Parent:WaitForChild("TextureMathNode"))

local TextureMultiplyNode = TextureMathNode:new()
TextureMultiplyNode.name = "TextureMultiplyNode"
TextureMultiplyNode._type = "TextureMultiplyNode"
TextureMultiplyNode.does = "multiplies"
TextureMultiplyNode.identity = 1
TextureMultiplyNode.commutes = true

TextureMultiplyNode.combine = function(a: number, b: number): number
	return a * b
end

return TextureMultiplyNode
