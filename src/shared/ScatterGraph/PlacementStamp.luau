--[[
	PlacementStamp

	One number that says what a placed instance looked like when the system put
	it down, so the next run can tell an untouched placement from a hand-edited
	one without remembering the whole thing.

	The number is folded from the instance's pivot and scale and, for every
	descendant, its shape and the parts of its look the placer itself writes:
	a part's box and colour and material, a SurfaceAppearance's tint. Part
	transforms are folded *relative to the pivot*, so sliding or turning the
	whole model -- which the pivot already records -- reads the same, while
	nudging one part inside it does not. Every real number is rounded to a
	thousandth before folding, so a save and reload, which is not an edit, does
	not read as one.

	Attributes are deliberately ignored: the placer stamps several of its own
	onto each instance, and a fingerprint that counted them would never match.
]]

local PlacementStamp = {}

-- Folds stay inside 2^48, which is a whole number of degrees short of the 2^53
-- where a double stops counting by ones: h * 31 is then under 2^53, so no fold
-- ever loses its low bit.
local MODULUS = 281474976710656

local function fold(hash: number, value: number): number
	return (hash * 31 + (value % MODULUS)) % MODULUS
end

-- A thousandth of a stud or a radian is finer than anything an author moves by
-- hand, and coarse enough that the same placement folds identically every run.
local function quant(value: number): number
	return math.round(value * 1000)
end

local function foldString(hash: number, text: string): number
	for index = 1, #text do
		hash = fold(hash, string.byte(text, index))
	end
	return hash
end

local function foldCFrame(hash: number, cframe: CFrame): number
	hash = fold(hash, quant(cframe.X))
	hash = fold(hash, quant(cframe.Y))
	hash = fold(hash, quant(cframe.Z))
	local rx, ry, rz = cframe:ToEulerAnglesXYZ()
	hash = fold(hash, quant(rx))
	hash = fold(hash, quant(ry))
	hash = fold(hash, quant(rz))
	return hash
end

local function foldColor(hash: number, color: Color3): number
	hash = fold(hash, math.round(color.R * 255))
	hash = fold(hash, math.round(color.G * 255))
	hash = fold(hash, math.round(color.B * 255))
	return hash
end

-- The fingerprint of one placed instance, in the state it is in right now.
function PlacementStamp.stamp(instance: Instance): number
	local hash = 0

	local pivot = if instance:IsA("PVInstance") then instance:GetPivot() else CFrame.identity
	hash = foldCFrame(hash, pivot)
	if instance:IsA("Model") then
		hash = fold(hash, quant(instance:GetScale()))
	end

	-- Everything a part carries is measured against the pivot, so the whole
	-- model can be dragged anywhere without changing a single descendant term.
	local inverse = pivot:Inverse()
	local descendants = instance:GetDescendants()
	-- Count first, so adding or deleting a child is caught even if two names
	-- happen to fold to the same place.
	hash = fold(hash, #descendants)

	for _, descendant in descendants do
		hash = foldString(hash, descendant.ClassName)
		hash = foldString(hash, descendant.Name)

		if descendant:IsA("BasePart") then
			hash = foldCFrame(hash, inverse * descendant.CFrame)
			hash = fold(hash, quant(descendant.Size.X))
			hash = fold(hash, quant(descendant.Size.Y))
			hash = fold(hash, quant(descendant.Size.Z))
			hash = foldColor(hash, descendant.Color)
			hash = fold(hash, descendant.Material.Value)
			hash = fold(hash, math.round(descendant.Transparency * 100))
			hash = fold(hash, if descendant.Anchored then 1 else 0)
		elseif descendant:IsA("SurfaceAppearance") then
			-- The one thing the tint step writes, so a retinted prop reads as
			-- edited rather than as the system's own work.
			hash = foldColor(hash, descendant.Color)
		end
	end

	return hash
end

return PlacementStamp
