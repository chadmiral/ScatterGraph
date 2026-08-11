--[[
	MaterialSDF2DNode

	Measures where named terrain materials are into a flat distance field: every
	cell of ground over the volumes being scattered holds how far it is from the
	nearest water, or sand, or whatever the node was asked for, negative within it.
	What reads one can then keep its points a distance clear of that material, or
	hold them to it, without knowing anything about the terrain itself.

	The material of a spot is the material seen looking straight down at it -- the
	topmost terrain voxel with anything in it, within the height the volumes span.
	That is the same surface a point lands on when it is snapped to the terrain, so
	a mask agrees with where the points it is masking end up: water reads as water
	because water is what is on top there, and the ground beneath a lake is not sand
	as far as this node is concerned.

	Materials are named by string, which is what makes this node safe to keep in a
	graph: a graph is shared between places and may not point at anything in one
	of them, but "Water" means water everywhere.

	What ground the field covers is not this node's to choose: the volumes being
	scattered set that rectangle and the evaluator hands it down the graph. How
	finely it is divided is, through Voxel Size, which defaults to the four studs
	terrain stores material on -- the finest the material itself is known to.
]]

local GraphNode = require(script.Parent:WaitForChild("GraphNode"))
local SDFGrid2D = require(script.Parent.Parent:WaitForChild("SDFGrid2D"))

local MaterialSDF2DNode = GraphNode:new()
MaterialSDF2DNode.name = "MaterialSDF2DNode"
MaterialSDF2DNode._type = "MaterialSDF2DNode"

-- The grid terrain is stored on and reads back at.
local TERRAIN_VOXEL = SDFGrid2D.TERRAIN_VOXEL

-- How much terrain one read takes, per axis. Terrain refuses a region of some
-- millions of voxels, and a 256 stud cube is 262144 of them: comfortably inside
-- that, and about ten milliseconds.
local READ_SPAN = 256

-- A voxel counts as terrain if there is anything in it at all. Terrain stores how
-- full a voxel is as well as what it is made of, and a shoreline voxel one tenth
-- full of water is still water to anything keeping out of it.
local MIN_OCCUPANCY = 0

-- The materials named in the node's parameter, and how many names were read.
-- Anything that is not a material is worth saying: a typo would otherwise leave
-- a field that quietly measures nothing.
local function materialsFrom(list: string, nodeName: string): ({ [Enum.Material]: boolean }, number)
	local byName = {}
	for _, material in Enum.Material:GetEnumItems() do
		byName[material.Name] = material
	end

	local wanted = {}
	local count = 0

	for name in list:gmatch("[^,]+") do
		-- "Water, Ice" is as natural to write as "Water,Ice".
		local trimmed = name:match("^%s*(.-)%s*$")

		if trimmed ~= "" then
			local material = byName[trimmed]

			if material == nil then
				warn(
					"ScatterGraph " .. nodeName .. ': "' .. trimmed .. '" is not a terrain material, so nothing '
						.. "was measured from it. Materials are named as they are in the Terrain editor, such as "
						.. "Water, Sand or LeafyGrass."
				)
			elseif not wanted[material] then
				wanted[material] = true
				count += 1
			end
		end
	end

	return wanted, count
end

-- How finely this node was asked to measure. Terrain's own voxel where nothing was
-- asked for, since that is the finest the material itself is known to; a smaller
-- one divides the same patches of material more finely, which sharpens the
-- distances around them rather than the shape of them.
local function voxelSizeOf(node: Instance): number
	local asked = node:GetAttribute("VoxelSize")

	if typeof(asked) ~= "number" then
		return TERRAIN_VOXEL
	end

	if asked <= 0 then
		warn(
			string.format(
				"ScatterGraph %s: Voxel Size is %g, which is no size at all, so the field was measured at "
					.. "%d studs.",
				node.Name,
				asked,
				TERRAIN_VOXEL
			)
		)
		return TERRAIN_VOXEL
	end

	return asked
end

-- The field cells one terrain voxel touches along an axis, clamped to the grid:
-- from the first whose span it reaches into to the last, which is overlap of spans
-- rather than which centre lands where. A cell counts as the material if any of it
-- is in there, so a coarse cell takes in several terrain voxels and a fine one is
-- one of several taking in the same terrain voxel. Either way the material spreads
-- out rather than dropping through the gaps -- the safe direction for anything
-- keeping clear of it.
local function cellRange(voxelLow: number, gridLow: number, voxelSize: number, count: number): (number, number)
	local first = math.floor((voxelLow - gridLow) / voxelSize)
	local last = math.ceil((voxelLow + TERRAIN_VOXEL - gridLow) / voxelSize) - 1

	return math.max(first, 0), math.min(last, count - 1)
end

--[[
	Marks every cell of the layout whose surface is one of the wanted materials.

	The terrain is read a patch at a time, since the whole rectangle at once would be
	past what one read allows over any real biome, and each patch is read from the
	top down: the first voxel found with anything in it is the surface of that
	column, and once every column of a patch has one there is nothing below worth
	reading. Ground with a hollow under it is therefore measured as ground, which is
	what looking down at it says.
]]
local function markSurface(
	terrain: Terrain,
	wanted: { [Enum.Material]: boolean },
	layout: SDFGrid2D.Layout,
	top: number,
	bottom: number
): { boolean }
	local voxelSize = layout.voxelSize
	local countX, countZ = layout.resolution.X, layout.resolution.Y
	local marked = {}

	local low = SDFGrid2D.corner(layout)
	local high = low + Vector2.new(countX * voxelSize, countZ * voxelSize)

	-- A patch need not line up with the field's cells, whatever size those are:
	-- each terrain column is placed in the field by the ground it covers.
	local span = READ_SPAN

	for patchZ = low.Y, high.Y - 1, span do
		for patchX = low.X, high.X - 1, span do
			local patchHighX = math.min(patchX + span, high.X)
			local patchHighZ = math.min(patchZ + span, high.Y)

			-- Which columns of this patch have had their surface found, by the
			-- column's place in the read. Every read over the patch covers the same
			-- columns, since only the height differs, so one set of them serves all
			-- of it.
			local settled = {}
			local remaining = nil

			local depth = top
			while depth > bottom and (remaining == nil or remaining > 0) do
				local slice = math.max(depth - span, bottom)

				-- Terrain will only read whole voxels, and refuses a region that is
				-- not on its grid, which a patch of a field on some other voxel size
				-- need not be. The corner is read back off the region rather than
				-- assumed, since expanding it moves it.
				local region = Region3.new(
					Vector3.new(patchX, slice, patchZ),
					Vector3.new(patchHighX, depth, patchHighZ)
				):ExpandToGrid(TERRAIN_VOXEL)
				local corner = region.CFrame.Position - region.Size * 0.5
				local materials, occupancies = terrain:ReadVoxels(region, TERRAIN_VOXEL)

				local acrossZ = #materials[1][1]
				remaining = remaining or #materials * acrossZ

				-- Down the read rather than across it: the highest voxel with
				-- anything in it settles its column, and lower ones are then passed
				-- over. Terrain voxel (a, b, c) is X, then height, then Z.
				for a = 1, #materials do
					local column, occupancy = materials[a], occupancies[a]
					local base = (a - 1) * acrossZ
					local iFrom, iTo = cellRange(corner.X + (a - 1) * TERRAIN_VOXEL, low.X, voxelSize, countX)

					for b = #column, 1, -1 do
						local row, rowOccupancy = column[b], occupancy[b]

						for c = 1, acrossZ do
							local key = base + c

							if settled[key] == nil and rowOccupancy[c] > MIN_OCCUPANCY then
								settled[key] = true
								remaining -= 1

								if wanted[row[c]] and iFrom <= iTo then
									local kFrom, kTo =
										cellRange(corner.Z + (c - 1) * TERRAIN_VOXEL, low.Y, voxelSize, countZ)

									for k = kFrom, kTo do
										local start = 1 + k * countX

										for i = iFrom, iTo do
											marked[start + i] = true
										end
									end
								end
							end
						end
					end
				end

				depth = slice
			end
		end
	end

	return marked
end

function MaterialSDF2DNode:evaluate(volumes, terrain, ctx)
	local n = ctx.node

	-- Every rule that masks against this node asks it for the same field, and
	-- measuring one is the most expensive thing in a run.
	local cache = ctx.fieldCache
	if cache ~= nil and cache[n] ~= nil then
		return cache[n]
	end

	local list = n:GetAttribute("Materials")
	if list == nil then
		warn("Missing parameters on node " .. n.Name)
		return nil
	end

	local wanted, count = materialsFrom(list, n.Name)
	if count == 0 then
		warn(
			"ScatterGraph " .. n.Name .. ": Materials names no terrain material, so there is no field to "
				.. "measure. Set it to a comma-separated list such as Water,Sand."
		)
		return nil
	end

	-- The rectangle comes from the volumes, handed down the graph; the cell size is
	-- this node's own, so the grid is re-divided when it asks for something other
	-- than what the run settled on. Working it out here rather than taking the one
	-- handed down costs nothing but the arithmetic -- the volumes decide the rest of
	-- it either way.
	local voxelSize = voxelSizeOf(n)
	local layout = ctx.gridLayout
	if layout == nil or layout.voxelSize ~= voxelSize then
		layout = SDFGrid2D.layoutFor(volumes, voxelSize)
	end

	-- The height to look down from, and how far: the same span the snap casts its
	-- rays through, so the two agree about what the surface is.
	local top, length = volumes:verticalBounds()
	local marked = markSurface(terrain, wanted, layout, top, top - length)
	local grid = SDFGrid2D.fromCells(layout, marked, terrain)

	if cache ~= nil then
		cache[n] = grid
	end

	return grid
end

return MaterialSDF2DNode
