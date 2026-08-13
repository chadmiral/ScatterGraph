--[[
	TextureSubtractNode

	A - B, cell by cell: one [Texture2D] taken out of another. See
	[TextureMathNode] for what the four of these share.

	Read as a density, subtracting is *this but not that*: ground A likes and B does
	not comes through, and ground they both like is cut back by however much B liked
	it. Everything below black is clamped there, so B being white anywhere means
	nothing survives there whatever A said.

	Wiring a Number of 1 into A and a texture into B is how a mask is turned over:
	white becomes black and black white. That is worth knowing, since *the low
	ground* and *the shallow slopes* are usually wanted the other way round from how
	the terrain nodes measure them.

	The order matters, which is the difference between this and the other three. An
	empty B leaves A alone; an empty A is nothing minus something, and comes out
	black everywhere.
]]

local TextureMathNode = require(script.Parent:WaitForChild("TextureMathNode"))

local TextureSubtractNode = TextureMathNode:new()
TextureSubtractNode.name = "TextureSubtractNode"
TextureSubtractNode._type = "TextureSubtractNode"
TextureSubtractNode.does = "subtracts"
TextureSubtractNode.identity = 0
TextureSubtractNode.commutes = false
TextureSubtractNode.withoutA = "which is nothing minus B, and so black wherever B is anything at all"

TextureSubtractNode.combine = function(a: number, b: number): number
	return a - b
end

return TextureSubtractNode
