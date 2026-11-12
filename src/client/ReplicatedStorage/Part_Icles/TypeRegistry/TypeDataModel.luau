--[[
	TypeDataModel  -  Model type definition, split from TypeData.luau (500-line cap).
	Merged into TypeData.ModelProperties + TypeData.Types at the bottom of TypeData.luau
	(same pattern as TypeDataLightning / TypeDataScreen).
]]

local ModelData = {}

ModelData.ModelProperties = {
	-- Graph properties (NumberSequence)
	Speed         = { type = "NumberSequence", default = NumberSequence.new(0) },
	-- Over-life per-axis position offset graphs (see PartProperties for semantics).
	PosOffsetX    = { type = "NumberSequence", default = NumberSequence.new(0) },
	PosOffsetY    = { type = "NumberSequence", default = NumberSequence.new(0) },
	PosOffsetZ    = { type = "NumberSequence", default = NumberSequence.new(0) },
	-- Perlin wander: amplitude envelope (studs) + noise frequency (Turbulence.luau).
	Turbulence          = { type = "NumberSequence", default = NumberSequence.new(0) },
	TurbulenceFrequency = { type = "number", default = 1 },
	RotSpeedX     = { type = "NumberSequence", default = NumberSequence.new(0) },
	RotSpeedY     = { type = "NumberSequence", default = NumberSequence.new(0) },
	RotSpeedZ     = { type = "NumberSequence", default = NumberSequence.new(0) },
	Scale         = { type = "NumberSequence", default = NumberSequence.new(1), nonNegative = true },
	-- Timescale: see PartProperties.
	Timescale     = { type = "NumberSequence", default = NumberSequence.new(1) },

	-- Non-graph properties
	Lifetime          = { type = "NumberRange",  default = NumberRange.new(1) },
	Rate              = { type = "number",       default = 10 },
	Drag              = { type = "number",       default = 0 },
	Acceleration      = { type = "Vector3",      default = Vector3.new(0, 0, 0) },
	SpreadAngle       = { type = "Vector2",      default = Vector2.new(0, 0) },
	RotX              = { type = "NumberRange",   default = NumberRange.new(0) },
	RotY              = { type = "NumberRange",   default = NumberRange.new(0) },
	RotZ              = { type = "NumberRange",   default = NumberRange.new(0) },
	PosX              = { type = "NumberRange",   default = NumberRange.new(0) },
	PosY              = { type = "NumberRange",   default = NumberRange.new(0) },
	PosZ              = { type = "NumberRange",   default = NumberRange.new(0) },
	PosMode           = { type = "string",       default = "Local" },
	RotMode           = { type = "string",       default = "OverLife" },
	RotOrder          = { type = "string",       default = "Global" },
	TotalKeyFrames    = { type = "number",       default = 100 },
	PartLife          = { type = "number",       default = 0, nonNegative = true },
	VelocityVectored  = { type = "boolean",      default = false },
	DirMode           = { type = "string",       default = "RigidLocal" },
	DisplacementMode  = { type = "string",       default = "Global" },
	InvertMotion      = { type = "boolean",      default = false },
	Enabled           = { type = "boolean",      default = false },
	-- When true, descendant Beam's TextureLength scales with the Model's Scale graph
	-- (preserves tile count as Beam grows). When false, TextureLength stays at authored
	-- value (tiles repeat more as Beam scales up). Default true preserves prior behavior.
	ScaleTextureLength = { type = "boolean",     default = true },
	-- Scale graph also scales nested-particle motion (Speed/Accel/PosOffset/Pos spread).
	-- Default true so a scaled Model's nested particles travel proportionally.
	ScaleMotion        = { type = "boolean",     default = true },
	-- Scale graph also scales nested-particle RotSpeed (angular → non-physical). Opt-in.
	ScaleRotation      = { type = "boolean",     default = false },

	-- Enum properties
	EmissionDirection  = { type = "enum", enumType = "NormalId", default = Enum.NormalId.Top },
	Orientation        = { type = "string", default = "None" },
	ZOffset            = { type = "number", default = 0 },

	-- Axis links: default "" means unlinked; GetData sanitizes empty/invalid values to nil.
	-- Model has Rot/Pos/RotSpeed config rows; Scale isn't axis-keyed so no link metadata.
	RotSpeedXLinkedTo    = { type = "string", default = "" },
	RotSpeedYLinkedTo    = { type = "string", default = "" },
	RotSpeedZLinkedTo    = { type = "string", default = "" },
	PosOffsetXLinkedTo   = { type = "string", default = "" },
	PosOffsetYLinkedTo   = { type = "string", default = "" },
	PosOffsetZLinkedTo   = { type = "string", default = "" },
	RotXLinkedTo         = { type = "string", default = "" },
	RotYLinkedTo         = { type = "string", default = "" },
	RotZLinkedTo         = { type = "string", default = "" },
	PosXLinkedTo         = { type = "string", default = "" },
	PosYLinkedTo         = { type = "string", default = "" },
	PosZLinkedTo         = { type = "string", default = "" },
	-- EvenDistribution: per-axis toggle. When true + EmitIndex/EmitCount in emitCtx,
	-- the axis samples a deterministic spread across [Min, Max] instead of random.
	-- EnableEmit batches use the natural EmitCount; rate-mode emits use a per-property
	-- rolling cycle (PositionEvenCycle / RotationEvenCycle) per Lifecycle.luau loopBody.
	-- Linked followers inherit the primary's spread scalar via AxisLinks.sampleRangeAxes.
	RotXEven             = { type = "boolean", default = false },
	RotYEven             = { type = "boolean", default = false },
	RotZEven             = { type = "boolean", default = false },
	PosXEven             = { type = "boolean", default = false },
	PosYEven             = { type = "boolean", default = false },
	PosZEven             = { type = "boolean", default = false },
	-- Per-property rolling-cycle length for rate-mode EvenDistribution. NumberRange
	-- sampled at every cycle wrap. Sign = direction (+ forward, - reverse). 0 or
	-- default zero-range → fall back to current cfg.Rate (forward).
	PositionEvenCycle    = { type = "NumberRange", default = NumberRange.new(0) },
	RotationEvenCycle    = { type = "NumberRange", default = NumberRange.new(0) },

	Pool                 = { type = "boolean", default = false },
}

ModelData.Types = {
	Model = {
		classCheck = function(item) return item:IsA("Model") end,
		pDataType = "Model",
		uiSection = "Models",
		properties = ModelData.ModelProperties,

		resize = {
			scaleGraphs = { "Speed", "Scale", "PosOffsetX", "PosOffsetY", "PosOffsetZ", "Turbulence" },
			scaleVectors = { "Acceleration" },
			scaleRanges = { "PosX", "PosY", "PosZ" },
		},
		retime = {
			multiplyNumbers = { "Rate", "Drag", "TurbulenceFrequency" },
			divideRanges = { "Lifetime" },
			multiplyGraphs = { "Speed" },
			rotSpeedGraphs = { "RotSpeedX", "RotSpeedY", "RotSpeedZ" },
			squareVectors = { "Acceleration" },
		},
		clipboard = {
			{name = "Emission", props = {"Rate", "Lifetime", "PartLife", "Timescale", "EmitCount", "EmitDelay", "EmitDuration"}},
			{name = "Spawn", props = {"Orientation", "PosMode", "PosX", "PosY", "PosZ", "PosXEven", "PosYEven", "PosZEven", "PositionEvenCycle", "RotOrder", "RotX", "RotY", "RotZ", "RotXEven", "RotYEven", "RotZEven", "RotationEvenCycle", "ZOffset"}},
			{name = "Motion", props = {"EmissionDirection", "SpreadAngle", "DirMode", "Speed", "Acceleration", "Drag", "InvertMotion", "DisplacementMode", "PosOffsetX", "PosOffsetY", "PosOffsetZ", "Turbulence", "TurbulenceFrequency", "RotMode", "RotSpeedX", "RotSpeedY", "RotSpeedZ"}},
			{name = "Scale", props = {"Scale", "ScaleTextureLength", "ScaleMotion", "ScaleRotation"}},
			{name = "Advanced", props = {"TotalKeyFrames", "Pool"}},
			{name = "Events", props = {"OnEmit", "OnDeath", "OnDestruction", "OnHit"}},
		},
	},
}

return ModelData
