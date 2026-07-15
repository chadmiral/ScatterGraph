local CollectionService = game:GetService("CollectionService")

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

function M.snapPointsToTerrain(volume, terrain, points, materialFilter, slopeDensityCurve)
	local raycastResults = {}

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }

	for i, point in pairs(points) do
		local rayOrigin = Vector3.new(point.X, volume.CFrame.Position.Y + volume.Size.Y * 0.5, point.Z)
		local rayDir = Vector3.new(0, -volume.Size.Y)
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
		if raycastResults[i] ~= nil then
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

function M.scatterPointsAroundPoints(volume, terrain, seed, points, count, innerRadius, outerRadius)
	math.randomseed(seed)

	if outerRadius < innerRadius then
		warn("Invalid inner & outer radii. Skipping")
		return
	end

	local newPoints = {}
	for _, p in pairs(points) do
		for _ = 1, count do
			local newP = Vector3.new(outerRadius * (2 * math.random() - 1), 0, outerRadius * (2 * math.random() - 1))
			local d = newP.Magnitude

			while d > outerRadius or d < innerRadius do
				newP = Vector3.new(outerRadius * (2 * math.random() - 1), 0, outerRadius * (2 * math.random() - 1))
				d = newP.Magnitude
			end

			table.insert(newPoints, p + newP)
		end
	end

	print("Scattering " .. #newPoints .. " children in volume " .. volume.Name)

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

function M.getExclusionFunction(volume: Part): (Vector3) -> boolean
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

		return minX <= transformedPoint.X
			and transformedPoint.X <= maxX
			and minY <= transformedPoint.Y
			and transformedPoint.Y <= maxY
			and minZ <= transformedPoint.Z
			and transformedPoint.Z <= maxZ
	end
end

function M.exclusionZoneFunctions(): { (Vector3) -> boolean }
	local exclusionVolumes = CollectionService:GetTagged("ExclusionVolume")
	local exclusionZoneFunctions = {}

	for _, volume in exclusionVolumes do
		if not volume:IsA("Part") then
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
