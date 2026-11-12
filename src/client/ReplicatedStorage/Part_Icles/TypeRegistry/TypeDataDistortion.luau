--[[
	TypeDataDistortion  -  Distortion type definition (screen-space glass
	distortion canvas; runtime in Modules/Part/Distortion/). Merged into
	TypeData.Types at the bottom of TypeData.luau (TypeDataLightning pattern).

	A Distortion item is a transformed BasePart discriminated by the
	IsDistortion attribute. Every active effect sums its height field into ONE
	shared camera-locked glass plane (Distortion/Canvas.luau)  -  overlapping
	glass planes cull each other, so per-effect planes cannot exist.
]]

local Distortion = {}

Distortion.DistortionProperties = {
	-- Field selection + shape. All screen-space quantities live in plane UV
	-- units (the canvas is 8x5 plane-studs); they are world-scale-invariant.
	FieldKind    = { type = "string", default = "Ripple" },
	-- Vertex displacement envelope over life (slope-normalized at write time
	-- so perceived strength is FOV- and wavelength-invariant).
	Amplitude    = { type = "NumberSequence", default = NumberSequence.new(0.5), nonNegative = true },
	Wavelength   = { type = "number", default = 1.5, nonNegative = true },
	-- SIGNED: negative = inward ripple / reversed wave / reversed scroll.
	Speed        = { type = "number", default = 3 },
	-- Degrees; Wave travel + Noise scroll direction.
	Direction    = { type = "number", default = 0 },
	NoiseScale   = { type = "number", default = 2, nonNegative = true },
	-- Bulge/Pinch dome radius (UV studs).
	LensRadius   = { type = "number", default = 1.5, nonNegative = true },

	-- Epicenter: WorldPoint = the item's live position (or moving nested clone,
	-- or Events AtPosition override) projected to the screen each frame;
	-- ScreenCenter = fixed center.
	EpicenterMode = { type = "string", default = "WorldPoint" },
	-- Camera-to-epicenter linear attenuation in world studs; 0 = global
	-- (ShakeFalloff semantics).
	Falloff      = { type = "number", default = 0, nonNegative = true },

	-- Plane glass Transparency over life: 1 = invisible, ~0.5-0.75 = peak
	-- refraction, below ~0.5 = dark semi-mirror, above 1 = overdrive request
	-- (engine-quirk zone, effective ~4-10). MIN-composed across active effects
	-- (strongest glass wins). Default fades out so the plane never pops.
	Transparency = { type = "NumberSequence", default = NumberSequence.new(0.3, 1), nonNegative = true },
	-- Software gain on this item's height contribution (always safe).
	Strength     = { type = "number", default = 1, nonNegative = true },
	-- Transparency>1 overdrive request (effective 4..10; 0 = off). Plane-global,
	-- composed by MAX across active effects; vetoed unless EVERY active effect
	-- opted in via AllowOverdrive (conservative wins).
	Amplify        = { type = "number", default = 0, nonNegative = true },
	AllowOverdrive = { type = "boolean", default = false },
	-- Mesh grid width (verts across; height keeps the 24:14 aspect). The plane
	-- is shared: the HIGHEST active request wins, and it never downgrades until
	-- teardown. Cost scales quadratically  -  OptCalc reflects it.
	Resolution     = { type = "number", default = 24, nonNegative = true },

	-- Standard timing family. Timescale supports signed reverse (negative
	-- segments run the field animation backward).
	Timescale      = { type = "NumberSequence", default = NumberSequence.new(1) },
	Lifetime       = { type = "NumberRange", default = NumberRange.new(0.5) },
	Rate           = { type = "number", default = 10 },
	Enabled        = { type = "boolean", default = false },
	TotalKeyFrames = { type = "number", default = 100 },
}

Distortion.Types = {
	Distortion = {
		-- IsDistortion stamped by Actions.TransformSelectionAsDistortion BEFORE
		-- Transform; config-child requirement keeps this disjoint from Part's
		-- classCheck under getTypeFor's unordered iteration.
		classCheck = function(item)
			return item:IsA("BasePart") and item:GetAttribute("IsDistortion") == true
				and item:FindFirstChild("PartIcleProperties") ~= nil
		end,
		pDataType = "Distortion",
		uiSection = "Distortions",
		properties = Distortion.DistortionProperties,

		-- Screen-space props (Amplitude/Wavelength/LensRadius) are world-scale-
		-- invariant; only the world-distance Falloff scales.
		resize = {
			scaleNumbers = { "Falloff" },
		},
		retime = {
			multiplyNumbers = { "Rate", "Speed" },
			divideRanges = { "Lifetime" },
		},
		clipboard = {
			{name = "Emission", props = {"Rate", "Lifetime", "Timescale", "EmitCount", "EmitDelay", "EmitDuration"}},
			{name = "Field", props = {"FieldKind", "Amplitude", "Wavelength", "Speed", "Direction", "NoiseScale", "LensRadius"}},
			{name = "Screen", props = {"EpicenterMode", "Falloff", "Strength", "Transparency", "Amplify", "AllowOverdrive", "Resolution"}},
			{name = "Advanced", props = {"TotalKeyFrames"}},
			{name = "Events", props = {"OnEmit", "OnDeath", "OnDestruction"}},
		},
	},
}

return Distortion
