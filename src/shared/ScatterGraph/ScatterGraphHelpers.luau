local CollectionService = game:GetService("CollectionService")

local VolumeShape = require(script.Parent:WaitForChild("VolumeShape"))

local M = {}

function M.evalNumberSequence(sequence: NumberSequence, time: number)
	if time == 0 then
		return sequence.Keypoints[1].Value
	elseif time == 1 then
		return sequence.Keypoints[#sequence.Keypoints].Value
	end

	for i = 1, #sequence.Keypoints - 1 do
		local currKeypoint = sequence.Keypoints[i]
		local nextKeypoint = sequence.Keypoints[i + 1]
		if time >= currKeypoint.Time and time < nextKeypoint.Time then
			local alpha = (time - currKeypoint.Time) / (nextKeypoint.Time - currKeypoint.Time)
			return currKeypoint.Value + (nextKeypoint.Value - currKeypoint.Value) * alpha
		end
	end
end

function M.evalColorSequence(sequence: ColorSequence, time: number)
	if time == 0 then
		return sequence.Keypoints[1].Value
	elseif time == 1 then
		return sequence.Keypoints[#sequence.Keypoints].Value
	end

	for i = 1, #sequence.Keypoints - 1 do
		local thisKeypoint = sequence.Keypoints[i]
		local nextKeypoint = sequence.Keypoints[i + 1]
		if time >= thisKeypoint.Time and time < nextKeypoint.Time then
			local alpha = (time - thisKeypoint.Time) / (nextKeypoint.Time - thisKeypoint.Time)
			return Color3.new(
				(nextKeypoint.Value.R - thisKeypoint.Value.R) * alpha + thisKeypoint.Value.R,
				(nextKeypoint.Value.G - thisKeypoint.Value.G) * alpha + thisKeypoint.Value.G,
				(nextKeypoint.Value.B - thisKeypoint.Value.B) * alpha + thisKeypoint.Value.B
			)
		end
	end
end

function M.snapPointsToTerrain(volumes, terrain, points, materialFilter, slopeDensityCurve)
	local raycastResults = {}

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }

	-- Rays span the group's world-space Y extent (which is taller than Size.Y
	-- once a volume is rotated); the containment test below is what actually
	-- confines hits to the volumes' shapes.
	local rayOriginY, rayLength = volumes:verticalBounds()
	local insideVolume = volumes:containsPointFunction()

	for i, point in pairs(points) do
		local rayOrigin = Vector3.new(point.X, rayOriginY, point.Z)
		local rayDir = Vector3.new(0, -rayLength, 0)
		local raycastResult = workspace:Raycast(rayOrigin, rayDir, params)
		-- Index by i (not table.insert): a missed ray returns nil, and
		-- table.insert(t, nil) is a silent no-op that would shift every later
		-- result down an index, misaligning raycastResults from points and
		-- corrupting the material/slope filters.
		raycastResults[i] = raycastResult

		if raycastResult ~= nil then
			if raycastResult.Instance == terrain then
				points[i] = raycastResult.Position
			end
		end
	end

	local filteredPoints = {}
	local materialFilterList = {}
	for material in materialFilter:gmatch("[^,]+") do
		table.insert(materialFilterList, material)
	end

	for i = 1, #points do
		if raycastResults[i] ~= nil and insideVolume(points[i]) then
			local dp = raycastResults[i].Normal:Dot(Vector3.new(0.0, 1.0, 0.0))
			local terrainSlope = math.clamp(1.0 - dp, 0.0, 1.0)

			local probability = 1
			if slopeDensityCurve ~= nil then
				probability = M.evalNumberSequence(slopeDensityCurve, terrainSlope)
			end

			if (math.random() < probability) and (not table.find(materialFilterList, raycastResults[i].Material.Name)) then
				table.insert(filteredPoints, points[i])
			end
		end
	end

	return filteredPoints, raycastResults
end

function M.scatterPointsAroundPoints(volumes, terrain, seed, points, count, innerRadius, outerRadius)
	math.randomseed(seed)

	if outerRadius < innerRadius then
		warn("Invalid inner & outer radii. Skipping")
		return
	end

	-- Cluster offsets can push a point past the edge of a volume, so they are
	-- clipped to the group's footprint the same way the source scatter is.
	local insideFootprint = volumes:footprintFunction()

	local newPoints = {}
	for _, p in pairs(points) do
		for _ = 1, count do
			local newP = Vector3.new(outerRadius * (2 * math.random() - 1), 0, outerRadius * (2 * math.random() - 1))
			local d = newP.Magnitude

			while d > outerRadius or d < innerRadius do
				newP = Vector3.new(outerRadius * (2 * math.random() - 1), 0, outerRadius * (2 * math.random() - 1))
				d = newP.Magnitude
			end

			local clusterPoint = p + newP
			if insideFootprint(clusterPoint.X, clusterPoint.Z) then
				table.insert(newPoints, clusterPoint)
			end
		end
	end

	print("Scattering " .. #newPoints .. " children in " .. volumes.name)

	return newPoints
end

function M.placeGeoOnPoints(
	templateGeo,
	points,
	scaleRange,
	colorRange,
	rotationType,
	instanceFolder: Folder,
	occupancy,
	avoidIntersections: boolean?,
	radius: number?,
	priority: number?,
	branchId: any
)
	local instances = {}
	radius = radius or 5
	priority = priority or 0

	-- Branches that opt in to avoidance are deferred: their placements are
	-- collected as candidates and resolved once, after every branch has been
	-- evaluated, so the outcome is independent of branch evaluation order.
	local defer = avoidIntersections == true and occupancy ~= nil

	for _, p in points do
		local instance = templateGeo:Clone()
		instance.Parent = instanceFolder
		instance:PivotTo(CFrame.new(p))

		local scale = 1
		if scaleRange then
			scale = scaleRange.X + math.random() * (scaleRange.Y - scaleRange.X)
		end
		instance:ScaleTo(scale)

		local tintColor = Color3.fromRGB(255, 255, 255)
		if colorRange then
			tintColor = M.evalColorSequence(colorRange, math.random())
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

		if rotationType == "Random" then
			instance:PivotTo(instance:GetPivot() * CFrame.Angles(2 * math.random() * math.pi, 2 * math.random() * math.pi, 2 * math.random() * math.pi))
		elseif rotationType == "UpAxis" then
			instance:PivotTo(instance:GetPivot() * CFrame.fromAxisAngle(Vector3.new(0, 1, 0), math.random() * math.pi * 2))
		end

		-- The footprint is a circle of the given radius centered on the placement
		-- point (rotation/scale pivot about p, so the center stays at p).
		if defer then
			-- Do not tag yet; resolveDeferred decides which candidates survive.
			occupancy:addCandidate({
				instance = instance,
				x = p.X,
				z = p.Z,
				radius = radius,
				priority = priority,
				branchId = branchId,
			})
		else
			CollectionService:AddTag(instance, "ScatterGraphInstance")
			-- Register as an always-kept footprint so opt-in branches avoid it.
			if occupancy then
				occupancy:addSolid(p.X, p.Z, radius, branchId)
			end
			table.insert(instances, instance)
		end
	end

	return instances
end

function M.getExclusionFunction(volume: BasePart): (Vector3) -> boolean
	return VolumeShape.containsPointFunction(volume)
end

function M.exclusionZoneFunctions(): { (Vector3) -> boolean }
	local exclusionVolumes = CollectionService:GetTagged("ExclusionVolume")
	local exclusionZoneFunctions = {}

	for _, volume in exclusionVolumes do
		if not volume:IsA("BasePart") then
			continue
		end

		table.insert(exclusionZoneFunctions, M.getExclusionFunction(volume))
	end

	return exclusionZoneFunctions
end

function M.excludePoints(points: { Vector3 }, exclusionFunctions: { (Vector3) -> boolean }): { Vector3 }
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

return M
