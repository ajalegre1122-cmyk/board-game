--[[
	TypeDataRocks  -  Rocks type definition (debris burst with ground-collision
	physics; runtime in Modules/Part/Rocks/). Merged into TypeData.Types at the
	bottom of TypeData.luau (TypeDataLightning pattern).
]]

local Rocks = {}

Rocks.RocksProperties = {
	-- Graphs over normalized life.
	Scale        = { type = "NumberSequence", default = NumberSequence.new(1), nonNegative = true },
	Brightness   = { type = "NumberSequence", default = NumberSequence.new(1) },
	Transparency = { type = "NumberSequence", default = NumberSequence.new(0) },
	Timescale    = { type = "NumberSequence", default = NumberSequence.new(1) },
	Color        = { type = "ColorSequence", default = ColorSequence.new(Color3.fromRGB(255, 255, 255)) },
	-- Launch speed sampled ONCE per chunk at spawn (seed envelope = per-chunk variation).
	Speed        = { type = "NumberSequence", default = NumberSequence.new(30) },

	-- Spawning
	Lifetime   = { type = "NumberRange", default = NumberRange.new(3) },
	Rate       = { type = "number",  default = 2 },
	Enabled    = { type = "boolean", default = false },
	BurstMode  = { type = "string",  default = "Directional" },
	SpreadAngle = { type = "Vector2", default = Vector2.new(25, 25) },
	ChunkCount = { type = "NumberRange", default = NumberRange.new(6, 10), nonNegative = true },
	ChunkScale = { type = "NumberRange", default = NumberRange.new(0.5, 1.5), nonNegative = true },
	PosX       = { type = "NumberRange", default = NumberRange.new(0) },
	PosY       = { type = "NumberRange", default = NumberRange.new(0) },
	PosZ       = { type = "NumberRange", default = NumberRange.new(0) },
	PosMode    = { type = "string", default = "Local" },
	-- EvenDistribution: chunk i of n spreads deterministically across [Min, Max].
	PosXEven   = { type = "boolean", default = false },
	PosYEven   = { type = "boolean", default = false },
	PosZEven   = { type = "boolean", default = false },
	-- Axis-link metadata (the shared axis widget's cog writes these).
	PosXLinkedTo = { type = "string", default = "" },
	PosYLinkedTo = { type = "string", default = "" },
	PosZLinkedTo = { type = "string", default = "" },

	-- Physics (predetermined trajectories: Bounciness = restitution, Friction = tangent damping).
	-- Gravity / Bounciness / Friction are ranges rolled per chunk at emit.
	-- Negative gravity launches chunks upward; the trajectory solver handles the sign
	-- (never-landing chunks ride the anyEndless gate to end of Lifetime).
	Gravity      = { type = "NumberRange", default = NumberRange.new(196.2) },
	Bounciness   = { type = "NumberRange", default = NumberRange.new(0.3, 0.5), nonNegative = true },
	Friction     = { type = "NumberRange", default = NumberRange.new(0.3), nonNegative = true },
	TumbleSpeed  = { type = "NumberRange", default = NumberRange.new(90, 360) },
	SinkOut      = { type = "boolean", default = true },
	InheritFloor = { type = "boolean", default = false },
	-- OnHit per chunk impact instead of once per burst.
	HitPerChunk  = { type = "boolean", default = false },

	-- Enum properties
	EmissionDirection = { type = "enum", enumType = "NormalId", default = Enum.NormalId.Top },

	-- Advanced
	TotalKeyFrames = { type = "number",  default = 100 },
	PartLife       = { type = "number",  default = 0, nonNegative = true },
	Pool           = { type = "boolean", default = true },
}

Rocks.Types = {
	Rocks = {
		-- IsRocks stamped by Actions.TransformSelectionAsRocks BEFORE Transform;
		-- config-child requirement keeps this disjoint from Part's classCheck
		-- exclusion during the transform window.
		classCheck = function(item)
			return item:IsA("BasePart") and item:GetAttribute("IsRocks") == true
				and item:FindFirstChild("PartIcleProperties") ~= nil
		end,
		pDataType = "Rocks",
		uiSection = "Rocks",
		properties = Rocks.RocksProperties,

		resize = {
			scaleGraphs = { "Speed" },
			scaleRanges = { "PosX", "PosY", "PosZ", "ChunkScale", "Gravity" },
		},
		retime = {
			multiplyNumbers = { "Rate" },
			multiplyGraphs = { "Speed" },
			multiplyRanges = { "TumbleSpeed" },
			squareRanges = { "Gravity" },
			divideRanges = { "Lifetime" },
		},
		clipboard = {
			{name = "Emission", props = {"Rate", "Lifetime", "PartLife", "Timescale", "EmitCount", "EmitDelay", "EmitDuration"}},
			{name = "Spawn", props = {"BurstMode", "ChunkCount", "ChunkScale", "PosMode", "PosX", "PosY", "PosZ", "PosXEven", "PosYEven", "PosZEven"}},
			{name = "Motion", props = {"EmissionDirection", "SpreadAngle", "Speed", "Gravity", "Bounciness", "Friction", "TumbleSpeed", "SinkOut", "InheritFloor", "HitPerChunk"}},
			{name = "Appearance", props = {"Material", "Color", "Brightness", "Transparency", "Scale"}},
			{name = "Advanced", props = {"TotalKeyFrames", "Pool"}},
			{name = "Events", props = {"OnEmit", "OnDeath", "OnDestruction", "OnHit"}},
		},
	},
}

return Rocks
