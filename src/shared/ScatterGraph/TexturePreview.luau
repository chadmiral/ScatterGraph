--[[
	TexturePreview

	The small picture a texture node shows on its card, and the only thing the
	Graph view knows about what an evaluation actually made.

	A texture exists during a run and nowhere else: it is worked out from the
	volumes being scattered, read by whatever masks against it, and dropped. The
	canvas, meanwhile, is a window onto the graph rather than onto the run, and
	shows what a node is set to rather than what it did. This is the one place
	the two meet. A run leaves a thumbnail of every texture it made here, against
	the node that made it, and the canvas draws whatever it finds -- so a node
	that has not been evaluated shows nothing, which is how a card says "not run
	yet" without having to find words for it.

	Shrunk on the way in rather than on the way out. A biome's texture runs to
	tens of thousands of cells and a card has room for something under a hundred
	on a side, so it is sampled down once, here, and the large table is not held
	onto afterwards. Sampled by averaging rather than by picking one cell in
	twenty: a noise texture picked from would show a different noise, coarser and
	harsher than the one the scatter is actually read against.

	Cleared at the start of the run it belongs to, so a picture is always of the
	last run that could have made it. A node cut out of its graph stops being
	evaluated and its card goes back to showing nothing, rather than keeping a
	picture of the last time it mattered. A run narrowed to one graph clears only
	that graph's, for the same reason it sweeps only that graph's instances.

	Weak in its keys, so a node deleted from the graph takes its picture with it.
]]

local Texture2D = require(script.Parent:WaitForChild("Texture2D"))

local TexturePreview = {}

-- The longest side of a thumbnail, in samples. A card is 176 pixels across, so
-- there is nothing to be had from carrying more than this, and a texture smaller
-- than it is left at its own size rather than blown up to fill it.
local MAX_SIDE = 96

export type Preview = {
	-- The picture: RGBA, one byte a channel, row 0 at the smallest world Z --
	-- which is the top of the screen looking down, as Studio's own top view has
	-- it.
	pixels: buffer,
	width: number,
	height: number,
	-- What it was made from, for the card to say: the texture's own resolution,
	-- and the ground it covers in studs.
	cells: Vector2,
	studs: Vector2,
	-- The texture this was taken from, so the same one arriving again -- eleven
	-- rules masking against one node ask it for the same texture eleven times --
	-- is recognised rather than sampled down again.
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

-- Every output pixel is the mean of the cells it covers, so the whole of the
-- texture is in the picture even where it is shrunk twenty to one.
local function shrink(texture: Texture2D.Texture): Preview
	local cellsX = math.max(1, math.floor(texture.resolution.X))
	local cellsZ = math.max(1, math.floor(texture.resolution.Y))
	local values = texture.values

	local scale = math.max(1, math.max(cellsX, cellsZ) / MAX_SIDE)
	local width = math.max(1, math.floor(cellsX / scale))
	local height = math.max(1, math.floor(cellsZ / scale))

	local pixels = buffer.create(width * height * 4)

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

			local shade = math.round(math.clamp(total / count, 0, 1) * 255)
			local at = (y * width + x) * 4
			buffer.writeu8(pixels, at, shade)
			buffer.writeu8(pixels, at + 1, shade)
			buffer.writeu8(pixels, at + 2, shade)
			buffer.writeu8(pixels, at + 3, 255)
		end
	end

	return {
		pixels = pixels,
		width = width,
		height = height,
		cells = Vector2.new(cellsX, cellsZ),
		studs = texture.dimensions,
		source = texture,
	}
end

-- Keep a picture of what this node made. Anything that is not a texture is not
-- a picture of anything and is ignored, so a caller may hand over whatever a
-- node returned without looking at it first.
function TexturePreview.record(node: Instance, texture: any)
	if node == nil or not Texture2D.is(texture) then
		return
	end

	local held = previews[node]
	if held ~= nil and held.source == texture then
		return
	end

	previews[node] = shrink(texture)
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
