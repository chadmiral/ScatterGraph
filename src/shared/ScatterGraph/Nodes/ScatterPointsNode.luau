local GraphNode = require(script.Parent:WaitForChild("GraphNode"))

ScatterPointsNode = GraphNode:new()
ScatterPointsNode.seed = -1
ScatterPointsNode.spacing = -1

local function scatterPoints(volume, terrain, seed, spacing)
	math.randomseed(seed)
	
	local points = {}
	
	--generate a cloud of random points using pseudo poisson-disc sampling (but we're just doing the first step)
	--where no 2 points are closer than spacing meters.
	--
	--https://www.cs.ubc.ca/~rbridson/docs/bridson-siggraph07-poissondisk.pdf
	--
	local cellSize = spacing / math.sqrt(2)
	local gridDim = { math.floor(volume.Size.X / cellSize), math.floor(volume.Size.Z / cellSize) }
	--print("Poisson Grid dimensions: "..gridDim[1]..", "..gridDim[2])
	
	--initialize the background grid (which will be in the volume's local space)
	for i = 0, gridDim[1] - 1 do
		for j = 0, gridDim[2] - 1 do
			--generate an initial random point inside the disc centered on the grid point
			--we'll use rejection sampling here, as it's fast and easy
			local p = Vector2.new(math.random(), math.random())
			local d = (p - Vector2.new(0.5, 0.5)).Magnitude
			while (d > 0.5) do
				p = Vector2.new(math.random(), math.random())
				d = (p - Vector2.new(0.5, 0.5)).Magnitude
			end
			
			local s = cellSize * Vector2.new(i + p.X, j + p.Y)
			
			local point = Vector3.new(s.X - volume.Size.X / 2, 0, s.Y - volume.Size.Z / 2)
			table.insert(points, (volume.CFrame * CFrame.new(point)).Position)
		end
	end
	
	return points
end

function ScatterPointsNode:evaluate(volume, terrain)
    print("Evaluating ScatterPointsNode "..self.name)
    --[[
    print("name: "..self.name)  
    print("type: "..self._type)
    print("seed: "..self.seed)
    print("spacing: "..self.seed)
    --]]
    return scatterPoints(volume, terrain, self.seed, self.spacing)
end

return ScatterPointsNode