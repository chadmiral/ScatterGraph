--[[
	TexturePreview

	The small picture a node that measures something over the ground shows on its
	card, and the only thing the Graph view knows about what an evaluation
	actually made.

	A texture exists during a run and nowhere else: it is worked out from the
	volumes being scattered, read by whatever masks against it, and dropped. The
	canvas, meanwhile, is a window onto the graph rather than onto the run, and
	shows what a node is set to rather than what it did. This is the one place
	the two meet. A run leaves a thumbnail of every texture and every distance
	field it made here, against the node that made it, and the canvas draws
	whatever it finds -- so a node that has not been evaluated shows nothing,
	which is how a card says "not run yet" without having to find words for it.

	Shrunk on the way in rather than on the way out. A biome's texture runs to
	tens of thousands of cells and a card has room for something under a hundred
	on a side, so it is sampled down once, here, and the large table is not held
	onto afterwards. Sampled by averaging rather than by picking one cell in
	twenty: a noise texture picked from would show a different noise, coarser and
	harsher than the one the scatter is actually read against.

	The two kinds of picture are shaded differently because their numbers mean
	different things. A texture is already a shade -- nought to one, black to
	white -- and is drawn as exactly that, since grey there means a stated chance
	and shading it any other way would be a lie about it. A distance field is
	studs, signed, and runs as far as the ground it is measured over, so there is
	no shade it already is: it is stretched to fill the picture instead, each side
	of the material to its own extreme, which puts the edge of the material at the
	halfway tone and gives both the shape of the material and the run of ground
	around it as much of the ramp as they can use. What those two extremes were is
	kept alongside, since a stretched picture says nothing about scale on its own
	and the card has to say it in words.

	Pictures are greyscale whichever they are. The view tints a field with the
	colour its wires and ports already carry, so the two kinds do not have to be
	told apart by squinting at them.

	Cleared at the start of the run it belongs to, so a picture is always of the
	last run that could have made it. A node cut out of its graph stops being
	evaluated and its card goes back to showing nothing, rather than keeping a
	picture of the last time it mattered. A run narrowed to one graph clears only
	that graph's, for the same reason it sweeps only that graph's instances.

	Weak in its keys, so a node deleted from the graph takes its picture with it.
]]

local Texture2D = require(script.Parent:WaitForChild("Texture2D"))
local SDFGrid2D = require(script.Parent:WaitForChild("SDFGrid2D"))

local TexturePreview = {}

-- The longest side of a thumbnail, in samples. A card is 176 pixels across, so
-- there is nothing to be had from carrying more than this, and a texture smaller
-- than it is left at its own size rather than blown up to fill it.
local MAX_SIDE = 96

export type Preview = {
	-- Which of the two this is a picture of, since a card says something
	-- different about each and draws them in different colours.
	kind: "density" | "field",
	-- The picture: RGBA, one byte a channel, row 0 at the smallest world Z --
	-- which is the top of the screen looking down, as Studio's own top view has
	-- it. Greyscale, whatever the card goes on to tint it.
	pixels: buffer,
	width: number,
	height: number,
	-- What it was made from, for the card to say: the resolution it was measured
	-- at, and the ground it covers in studs.
	cells: Vector2,
	studs: Vector2,
	-- How far the darkest and brightest of a field's picture stand from the
	-- material, in studs: the first is into it, the second clear of it. Both nil
	-- for a density, which is not stretched and means what it looks like.
	inside: number?,
	outside: number?,
	-- What this was taken from, so the same thing arriving again -- eleven rules
	-- masking against one node ask it for the same texture eleven times -- is
	-- recognised rather than sampled down again.
	source: any,
}

local previews: { [Instance]: Preview } = setmetatable({}, { __mode = "k" }) :: any
local listeners: { [() -> ()]: boolean } = {}

local function announce()
	-- Spawned rather than called: a window unhappy about a picture is not a
	-- reason for the run that made it to stop.
	for callback in listeners do
		task.spawn(callback)
	end
end

-- Every output pixel is the mean of the cells it covers, so the whole of what
-- was measured is in the picture even where it is shrunk twenty to one. Returns
-- the means themselves rather than a picture: what shade one of them is depends
-- on what the numbers are of, and in a field's case on all of them together.
local function averaged(values: { number }, resolution: Vector2): ({ number }, number, number)
	local cellsX = math.max(1, math.floor(resolution.X))
	local cellsZ = math.max(1, math.floor(resolution.Y))

	local scale = math.max(1, math.max(cellsX, cellsZ) / MAX_SIDE)
	local width = math.max(1, math.floor(cellsX / scale))
	local height = math.max(1, math.floor(cellsZ / scale))

	local means = table.create(width * height)
	local at = 1

	for y = 0, height - 1 do
		-- The band of cells this row of the picture stands for. The last one is
		-- pinned to the first so a row is never empty when the arithmetic of a
		-- shrink by a fraction leaves it that way.
		local firstZ = math.floor(y * cellsZ / height)
		local lastZ = math.max(firstZ, math.floor((y + 1) * cellsZ / height) - 1)

		for x = 0, width - 1 do
			local firstX = math.floor(x * cellsX / width)
			local lastX = math.max(firstX, math.floor((x + 1) * cellsX / width) - 1)

			local total, count = 0, 0
			for k = firstZ, lastZ do
				local row = k * cellsX
				for i = firstX, lastX do
					total += values[1 + row + i] or 0
					count += 1
				end
			end

			means[at] = total / count
			at += 1
		end
	end

	return means, width, height
end

-- A greyscale picture from a shade per pixel, each already between nought and
-- one.
local function paint(shades: { number }): buffer
	local pixels = buffer.create(#shades * 4)

	for index, shade in shades do
		local level = math.round(math.clamp(shade, 0, 1) * 255)
		local at = (index - 1) * 4

		buffer.writeu8(pixels, at, level)
		buffer.writeu8(pixels, at + 1, level)
		buffer.writeu8(pixels, at + 2, level)
		buffer.writeu8(pixels, at + 3, 255)
	end

	return pixels
end

local function shrinkTexture(texture: Texture2D.Texture): Preview
	local means, width, height = averaged(texture.values, texture.resolution)

	return {
		kind = "density",
		pixels = paint(means),
		width = width,
		height = height,
		cells = texture.resolution,
		studs = texture.dimensions,
		source = texture,
	}
end

--[[
	A field's picture, stretched to fill the ramp: black at the deepest the
	picture goes into the material, white at the furthest it stands from it, and
	the halfway tone exactly on the edge of it.

	Each side is stretched by its own extreme rather than both by the larger.
	Grass covers most of a forest, so its field runs a couple of hundred studs
	deep inside and a few tens outside; one scale over both would flatten the
	ground around it -- the part a threshold is nearly always cut from -- into a
	band of greys a shade apart.

	Measured off the picture rather than off the field, so the extremes describe
	what is actually on screen: the darkest pixel is the darkest there is, and
	what the card says about it is true of the pixel it is pointing at.
]]
local function shrinkField(field: SDFGrid2D.Grid): Preview
	local means, width, height = averaged(field.distances, field.resolution)

	local inside, outside = 0, 0
	for _, distance in means do
		if distance < 0 then
			inside = math.max(inside, -distance)
		else
			outside = math.max(outside, distance)
		end
	end

	-- A field with no material in it at all, or none of it anything but, has one
	-- side of the ramp to itself; the divisions below still have to mean
	-- something.
	local depth = if inside > 0 then inside else 1
	local reach = if outside > 0 then outside else 1

	local shades = table.create(#means)
	for index, distance in means do
		shades[index] = if distance < 0 then 0.5 * (1 + distance / depth) else 0.5 * (1 + distance / reach)
	end

	return {
		kind = "field",
		pixels = paint(shades),
		width = width,
		height = height,
		cells = field.resolution,
		studs = field.dimensions,
		inside = inside,
		outside = outside,
		source = field,
	}
end

-- Keep a picture of the texture this node made. Anything that is not a texture
-- is not a picture of anything and is ignored, so a caller may hand over
-- whatever a node returned without looking at it first.
function TexturePreview.recordTexture(node: Instance, texture: any)
	if node == nil or not Texture2D.is(texture) then
		return
	end

	local held = previews[node]
	if held ~= nil and held.source == texture then
		return
	end

	previews[node] = shrinkTexture(texture)
	announce()
end

-- The same, for a node that measures a distance field rather than filling a
-- texture.
function TexturePreview.recordField(node: Instance, field: any)
	if node == nil or not SDFGrid2D.is(field) then
		return
	end

	local held = previews[node]
	if held ~= nil and held.source == field then
		return
	end

	previews[node] = shrinkField(field)
	announce()
end

function TexturePreview.of(node: Instance): Preview?
	return previews[node]
end

-- Forget the pictures of a graph's nodes, or of every node when given nothing,
-- which is what a run does before it begins making new ones.
function TexturePreview.clear(under: Instance?)
	local cleared = false

	for node in previews do
		if under == nil or node:IsDescendantOf(under) then
			previews[node] = nil
			cleared = true
		end
	end

	if cleared then
		announce()
	end
end

-- Called after a picture is taken or forgotten. Returns the way to stop being
-- called.
function TexturePreview.onChanged(callback: () -> ()): () -> ()
	listeners[callback] = true

	return function()
		listeners[callback] = nil
	end
end

return TexturePreview
