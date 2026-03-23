local CollectionService = game:GetService("CollectionService")
local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BrushToolActive = false

local GraphNode = require(script.Parent.Nodes:WaitForChild("GraphNode"))
local ScatterPointsNode = require(script.Parent.Nodes:WaitForChild("ScatterPointsNode"))

local InstanceFolder = workspace:FindFirstChild("ScatterGraphInstances")
if InstanceFolder == nil then
	InstanceFolder = Instance.new("Folder")
	InstanceFolder.Name = "ScatterGraphInstances"
	InstanceFolder.Parent = workspace
end

local ScatterGraphsFolder = ReplicatedStorage:FindFirstChild("ScatterGraphs")
if ScatterGraphsFolder == nil then
	ScatterGraphsFolder = Instance.new("Folder")
	ScatterGraphsFolder.Name = "ScatterGraphs"
	ScatterGraphsFolder.Parent = ReplicatedStorage
end

local toolbar = plugin:CreateToolbar("ScatterGraph")

-- Add a toolbar button labeled "Empty Script"
local newScriptButton = toolbar:CreateButton("EvaluateScatterGraph", "Evaluate the Scatter Graph", "rbxassetid://14978048121")
local clearButton = toolbar:CreateButton("Clear Instances", "Clear all ScatterGraph Instances", "")
local brushButton = toolbar:CreateButton("Brush", "Enable Brush Mode", "")
local testButton = toolbar:CreateButton("Test", "Test Button", "")

local function clearAllInstances()
	for _, instance in pairs(InstanceFolder:GetChildren()) do
		instance:Destroy()
	end
end

--how is this not a built in function?! Absolutely baffling.
local function evalNumberSequence(sequence: NumberSequence, time: number)
	-- If time is 0 or 1, return the first or last value respectively
	if time == 0 then
		return sequence.Keypoints[1].Value
	elseif time == 1 then
		return sequence.Keypoints[#sequence.Keypoints].Value
	end

	-- Otherwise, step through each sequential pair of keypoints
	for i = 1, #sequence.Keypoints - 1 do
		local currKeypoint = sequence.Keypoints[i]
		local nextKeypoint = sequence.Keypoints[i + 1]
		if time >= currKeypoint.Time and time < nextKeypoint.Time then
			-- Calculate how far alpha lies between the points
			local alpha = (time - currKeypoint.Time) / (nextKeypoint.Time - currKeypoint.Time)
			-- Return the value between the points using alpha
			return currKeypoint.Value + (nextKeypoint.Value - currKeypoint.Value) * alpha
		end
	end
end

local function evalColorSequence(sequence: ColorSequence, time: number)
    -- If time is 0 or 1, return the first or last value respectively
    if time == 0 then
        return sequence.Keypoints[1].Value
    elseif time == 1 then
        return sequence.Keypoints[#sequence.Keypoints].Value
    end

    -- Otherwise, step through each sequential pair of keypoints
    for i = 1, #sequence.Keypoints - 1 do
        local thisKeypoint = sequence.Keypoints[i]
        local nextKeypoint = sequence.Keypoints[i + 1]
        if time >= thisKeypoint.Time and time < nextKeypoint.Time then
            -- Calculate how far alpha lies between the points
            local alpha = (time - thisKeypoint.Time) / (nextKeypoint.Time - thisKeypoint.Time)
            -- Evaluate the real value between the points using alpha
            return Color3.new(
                (nextKeypoint.Value.R - thisKeypoint.Value.R) * alpha + thisKeypoint.Value.R,
                (nextKeypoint.Value.G - thisKeypoint.Value.G) * alpha + thisKeypoint.Value.G,
                (nextKeypoint.Value.B - thisKeypoint.Value.B) * alpha + thisKeypoint.Value.B
            )
        end
    end
end

local function snapPointsToTerrain(volume, terrain, points, materialFilter, slopeDensityCurve)
	local raycastResults = {}
	
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = {workspace.Terrain}
	
	for i, point in pairs(points) do
		local rayOrigin = Vector3.new(point.X, volume.CFrame.Position.Y + volume.Size.Y * 0.5, point.Z)
		local rayDir = Vector3.new(0, -volume.Size.Y)
		local raycastResult = workspace:Raycast(rayOrigin, rayDir, params)--workspace:Raycast(rayOrigin, rayDir)
		table.insert(raycastResults, raycastResult)

		if (raycastResult ~= nil) then
			if(raycastResult.Instance == terrain) then
				points[i] = raycastResult.Position
			end
		end
	end
	
	--filter on material & slope
	--split the materialFilter string by ','
	local filteredPoints = {}
	local materialFilterList = {}
	for material in materialFilter:gmatch("[^,]+") do
		table.insert(materialFilterList, material)
	end
	
	--print("Filtered materials list: ")
	--print(materialFilterList)
	
	for i = 1, #points do
		if(raycastResults[i] ~= nil) then
			--print(raycastResults[i].Material.Name)
			
			local dp = raycastResults[i].Normal:Dot(Vector3.new(0.0,1.0,0.0))
			local terrainSlope = math.clamp(1.0 - dp, 0.0, 1.0)
			
			local probability = 1
			if slopeDensityCurve ~= nil then 
				probability = evalNumberSequence(slopeDensityCurve, terrainSlope)
			end

			if (math.random() < probability) and (not table.find(materialFilterList, raycastResults[i].Material.Name)) then
				table.insert(filteredPoints, points[i])
				--("Pass")
				--print(materialFilterList)
			end
		end
	end
	
	--print("Filtered "..#points - #filteredPoints.." points")
	
	
	return filteredPoints, raycastResults
end

--[[
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
end--]]

--points is in world space here. 
local function scatterPointsAroundPoints(volume, terrain, seed, points, count, innerRadius, outerRadius)
	math.randomseed(seed)
	
	--print("Scattering "..count.." children points around each of "..#points.." parent points")
	--print("Inner Radius "..innerRadius..", Outer Radius: "..outerRadius)
	
	if outerRadius < innerRadius then
		warn("Invalid inner & outer radii. Skipping")
		return
	end
	
	local newPoints = {}
	for _,p in pairs(points) do
		for i = 1, count do
			--rejection sampling - generate points in an annulus between innerRadius and outerRadius
			local newP = Vector3.new(outerRadius * (2 * math.random() - 1), 0, outerRadius * (2 * math.random() - 1))
			local d = newP.Magnitude
			
			--reject points outside of the inner and outer radii
			while (d > outerRadius or d < innerRadius) do
				newP = Vector3.new(outerRadius * (2 * math.random() - 1), 0, outerRadius * (2 * math.random() - 1))
				d = newP.Magnitude
			end
			
			table.insert(newPoints, p + newP)
		end
	end
	
	print("Scattering "..#newPoints.." children in volume "..volume.Name)
	
	return newPoints
end

local function placeGeoOnPoints(templateGeo, points, scaleRange, colorRange, rotationType)
	--print("Placing geometry on points...")
	local instances = {}
	
	--debug part
	local templatePart = Instance.new("Part")
	templatePart.Size = Vector3.new(1,1,1)
	templatePart.Shape = Enum.PartType.Ball
	templatePart.Anchored = true
	templatePart.CanCollide = false
	templatePart.CanTouch = false

	for _, p in points do
		
		--clone the template part and place it at the point
		local instance = templateGeo:Clone()
		instance.Parent = InstanceFolder
		instance:PivotTo(CFrame.new(p))
		
		--scale the instance
		local scale = 1
		if scaleRange then
			scale = scaleRange.X + math.random() * (scaleRange.Y - scaleRange.X)
		end
		instance:ScaleTo(scale)

		local tintColor = Color3.fromRGB(255, 255, 255)
		if colorRange then
			tintColor = evalColorSequence(colorRange, math.random())
		end
		for _, d in instance:GetDescendants() do
			if d:IsA("MeshPart") then
				local noTint = CollectionService:HasTag(d, "NoTint")
				if not noTint then 
					for _, sa in d:GetDescendants() do
						if sa:IsA("SurfaceAppearance") then
							sa.Color = tintColor
						end
					end
				end
			end
		end

		--randomize rotation
		if rotationType == "Random" then
			instance:PivotTo(instance:GetPivot() * CFrame.Angles(2 * math.random() * math.pi, 2 * math.random() * math.pi, 2 * math.random() * math.pi))
		elseif rotationType == "UpAxis" then
			instance:PivotTo(instance:GetPivot() * CFrame.fromAxisAngle(Vector3.new(0,1,0), math.random() * math.pi * 2))
		end
		
		table.insert(instances, instances)
	end
	return instances
end

local function getExclusionFunction(volume: Part): (Vector3) -> boolean
	local volumeCFrame = volume.CFrame
	local objectSpaceCFrame = volumeCFrame:ToObjectSpace(volumeCFrame)

	local halfX = volume.Size.X / 2
	local halfY = volume.Size.Y / 2
	local halfZ = volume.Size.Z / 2

	local minX = objectSpaceCFrame.Position.X - halfX
	local maxX = objectSpaceCFrame.Position.X + halfX
	local minY = objectSpaceCFrame.Position.Y - halfY
	local maxY = objectSpaceCFrame.Position.Y + halfY
	local minZ = objectSpaceCFrame.Position.Z - halfZ
	local maxZ = objectSpaceCFrame.Position.Z + halfZ
	return function(point: Vector3)
		local transformedPoint = volumeCFrame:PointToObjectSpace(point)

		return minX <= transformedPoint.X and transformedPoint.X <= maxX and minY <= transformedPoint.Y and transformedPoint.Y <= maxY and minZ <= transformedPoint.Z and transformedPoint.Z <= maxZ
	end
end

local function exclusionZoneFunctions(): { (Vector3) -> boolean }
	local exclusionVolumes = CollectionService:GetTagged("ExclusionVolume")
	local exclusionZoneFunctions = {}

	for _, volume in exclusionVolumes do
		if not volume:IsA("Part") then
			continue
		end 

		table.insert(exclusionZoneFunctions, getExclusionFunction(volume))
	end

	return exclusionZoneFunctions
end

local function excludePoints(points: { Vector3 }, exclusionFunctions: { (Vector3) -> boolean }): { Vector3 }
	if not exclusionFunctions then
		return points
	end

	local newPoints: { Vector3 } = table.clone(points)
	local tempPoints: { Vector3 } = {}
	for _, exclusionFunction in exclusionFunctions do
		for _, point in newPoints do
			if not exclusionFunction(point) then
				table.insert(tempPoints, point)
			end
		end

		newPoints = table.clone(tempPoints)
		tempPoints = {}
	end

	return newPoints
end

local function evaluateNode(n, volume, terrain, debugString)
	--print("Evaluating Node "..n.Name)
	
	local exclusionFunctions = exclusionZoneFunctions()

	if n == nil then
		warn("Nil GraphNode!")
		warn(debugString)
	end

	if debugString == nil then
		debugString = n.Parent.Name.."/"..n.Name
	else
		debugString = n.Parent.Name.."/"..n.Name.."->"..debugString
	end
	
	--first, do whatever this node needs to do
	local nodeType = n:GetAttribute("NodeType")
	if nodeType == "Output" then
		--output does nothing. Just needs to evaluate nodes upstream
		for _, wire in pairs(n:GetChildren()) do
			if wire:IsA("ObjectValue") then
				if wire.Value == nil then
					warn("missing value in OutputNode wire "..wire.Name)
				end
				evaluateNode(wire.Value, volume, terrain, debugString)
			end
		end
		return nil
		
	elseif nodeType == "PlaceGeometryOnPoints" then
		local geo = nil
		local assetWire = n:FindFirstChild("Asset")
		if assetWire and assetWire:IsA("ObjectValue") and assetWire.Value ~= nil then
			geo = assetWire.Value
		else
			local geoAssetID = n:GetAttribute("GeometryAssetID")
			if geoAssetID ~= nil then
				geo = InsertService:LoadAsset(geoAssetID):GetChildren()[1]
			else
				warn("PlaceGeometryOnPoints node "..n.Name..": set ObjectValue Asset or GeometryAssetID")
			end
		end

		if geo ~= nil then
			local points = {}
			
			for _, wire in pairs(n:GetChildren()) do
				if wire:IsA("ObjectValue") and wire.Name == "Points" then
					if wire.Value == nil then
						warn("Missing Value in ObjectValue wire "..wire.Name)
					end
					local newPoints = evaluateNode(wire.Value, volume, terrain, debugString)
					for _,p in newPoints do
						table.insert(points, p)
				 	end
				end
			end
			
			local scaleRange = n:GetAttribute("ScaleRange")
			local rotationType = n:GetAttribute("RotationType")
			local colorRange = n:GetAttribute("ColorRange")
			--[[if scaleRange == nil or rotationType == nil or colorRange == nil then
				warn("Missing parameters in node "..n.Name)
			end
			--]]
			
			points = excludePoints(points, exclusionFunctions)
			local result = placeGeoOnPoints(geo, points, scaleRange, colorRange, rotationType)
		end
	elseif nodeType == "SnapPointsToTerrain" then
		local points = {}
		
		local materialFilter = n:GetAttribute("MaterialFilter")
		local slopeDensityCurve = n:GetAttribute("SlopeFilter")
		if materialFilter == nil or slopeDensityCurve == nil then
			warn("Missing parameters on node "..n.Name)
		end
		
		for _, wire in pairs(n:GetChildren()) do
			if wire:IsA("ObjectValue") and wire.Name == "Points" then
				points = evaluateNode(wire.Value, volume, terrain, debugString)
			end
		end
		
		points = excludePoints(points, exclusionFunctions)
		return snapPointsToTerrain(volume, terrain, points, materialFilter, slopeDensityCurve)
	elseif nodeType == "ScatterPoints" then
		local seed = n:GetAttribute("Seed")
		local spacing = n:GetAttribute("Spacing")
		if seed == nil or spacing == nil then
			warn("Missing parameters on node "..n.Name)
		end
		
		--return scatterPoints(volume, terrain, seed, spacing)

		local scatterPointsNode = ScatterPointsNode:new{
			name="ScatterPointsNode",
			_type="ScatterPointsNode",
			seed=seed,
			spacing=spacing
		}
		return scatterPointsNode:evaluate(volume,terrain)
	elseif nodeType == "ScatterPointsAroundPoints" then
		local seed = n:GetAttribute("Seed")
		local innerRadius = n:GetAttribute("InnerRadius")
		local outerRadius = n:GetAttribute("OuterRadius")
		local count = n:GetAttribute("Count")
		if innerRadius == nil or outerRadius == nil or count == nil then
			warn("Missing Parameters on node "..n.Name)
		end
		
		local points = {}
		for _, wire in pairs(n:GetChildren()) do
			if wire:IsA("ObjectValue") and wire.Name == "Points" then
				if wire.Value == nil then
					warn("missing Value in ObjectValue wire "..wire.Name)
				end
				 local newPoints = evaluateNode(wire.Value, volume, terrain, debugString)
				 for _,p in newPoints do
					table.insert(points, p)
				 end
			end
		end
		
		points = excludePoints(points, exclusionFunctions)
		return scatterPointsAroundPoints(volume, terrain, seed, points, count, innerRadius, outerRadius)
	else
		warn("Invalid node encountered: "..n.Name)
	end
end

local function evaluateGraph(g, volume, terrain)
	--first, find all the output nodes
	--print("Evaluating Graph "..g.Name)
	
	for _, node in pairs(g:GetChildren()) do
		local nodeType = node:GetAttribute("NodeType")
		if nodeType == "Output" then
			evaluateNode(node, volume, terrain, nil)
		end
	end
end	
	

local function onPluginButtonClicked()
	BrushToolActive = false
	local terrain = workspace.Terrain
	
	clearAllInstances()
	
	--Collect all Biome Volumes
	local biomeVolumes = CollectionService:GetTagged("ScatterGraphVolume")
	
	--retrieve the ScatterGraph package
	for _, volume in pairs(biomeVolumes) do
		--print(volume.Name)
		
		local scatterGraph = nil
		
		--see if we have an ObjectValue child
		local biomeDefinitionRef = volume:FindFirstChildOfClass("ObjectValue")
		
		if biomeDefinitionRef == nil then
			local biomeDefinitionID = volume:GetAttribute("BiomeDefinitionAssetID")
			
			local biomeAsset = game:GetService("InsertService"):LoadAsset(biomeDefinitionID)
			local packageChildren = biomeAsset:GetChildren()
			scatterGraph = packageChildren[1]
		else
			scatterGraph = biomeDefinitionRef.Value
		end

		local enabled = volume:GetAttribute("Enabled")
		if enabled then
			evaluateGraph(scatterGraph, volume, terrain)
		end
	end
end

local function onClearButtonClicked()
	BrushToolActive = false
	clearAllInstances()
end

local function onBrushButtonClicked()
	BrushToolActive = not BrushToolActive
end

local function onTestButtonClicked()
	print("test")
	local abstractNode = GraphNode:new()
	abstractNode:evaluate(nil, nil)

	local scatterPointsNode = ScatterPointsNode:new{name="ScatterPointsNode", _type="ScatterPointsNode"}
	scatterPointsNode:evaluate(nil, nil)
end

newScriptButton.Click:Connect(onPluginButtonClicked)
clearButton.Click:Connect(onClearButtonClicked)
brushButton.Click:Connect(onBrushButtonClicked)
testButton.Click:Connect(onTestButtonClicked)

--[[
local function onGraphChangedEvent()
	--print("Graph Changed!")
	onPluginButtonClicked()
end


--hack in the scatter graph we care about (no context yet)
local graphChangedEvent = game.ReplicatedStorage.ScatterGraphs.NewScatterGraph:WaitForChild("GraphChanged")
if graphChangedEvent ~= nil then
	graphChangedEvent.Event:Connect(onGraphChangedEvent)
end
--]]