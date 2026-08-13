--[[
	TextureDivideNode

	A ÷ B, cell by cell: one [Texture2D] divided by another. See [TextureMathNode]
	for what the four of these share.

	The odd one of the four. A texture holds 0 to 1, so dividing by anything short of
	white makes the result larger, and a division of two ordinary masks is white over
	most of its ground -- which as a density means *keep everything*, and is rarely
	what anyone wanted. What it is actually good for is dividing by a Number: A over
	a Number of 0.25 is A four times as strong, brightening a faint mask rather than
	fading it the way multiplying would.

	**Dividing by black.** There is no answer, so one is chosen: a cell of A over a
	cell of black comes out white where A is anything at all, and black where A is
	black as well -- nothing shared out among nothing. Both are the clamp the
	arithmetic itself would reach, infinity landing on white and nothing-over-nothing
	on black, and the node says how many cells it happened to, since a division that
	is mostly white by way of its divisor is usually a mistake.

	The order matters, as it does for subtraction. An empty B leaves A alone; an empty
	A is one over B, which is white everywhere but the palest of it.
]]

local TextureMathNode = require(script.Parent:WaitForChild("TextureMathNode"))

local TextureDivideNode = TextureMathNode:new()
TextureDivideNode.name = "TextureDivideNode"
TextureDivideNode._type = "TextureDivideNode"
TextureDivideNode.does = "divides"
TextureDivideNode.identity = 1
TextureDivideNode.commutes = false
TextureDivideNode.withoutA = "which is one over B, and so white everywhere but the palest of it"

-- How many cells of the texture being worked out were divided by black. Counted
-- while the cells are walked and said once at the end of it: a warning per cell
-- would be tens of thousands of them.
local dividedByBlack = 0

TextureDivideNode.combine = function(a: number, b: number): number
	if b == 0 then
		dividedByBlack += 1
		return if a > 0 then 1 else 0
	end

	return a / b
end

TextureDivideNode.report = function(node: Instance, cells: number)
	if dividedByBlack > 0 then
		warn(
			string.format(
				"ScatterGraph %s: %d of its %d cells were divided by black, and read as white where A was "
					.. "anything and black where A was not. Wire something that is nowhere black to B, or "
					.. "add a little to B first, if that is not what you meant.",
				node.Name,
				dividedByBlack,
				cells
			)
		)
	end

	dividedByBlack = 0
end

return TextureDivideNode
