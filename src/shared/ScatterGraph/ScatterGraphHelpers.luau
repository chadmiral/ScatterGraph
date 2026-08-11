local CollectionService = game:GetService("CollectionService")

local VolumeShape = require(script.Parent:WaitForChild("VolumeShape"))
local PlacementStamp = require(script.Parent:WaitForChild("PlacementStamp"))
local PlacementLedger = require(script.Parent:WaitForChild("PlacementLedger"))
local SDFGrid2D = require(script.Parent:WaitForChild("SDFGrid2D"))

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
		return {}
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

-- Assigns each point an occurrence index within its own millimetre-quantised
-- X,Z cell, so two placements of one rule that share a column can still be told
-- apart. Ordered by height, then by the order they were handed in, so the same
-- point set always yields the same indices. Returned keyed by original index,
-- since the placement loop must run in its original order to keep the random
-- stream aligned.
local function occurrenceIndices(points): { number }
	local cells = {}
	for index, p in points do
		local cellKey = PlacementLedger.qmm(p.X) .. "," .. PlacementLedger.qmm(p.Z)
		local cell = cells[cellKey]
		if cell == nil then
			cell = {}
			cells[cellKey] = cell
		end
		table.insert(cell, { index = index, y = p.Y })
	end

	local occByIndex = table.create(#points)
	for _, cell in cells do
		table.sort(cell, function(a, b)
			if a.y ~= b.y then
				return a.y < b.y
			end
			return a.index < b.index
		end)
		for rank, item in cell do
			occByIndex[item.index] = rank - 1
		end
	end
	return occByIndex
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
	run,
	graphKey: string?,
	ruleKey: string?,
	ruleName: string?
)
	local instances = {}
	radius = radius or 5
	priority = priority or 0

	-- The rule's own key doubles as the branch id, so a rule never rejects its
	-- own placements -- fresh or promoted -- while a different rule does.
	local branchId = ruleKey or templateGeo
	local tracking = run ~= nil and graphKey ~= nil and ruleKey ~= nil

	-- One folder per rule under ScatterGraphInstances, so the Explorer reads like
	-- the graph and deleting a rule's folder by hand is a legible act.
	local targetFolder = instanceFolder
	if graphKey ~= nil and ruleName ~= nil then
		local graphFolder = instanceFolder:FindFirstChild(graphKey)
		if graphFolder == nil then
			graphFolder = Instance.new("Folder")
			graphFolder.Name = graphKey
			graphFolder.Parent = instanceFolder
		end
		local ruleFolder = graphFolder:FindFirstChild(ruleName)
		if ruleFolder == nil then
			ruleFolder = Instance.new("Folder")
			ruleFolder.Name = ruleName
			ruleFolder.Parent = graphFolder
		end
		targetFolder = ruleFolder
	end

	-- Counts as evaluated even if no point survives, so its stale entries are
	-- pruned rather than left to be misread as deletions next run.
	if tracking then
		run:markEvaluated(graphKey, ruleKey, ruleName)
	end

	local occByIndex = occurrenceIndices(points)

	-- Branches that opt in to avoidance are deferred: their placements are
	-- collected as candidates and resolved once, after every branch has been
	-- evaluated, so the outcome is independent of branch evaluation order.
	local defer = avoidIntersections == true and occupancy ~= nil

	for index, p in points do
		local xmm = PlacementLedger.qmm(p.X)
		local zmm = PlacementLedger.qmm(p.Z)
		local occ = occByIndex[index]

		-- Draw the random stream first and unconditionally: a suppressed point
		-- must consume the very same draws a placed one would, or deleting a
		-- single prop would restyle every prop scattered after it.
		local scale = 1
		if scaleRange then
			scale = scaleRange.X + math.random() * (scaleRange.Y - scaleRange.X)
		end
		local tintColor = Color3.fromRGB(255, 255, 255)
		if colorRange then
			tintColor = M.evalColorSequence(colorRange, math.random())
		end
		local rotation = nil
		if rotationType == "Random" then
			rotation = CFrame.Angles(2 * math.random() * math.pi, 2 * math.random() * math.pi, 2 * math.random() * math.pi)
		elseif rotationType == "UpAxis" then
			rotation = CFrame.fromAxisAngle(Vector3.new(0, 1, 0), math.random() * math.pi * 2)
		end

		local place = not tracking or run:shouldPlace(graphKey, ruleKey, xmm, zmm, occ)
		if place then
			local instance = templateGeo:Clone()
			instance.Parent = targetFolder
			instance:PivotTo(CFrame.new(p))
			instance:ScaleTo(scale)

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

			if rotation then
				instance:PivotTo(instance:GetPivot() * rotation)
			end

			-- Where this came from and what it looks like, so the next run can
			-- match it to its point and tell an untouched prop from an edited
			-- one. The stamp is taken last, once every transform has landed.
			if tracking then
				instance:SetAttribute("ScatterGraph", graphKey)
				instance:SetAttribute("ScatterRule", ruleKey)
				instance:SetAttribute("ScatterOrigin", p)
				instance:SetAttribute("ScatterOccurrence", occ)
				instance:SetAttribute("ScatterRadius", radius)
				instance:SetAttribute("ScatterStamp", PlacementStamp.stamp(instance))
			end

			-- The footprint is a circle of the given radius centered on the
			-- placement point (rotation/scale pivot about p, so the center stays
			-- at p).
			if defer then
				-- Do not tag or record yet; resolveDeferred decides which
				-- candidates survive and records the winners.
				occupancy:addCandidate({
					instance = instance,
					x = p.X,
					z = p.Z,
					xmm = xmm,
					zmm = zmm,
					occ = occ,
					radius = radius,
					priority = priority,
					branchId = branchId,
					ruleKey = ruleKey,
				})
			else
				CollectionService:AddTag(instance, "ScatterGraphInstance")
				-- Register as an always-kept footprint so opt-in branches avoid it.
				if occupancy then
					occupancy:addSolid(p.X, p.Z, radius, branchId)
				end
				if tracking then
					run:recordPlaced(graphKey, ruleKey, xmm, zmm, occ)
				end
				table.insert(instances, instance)
			end
		end
	end

	return instances
end

-- An exclusion volume: the part's own shape as a test, and which rules it keeps
-- points out of.
export type ExclusionZone = {
	volume: BasePart,
	contains: (Vector3) -> boolean,
	-- The Output registry entries this volume excludes, or nil where it names
	-- none and so excludes every rule in the place.
	targets: { Instance }?,
}

function M.getExclusionFunction(volume: BasePart): (Vector3) -> boolean
	return VolumeShape.containsPointFunction(volume)
end

-- Is this what an exclusion volume's ObjectValue is meant to point at -- one of
-- the entries under a graph's Output node, which is what names a single rule?
local function isOutputEntry(target: Instance): boolean
	if not target:IsA("ObjectValue") then
		return false
	end

	local registry = target.Parent
	return registry ~= nil and registry:GetAttribute("NodeType") == "Output"
end

-- Which rules a volume excludes, read from its ObjectValue children: each one
-- points at the Output entry of a rule to keep out. A volume with no children
-- names no rules and so excludes all of them, which is how every exclusion volume
-- behaved before any of them could be aimed.
--
-- A child that points at nothing, or at something that is not an Output entry, is
-- a half-finished aim rather than a licence to exclude everything: it excludes
-- nothing and says so. This is the one place with a whole volume in hand to say
-- it from, so it is said here, once a run, rather than once a rule.
local function targetsOf(volume: BasePart): { Instance }?
	local targets = nil

	for _, child in volume:GetChildren() do
		if child:IsA("ObjectValue") then
			targets = targets or {}

			if child.Value == nil then
				warn(
					"Exclusion volume " .. volume.Name .. ": its " .. child.Name .. " points at nothing. Set "
						.. "it to the Output entry of the rule to exclude, or delete it to exclude every rule."
				)
			elseif not isOutputEntry(child.Value) then
				warn(
					"Exclusion volume " .. volume.Name .. ": its " .. child.Name .. " points at "
						.. child.Value:GetFullName() .. ", which is not one of an Output node's entries, so it "
						.. "excludes nothing."
				)
			else
				table.insert(targets, child.Value)
			end
		end
	end

	return targets
end

-- Every part tagged ExclusionVolume, with the rules each one applies to. Built
-- once a run: the tag is read once, each part's shape is worked out once, and
-- anything wrong with how one is aimed is reported once.
function M.exclusionZones(): { ExclusionZone }
	local zones = {}

	for _, volume in CollectionService:GetTagged("ExclusionVolume") do
		if not volume:IsA("BasePart") then
			continue
		end

		table.insert(zones, {
			volume = volume,
			contains = M.getExclusionFunction(volume),
			targets = targetsOf(volume),
		})
	end

	return zones
end

-- The exclusion tests that apply to one rule: every volume that names it, and
-- every volume that names no rule at all. `rule` is the Output entry that names
-- the chain being evaluated.
function M.exclusionZoneFunctions(zones: { ExclusionZone }, rule: Instance?): { (Vector3) -> boolean }
	local functions = {}

	for _, zone in zones do
		local applies = false

		if zone.targets == nil then
			applies = true
		elseif rule ~= nil then
			applies = table.find(zone.targets, rule) ~= nil
		end

		if applies then
			table.insert(functions, zone.contains)
		end
	end

	return functions
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

-- The slots a scattering node takes its mask on, named as DataTypes declares
-- them: the field to measure candidates against, and how far off it they must be.
local SDF_MASK_WIRE = "SDFMask"
local MASK_DISTANCE_WIRE = "MaskDistance"

-- What a Mask Distance slot stands at while nothing is wired to it. Zero rejects
-- a candidate inside the masked shape and nothing else, which is the least a mask
-- can be asked to do.
local DEFAULT_MASK_DISTANCE = 0

local function wireNamed(node: Instance, name: string): ObjectValue?
	for _, child in node:GetChildren() do
		if child:IsA("ObjectValue") and child.Name == name then
			return child
		end
	end

	return nil
end

--[[
	The mask on a node: the field wired to its SDF Mask slot, and the distance
	wired to its Mask Distance slot or the default in its place.

	Both slots are read here rather than in each node, since both scattering nodes
	take the same mask and would otherwise say so twice. A slot left empty is not a
	mistake -- most nodes have no mask at all -- but a slot wired to something that
	does not produce what it asks for is, and is said once per evaluation.
]]
function M.readMask(node: Instance, volumes, terrain, ctx): (SDFGrid2D.Grid?, number)
	local distance = DEFAULT_MASK_DISTANCE

	local distanceWire = wireNamed(node, MASK_DISTANCE_WIRE)
	if distanceWire ~= nil and distanceWire.Value ~= nil then
		local value = ctx.evaluateNode(distanceWire.Value, volumes, terrain, ctx.debugString)

		if typeof(value) == "number" then
			distance = value
		else
			warn(
				"Node " .. node.Name .. ": its Mask Distance wire points at " .. distanceWire.Value.Name
					.. ", which does not produce a number, so the mask stands at " .. DEFAULT_MASK_DISTANCE .. "."
			)
		end
	end

	local maskWire = wireNamed(node, SDF_MASK_WIRE)
	if maskWire == nil or maskWire.Value == nil then
		return nil, distance
	end

	local grid = ctx.evaluateNode(maskWire.Value, volumes, terrain, ctx.debugString)
	if not SDFGrid2D.is(grid) then
		warn(
			"Node " .. node.Name .. ": its SDF Mask wire points at " .. maskWire.Value.Name
				.. ", which does not produce a distance field, so nothing is masked."
		)
		return nil, distance
	end

	return grid, distance
end

-- Drops every point the mask rejects: one standing nearer the masked shape than
-- `distance`. On the shape the field reads negative, so any distance at all keeps
-- points off it, and a negative distance allows them that far in. The field is
-- flat, so a point is measured by where it stands rather than by how high it is,
-- and masking before or after a snap comes to the same thing. A node with no field
-- wired to it masks nothing.
function M.maskPoints(points: { Vector3 }, mask: SDFGrid2D.Grid?, distance: number): { Vector3 }
	if mask == nil then
		return points
	end

	local kept = {}
	for _, point in points do
		if SDFGrid2D.sample(mask, point) >= distance then
			table.insert(kept, point)
		end
	end

	return kept
end

return M
