--[[
	ParentInstancesToNode

	Moves what a rule placed somewhere else in the hierarchy, and hands the same
	instances on. A rule's geometry lands in a folder per rule under
	ScatterGraphInstances, which is where the plugin's own bookkeeping reads
	best; a place may want it somewhere else -- inside a model that gets streamed
	or moved as a unit, under a folder a level's own tooling walks -- and this is
	how a graph says so.

	Where to put them is a child ObjectValue named Parent rather than an
	attribute, since an attribute cannot hold a reference to an instance. That
	makes this the one node whose parameter points into the place it is running
	in: a graph carrying one only works where the thing it points at exists, so
	it is worth thinking about before putting one in a graph several places
	share. A Parent that has since been deleted is a warning and the instances
	are left where they were, rather than being moved out of the DataModel where
	nothing could reach them again.

	Reparenting does not upset anything the plugin later does with a placement.
	Both the sweep at the start of a run and Clear find instances by their
	CollectionService tag rather than by where they sit, so a moved instance is
	still swept, still promoted if it has been edited by hand, and still cleared.
	It keeps its world position too: parenting in Roblox does not transform
	anything.
]]

local GraphNode = require(script.Parent:WaitForChild("GraphNode"))
local Helpers = require(script.Parent.Parent:WaitForChild("ScatterGraphHelpers"))

local ParentInstancesToNode = GraphNode:new()
ParentInstancesToNode.name = "ParentInstancesToNode"
ParentInstancesToNode._type = "ParentInstancesToNode"

-- The instances to move, and where to move them: the first is a wire from
-- another node, the second a reference into the place.
local INPUT_WIRE = "Instances"
local PARENT_WIRE = "Parent"

function ParentInstancesToNode:evaluate(volumes, terrain, ctx)
	local n = ctx.node

	local wire = Helpers.wireNamed(n, INPUT_WIRE)
	if wire == nil or wire.Value == nil then
		warn(
			"ScatterGraph " .. n.Name .. ": nothing is wired into its " .. INPUT_WIRE .. " slot, so there is "
				.. "nothing for it to reparent."
		)
		return nil
	end

	-- The rule this chain belongs to travels on, the way it does through a
	-- reroute: this node may stand between a terminal and the Output entry that
	-- names the rule, and the terminal behind it is what stamps each placement
	-- with that name.
	local instances = ctx.evaluateNode(wire.Value, volumes, terrain, ctx.debugString, ctx.rule)

	if typeof(instances) ~= "table" then
		-- Either the node behind it placed nothing and said so, or it produces
		-- something that is not a set of instances at all.
		return nil
	end

	local parentWire = Helpers.wireNamed(n, PARENT_WIRE)
	local parent = if parentWire ~= nil then parentWire.Value else nil

	if parent == nil then
		warn(
			"ScatterGraph " .. n.Name .. ": its " .. PARENT_WIRE .. " points at nothing, so the "
				.. #instances .. " instances behind it were left where they were placed."
		)
		return instances
	end

	-- A reference to something deleted since it was aimed. Setting a parent to it
	-- would put the placements outside the DataModel, where the only thing left
	-- to do with them is lose them.
	if not parent:IsDescendantOf(game) then
		warn(
			"ScatterGraph " .. n.Name .. ": its " .. PARENT_WIRE .. " points at " .. parent.Name
				.. ", which is no longer in the place, so the " .. #instances
				.. " instances behind it were left where they were placed."
		)
		return instances
	end

	for _, instance in instances do
		instance.Parent = parent
	end

	return instances
end

return ParentInstancesToNode
