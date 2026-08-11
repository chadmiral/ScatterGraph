local GraphNode = require(script.Parent:WaitForChild("GraphNode"))
local Helpers = require(script.Parent.Parent:WaitForChild("ScatterGraphHelpers"))

ScatterPointsNode = GraphNode:new()
ScatterPointsNode.name = "ScatterPointsNode"
ScatterPointsNode._type = "ScatterPointsNode"
ScatterPointsNode.seed = -1
ScatterPointsNode.spacing = -1

--keeps the cell key inside the range where the arithmetic below stays exact in
--a double
local SEED_MODULUS = 1048576

--the jittered point for one lattice cell. The lattice is anchored to the world
--origin and the jitter comes from the cell's own index rather than a running
--random stream, so any two volumes sharing a seed and spacing agree on every
--cell they both cover -- that is what lets overlapping volumes union cleanly.
local function cellPoint(seed: number, i: number, j: number, cellSize: number): (number, number)
	local rng = Random.new((seed % SEED_MODULUS) * 2654435761 + i * 73856093 + j * 19349663)

	--generate a point inside the disc inscribed in the cell
	--we'll use rejection sampling here, as it's fast and easy
	local p = Vector2.new(rng:NextNumber(), rng:NextNumber())
	while (p - Vector2.new(0.5, 0.5)).Magnitude > 0.5 do
		p = Vector2.new(rng:NextNumber(), rng:NextNumber())
	end

	return (i + p.X) * cellSize, (j + p.Y) * cellSize
end

local function scatterPoints(volumes, terrain, seed, spacing)
	--downstream nodes still draw from the global stream for scale, rotation and
	--the slope filter, so it stays seeded here
	math.randomseed(seed)

	local points = {}

	--generate a cloud of random points using pseudo poisson-disc sampling (but we're just doing the first step)
	--where no 2 points are closer than spacing meters.
	--
	--https://www.cs.ubc.ca/~rbridson/docs/bridson-siggraph07-poissondisk.pdf
	--
	local cellSize = spacing / math.sqrt(2)

	local insideFootprint = volumes:footprintFunction()
	local scatterHeight = volumes:centerHeight()

	--each volume walks its own cell range instead of one grid spanning the whole
	--group, so volumes that share a definition but sit far apart cost nothing in
	--between. Cells are visited once across the group, which is what removes the
	--doubled density where volumes overlap.
	local visited = {}
	for _, bounds in volumes:footprintBoundsList() do
		for i = math.floor(bounds.minX / cellSize), math.floor(bounds.maxX / cellSize) do
			local column = visited[i]
			if column == nil then
				column = {}
				visited[i] = column
			end

			for j = math.floor(bounds.minZ / cellSize), math.floor(bounds.maxZ / cellSize) do
				if not column[j] then
					column[j] = true

					local x, z = cellPoint(seed, i, j, cellSize)
					if insideFootprint(x, z) then
						table.insert(points, Vector3.new(x, scatterHeight, z))
					end
				end
			end
		end
	end

	--a stable order keeps the run reproducible: downstream nodes consume the
	--global random stream per point, and the order volumes come back from
	--CollectionService is not guaranteed
	table.sort(points, function(a, b)
		if a.X ~= b.X then
			return a.X < b.X
		end
		return a.Z < b.Z
	end)

	return points
end

function ScatterPointsNode:evaluate(volumes, terrain, ctx)
    print("Evaluating ScatterPointsNode "..self.name)
    local seed = self.seed
    local spacing = self.spacing
    if ctx and ctx.node then
        seed = ctx.node:GetAttribute("Seed")
        spacing = ctx.node:GetAttribute("Spacing")
        if seed == nil or spacing == nil then
            warn("Missing parameters on node "..ctx.node.Name)
        end
    end
    local points = scatterPoints(volumes, terrain, seed, spacing)

    if ctx == nil or ctx.node == nil then
        return points
    end

    --the field is flat, so a candidate is measured by the ground it stands over
    --whether or not anything has snapped it there yet
    local mask, maskDistance = Helpers.readMask(ctx.node, volumes, terrain, ctx)
    return Helpers.maskPoints(points, mask, maskDistance)
end

return ScatterPointsNode
