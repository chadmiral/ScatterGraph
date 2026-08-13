--[[
	TextureAddNode

	A + B, cell by cell: two [Texture2D]s summed into a third. See
	[TextureMathNode] for what the four of these share.

	Read as a density, adding is *either of these*: two masks added keep whatever
	either of them would have kept, and the ground both of them like comes out
	white. Where a sum passes white it is clamped there, so adding two half-grey
	textures gives white rather than anything brighter -- which is the same thing as
	saying two half chances do not make more than a certainty.

	An empty side reads as nothing, so a half-wired sum hands the other side on
	unchanged.
]]

local TextureMathNode = require(script.Parent:WaitForChild("TextureMathNode"))

local TextureAddNode = TextureMathNode:new()
TextureAddNode.name = "TextureAddNode"
TextureAddNode._type = "TextureAddNode"
TextureAddNode.does = "adds"
TextureAddNode.identity = 0
TextureAddNode.commutes = true

TextureAddNode.combine = function(a: number, b: number): number
	return a + b
end

return TextureAddNode
