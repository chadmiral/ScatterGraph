local GraphNode = require(script.Parent:WaitForChild("GraphNode"))

local OutputNode = GraphNode:new()
OutputNode.name = "OutputNode"
OutputNode._type = "OutputNode"

function OutputNode:evaluate(volume, terrain, ctx)
	local n = ctx.node
	local debugString = ctx.debugString
	for _, wire in pairs(n:GetChildren()) do
		if wire:IsA("ObjectValue") then
			if wire.Value == nil then
				warn("missing value in OutputNode wire " .. wire.Name)
			end
			ctx.evaluateNode(wire.Value, volume, terrain, debugString)
		end
	end
	return nil
end

return OutputNode
