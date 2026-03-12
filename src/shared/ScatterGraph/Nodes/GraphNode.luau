GraphNode = { name = "GraphNode", _type = "GraphNode", inputPins = {}, outputPins = {} }

function GraphNode:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function GraphNode:evaluate(volume, terrain)
    print("Evaluating node "..self.name.." of type "..self._type)
end

return GraphNode