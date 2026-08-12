--[[
	PointRangeNode

	What the three nodes that vary a point between two ends have in common: Set
	Rotation Range, Set Scale Range and Set Translation Offset Range.

	Each of them reads a cloud of points and two values, A and B, and hands the
	cloud on with something drawn between those two ends settled on every point of
	it. They differ only in what A and B are, how a value between them is drawn,
	and what setting it does to a point -- which is what the fields below are for.
	Everything else, from finding the wires to complaining about the wrong thing
	being on the end of one, is here and is done the same way three times over.

	Either end may be given twice over: as a port, and as a value on the node
	itself. **The port wins where it is wired**, and the value on the node is what
	stands when it is not, which is why the parameter panel greys that row out and
	marks it unused while a wire is there.

	Two ways of saying one thing because the two are wanted at different times. A
	range only this node cares about is two numbers typed on the card and no
	wiring at all -- which is most of them. A range several rules must agree on is
	a Number or a Rotation node wired into each of them, so that changing the one
	node changes all of them at once.

	An end with neither is the value that changes nothing: no turn, full size, no
	offset. That makes a node with nothing at either end a node that does nothing,
	which is pointless enough to be worth saying out loud.

	The draw comes from the run's own random stream, seeded by the scatter at the
	head of the chain, rather than from a seed of the node's own: a graph run twice
	over unchanged ground settles on the same rotations and sizes twice. The
	consequence is that a node added to the middle of a chain shifts every draw
	made after it, so the props downstream of one all change the first time it
	appears. That is the same bargain every node in a chain already makes.
]]

local GraphNode = require(script.Parent:WaitForChild("GraphNode"))
local Helpers = require(script.Parent.Parent:WaitForChild("ScatterGraphHelpers"))
local Point = require(script.Parent.Parent:WaitForChild("Point"))

-- The slots these nodes read, named as DataTypes declares them.
local POINTS_WIRE = "Points"
local A_WIRE = "A"
local B_WIRE = "B"

local PointRangeNode = GraphNode:new()
PointRangeNode.name = "PointRangeNode"
PointRangeNode._type = "PointRangeNode"

-- What this node sets on a point, in the words its warnings use.
PointRangeNode.sets = "nothing"
-- What the two ends of the range are, in those same words.
PointRangeNode.valueName = "value"
-- What an unwired end stands at, which must be the value that leaves a point as
-- it was.
PointRangeNode.neutral = nil :: any
-- Is what came up an A or B wire the kind of thing this node takes?
PointRangeNode.takes = function(_value: any): boolean
	return false
end
-- What the attribute of that name on the node itself means, read as one of these
-- values, or nil where it is unset or of no use. A rotation is typed as three
-- angles and a scale as one number, so this is not always the value itself.
PointRangeNode.fromAttribute = function(_raw: any): any
	return nil
end
-- One value drawn between the two ends. Called once per point, and the only
-- thing here that touches the random stream.
PointRangeNode.between = function(_a: any, _b: any): any
	return nil
end
-- The point that value makes of this one.
PointRangeNode.settle = function(point: Point.Point, _value: any): Point.Point
	return point
end

-- One end of the range: what is wired to it, else what is set on the node, else
-- the neutral value. Also says whether either of the first two was there, so that
-- a node with nothing at either end can be told from one deliberately ranged
-- against nothing happening.
function PointRangeNode:_end(n: Instance, slot: string, volumes, terrain, ctx): (any, boolean)
	local wire = Helpers.wireNamed(n, slot)

	if wire ~= nil and wire.Value ~= nil then
		local produced = ctx.evaluateNode(wire.Value, volumes, terrain, ctx.debugString)

		if self.takes(produced) then
			return produced, true
		end

		-- A wire that is there but carries the wrong thing is a mistake to say out
		-- loud rather than to quietly fall back out of: the value on the node is
		-- marked unused while a wire is attached, so using it here would place
		-- geometry by a figure the panel says is being ignored.
		warn(
			"ScatterGraph " .. n.Name .. ": its " .. slot .. " slot points at " .. wire.Value.Name
				.. ", which does not produce a " .. self.valueName .. ", so that end of the range stands at "
				.. "no change."
		)
		return self.neutral, false
	end

	local set = self.fromAttribute(n:GetAttribute(slot))
	if set ~= nil then
		return set, true
	end

	return self.neutral, false
end

function PointRangeNode:evaluate(volumes, terrain, ctx)
	local n = ctx.node

	local points = {}
	for _, wire in n:GetChildren() do
		if wire:IsA("ObjectValue") and wire.Name == POINTS_WIRE then
			if wire.Value == nil then
				warn("ScatterGraph " .. n.Name .. ": its Points input points at nothing.")
			else
				local upstream = ctx.evaluateNode(wire.Value, volumes, terrain, ctx.debugString)
				if typeof(upstream) == "table" then
					for _, p in upstream do
						table.insert(points, p)
					end
				end
			end
		end
	end

	local a, aWired = self:_end(n, A_WIRE, volumes, terrain, ctx)
	local b, bWired = self:_end(n, B_WIRE, volumes, terrain, ctx)

	if not aWired and not bWired then
		warn(
			"ScatterGraph " .. n.Name .. ": neither end of its range is set, so every point keeps the "
				.. self.sets .. " it arrived with. Set A and B on the node, or wire a value to either."
		)
		return points
	end

	local settled = table.create(#points)
	local warnedUnpointed = false

	for _, point in points do
		if not Point.is(point) then
			-- A wire can be aimed at any node from the Explorer, whatever the
			-- canvas would allow, so what arrives on the Points slot may be
			-- anything at all.
			if not warnedUnpointed then
				warnedUnpointed = true
				warn(
					"ScatterGraph " .. n.Name .. ": something reaching its Points input is not a point, and "
						.. "was left out."
				)
			end
			continue
		end

		table.insert(settled, self.settle(point, self.between(a, b)))
	end

	return settled
end

return PointRangeNode
