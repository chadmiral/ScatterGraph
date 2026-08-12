--[[
	MergeInstancesNode

	Hands on everything placed by every terminal wired into it. See MergeNode for
	how a merge works; this is that with placed instances in it.

	It is what lets one rule end in more than one kind of geometry. An Output
	entry takes a single wire, so a rule was a single terminal: two kinds of tree
	meant two rules, and anything to be done to both of them afterwards had to be
	done twice. Wire both terminals into a merge and one ParentInstancesTo behind
	it puts the lot somewhere, or one Output entry accounts for the lot.

	Everything reached through a merge is placed under the rule the merge is
	part of, since the rule's identity travels down every input. That is what the
	plugin's bookkeeping goes by, so the two terminals write into one rule's book
	and are swept, promoted and cleared together. Their instances still land in
	that rule's own folder under ScatterGraphInstances, both of them, which is
	worth knowing before wondering why a rule's folder holds two kinds of thing.

	Merging is not placing. The instances exist before they arrive here -- placing
	them is what the terminals behind it did -- so a merge cannot un-place
	anything, and one wired to nothing is a rule that placed nothing rather than
	one that placed something and lost it.
]]

local MergeNode = require(script.Parent:WaitForChild("MergeNode"))

local MergeInstancesNode = MergeNode:new()
MergeInstancesNode.name = "MergeInstancesNode"
MergeInstancesNode._type = "MergeInstancesNode"
MergeInstancesNode.merges = "instances"

return MergeInstancesNode
