--[[
	MergeNode

	What both merging nodes do, which is the same thing to two different kinds of
	thing: read every node wired into it and hand back all of them together.
	MergePointsNode and MergeInstancesNode are this with a noun filled in --
	`merges`, used only in what they say when something is wrong.

	A merge is how one chain reads several. Before it, a chain was a line: a node
	took one thing, did something to it, and passed it on, so two scatters that
	wanted the same treatment had to have that treatment built twice, once in each
	chain, and stay in step by hand. A merge joins them first and treats them once.
	Two scatters at different spacings snapped to the ground and thinned by one
	texture is a merge of points; two kinds of geometry gathered under one folder
	is a merge of instances.

	Its slots are made as they are wired, like the Output registry's: a wire per
	input, named after the node it comes from, and an empty one under them to add
	another. Nothing declares how many there are, so nothing has to be told when
	a chain gains one.

	The order is the order the card shows, by wire name, rather than the order the
	wires happen to sit in the file. Points are read in the order they arrive --
	each one draws in turn from the run's random stream for its scale and rotation
	-- so the order has to be settled by something, and the one on screen is the
	one worth settling it by.

	What a merge does not do is notice that two of its inputs lead back to the
	same node further upstream. That node is then evaluated once for each way
	round to it, and evaluating a node is not free of consequence: a terminal
	reached twice places its geometry twice. Two inputs pointing straight at the
	same node is the case this can see, and it warns and reads it once; a diamond
	further up is the author's to keep out of.
]]

local GraphNode = require(script.Parent:WaitForChild("GraphNode"))

-- Is this a list of things, rather than something else that happens to be a
-- table? A texture and a distance field are both tables of named parts, and
-- either would otherwise be merged in as its parts: an origin, a resolution and
-- a few thousand cells, handed on as though they were points. Empty counts as a
-- list, since a chain that produced nothing is not a chain of the wrong thing.
local function isList(value: any): boolean
	return typeof(value) == "table" and (#value > 0 or next(value) == nil)
end

local MergeNode = GraphNode:new()
MergeNode.name = "MergeNode"
MergeNode._type = "MergeNode"
-- What this merges, in the words its warnings use. Filled in by the two nodes
-- that are this.
MergeNode.merges = "things"

function MergeNode:evaluate(volumes, terrain, ctx)
	local n = ctx.node

	local wires = {}
	for _, child in n:GetChildren() do
		if child:IsA("ObjectValue") then
			table.insert(wires, child)
		end
	end

	table.sort(wires, function(a, b)
		return a.Name < b.Name
	end)

	if #wires == 0 then
		warn(
			"ScatterGraph " .. n.Name .. ": nothing is wired into it, so there are no " .. self.merges
				.. " to merge. Drop a wire on the empty slot at the bottom of its card to add an input."
		)
		return {}
	end

	local merged = {}
	local read: { [Instance]: boolean } = {}

	for _, wire in wires do
		local upstream = wire.Value

		if upstream == nil then
			warn(
				"ScatterGraph " .. n.Name .. ": its " .. wire.Name .. " input points at nothing, so nothing "
					.. "was merged from it."
			)
		elseif read[upstream] then
			-- Reading it again would not give the same answer twice over -- a
			-- scatter thinned by a density draws from the run's random stream as
			-- it goes -- and where the thing being merged is instances it would
			-- place them all a second time.
			warn(
				"ScatterGraph " .. n.Name .. ": two of its inputs point at " .. upstream.Name
					.. ", which was read once rather than twice. Wire each input to a different node."
			)
		else
			read[upstream] = true

			-- The rule this chain belongs to travels on, the way it does through a
			-- reroute: a merge of instances may stand between the Output entry
			-- that names the rule and the terminals that place under it, and a
			-- terminal reached without it stamps nothing and is swept away as
			-- something the graph does not account for.
			local produced = ctx.evaluateNode(upstream, volumes, terrain, ctx.debugString, ctx.rule)

			if produced == nil then
				-- The node behind it produced nothing and will have said why.
			elseif isList(produced) then
				for _, item in produced do
					table.insert(merged, item)
				end
			else
				-- A wire can be pointed at any node from the Explorer, whatever the
				-- canvas would allow, so an input may be fed a number, or a texture,
				-- or a field -- and the last two are tables, which is why being a
				-- table is not enough to be a list of things to merge.
				warn(
					"ScatterGraph " .. n.Name .. ": its " .. wire.Name .. " input is wired to "
						.. upstream.Name .. ", which does not produce " .. self.merges .. "."
				)
			end
		end
	end

	return merged
end

return MergeNode
