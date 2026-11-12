--[[
	TypeDataRope  -  Rope type definition (verlet-chain rope; runtime in
	Modules/Part/Rope/). Merged into TypeData.Types at the bottom of
	TypeData.luau (TypeDataLightning pattern).
]]

local Rope = {}

Rope.RopeProperties = {
	-- Graphs over normalized life. Thickness shares its name with Lightning so
	-- the Appearance clipboard group crosses the two types.
	Color        = { type = "ColorSequence", default = ColorSequence.new(Color3.fromRGB(255, 255, 255)) },
	Brightness   = { type = "NumberSequence", default = NumberSequence.new(1) },
	Transparency = { type = "NumberSequence", default = NumberSequence.new(0) },
	Thickness    = { type = "NumberSequence", default = NumberSequence.new(0.15) },
	Timescale    = { type = "NumberSequence", default = NumberSequence.new(1) },

	-- Spawning
	Lifetime     = { type = "NumberRange", default = NumberRange.new(2) },
	Rate         = { type = "number",  default = 1 },
	Enabled      = { type = "boolean", default = false },
	-- SegmentCount shares its name with Lightning (clipboard cross-type).
	SegmentCount = { type = "NumberRange", default = NumberRange.new(12), nonNegative = true },
	-- BothEnds pins the far end to the Target ObjectValue; StartOnly hangs free;
	-- Launch throws the far end ballistically — aimed at the Target (arrive +
	-- attach, grappling hook) when set, else blind along EmissionDirection.
	PinMode      = { type = "string", default = "BothEnds" },
	-- Total rope length in studs; <= 0 = auto (anchor distance × Slack).
	RopeLength   = { type = "NumberRange", default = NumberRange.new(0) },
	Slack        = { type = "number", default = 1.2, nonNegative = true },

	-- Anchor motion: Speed/Acceleration/Drag + Displacement graphs + Turbulence
	-- drive the Start or End anchor (whips animate the START; the wave and tip
	-- crack emerge). Speed moves the anchor along EmissionDirection.
	MotionTarget        = { type = "string", default = "Start" },
	Speed               = { type = "NumberSequence", default = NumberSequence.new(0) },
	Acceleration        = { type = "Vector3", default = Vector3.new(0, 0, 0) },
	Drag                = { type = "number", default = 0 },
	PosOffsetX          = { type = "NumberSequence", default = NumberSequence.new(0) },
	PosOffsetY          = { type = "NumberSequence", default = NumberSequence.new(0) },
	PosOffsetZ          = { type = "NumberSequence", default = NumberSequence.new(0) },
	PosOffsetXLinkedTo  = { type = "string", default = "" },
	PosOffsetYLinkedTo  = { type = "string", default = "" },
	PosOffsetZLinkedTo  = { type = "string", default = "" },
	Turbulence          = { type = "NumberSequence", default = NumberSequence.new(0) },
	TurbulenceFrequency = { type = "number", default = 1 },
	-- Local and RigidLocal are identical for Rope (both = source-rotation frame).
	DisplacementMode    = { type = "string", default = "Global" },

	-- Spawn (mesh/Lightning parity): Pos offsets the SpawnTarget anchor; RotXYZ
	-- rotates the aim + Local offset frame (rings/fans/crowns); evens + rolling
	-- cycles via the shared EvenCycle machinery. Direction seeds StartOnly poses
	-- + aims Launch; SpreadAngle cones both.
	SpawnTarget  = { type = "string", default = "Start" },
	PosX         = { type = "NumberRange", default = NumberRange.new(0) },
	PosY         = { type = "NumberRange", default = NumberRange.new(0) },
	PosZ         = { type = "NumberRange", default = NumberRange.new(0) },
	PosXEven     = { type = "boolean", default = false },
	PosYEven     = { type = "boolean", default = false },
	PosZEven     = { type = "boolean", default = false },
	PositionEvenCycle = { type = "NumberRange", default = NumberRange.new(0) },
	PosXLinkedTo = { type = "string", default = "" },
	PosYLinkedTo = { type = "string", default = "" },
	PosZLinkedTo = { type = "string", default = "" },
	PosMode      = { type = "string", default = "Local" },
	RotX         = { type = "NumberRange", default = NumberRange.new(0) },
	RotY         = { type = "NumberRange", default = NumberRange.new(0) },
	RotZ         = { type = "NumberRange", default = NumberRange.new(0) },
	RotXEven     = { type = "boolean", default = false },
	RotYEven     = { type = "boolean", default = false },
	RotZEven     = { type = "boolean", default = false },
	RotationEvenCycle = { type = "NumberRange", default = NumberRange.new(0) },
	RotXLinkedTo = { type = "string", default = "" },
	RotYLinkedTo = { type = "string", default = "" },
	RotZLinkedTo = { type = "string", default = "" },
	RotOrder     = { type = "string", default = "Global" },
	EmissionDirection = { type = "enum", enumType = "NormalId", default = Enum.NormalId.Front },
	SpreadAngle       = { type = "Vector2", default = Vector2.new(0, 0) },

	-- Lifecycle: GrowIn pays the rope out over the first fraction of life;
	-- DeathMode ends it over the last DeathWindow fraction.
	GrowIn      = { type = "number", default = 0, nonNegative = true },
	DeathMode   = { type = "string", default = "None" },
	DeathWindow = { type = "number", default = 0.2, nonNegative = true },

	-- Bend stiffness 0..1: floppy chain → stiff cable/tentacle.
	BendStiffness = { type = "number", default = 0, nonNegative = true },
	-- Width along the ARC (0 = root, 1 = tip) multiplying Thickness — whip taper.
	ThicknessProfile = { type = "NumberSequence", default = NumberSequence.new(1) },
	-- Speed's own direction (decoupled from the spawn aim), same rotated frame.
	MotionDirection = { type = "enum", enumType = "NormalId", default = Enum.NormalId.Front },

	-- Launch mode: ballistic end-anchor velocity (rope Gravity bends the arc).
	LaunchSpeed       = { type = "NumberRange", default = NumberRange.new(40), nonNegative = true },

	-- Chain physics (tuned, not physical).
	Stiffness     = { type = "number", default = 4, nonNegative = true },
	Damping       = { type = "number", default = 0.03, nonNegative = true },
	Gravity       = { type = "Vector3", default = Vector3.new(0, -40, 0) },
	WindAmplitude = { type = "NumberRange", default = NumberRange.new(0) },
	WindFrequency = { type = "number", default = 2 },

	-- Advanced
	TotalKeyFrames = { type = "number",  default = 100 },
	PartLife       = { type = "number",  default = 0, nonNegative = true },
	Pool           = { type = "boolean", default = false },
}

Rope.Types = {
	Rope = {
		-- IsRope stamped by Actions before Transform; config-child requirement
		-- keeps this disjoint from Part's classCheck during the transform window.
		classCheck = function(item)
			return item:IsA("BasePart") and item:GetAttribute("IsRope") == true
				and item:FindFirstChild("PartIcleProperties") ~= nil
		end,
		pDataType = "Rope",
		uiSection = "Ropes",
		properties = Rope.RopeProperties,

		resize = {
			scaleGraphs = { "Thickness", "PosOffsetX", "PosOffsetY", "PosOffsetZ", "Turbulence", "Speed" },
			scaleRanges = { "RopeLength", "WindAmplitude", "LaunchSpeed", "PosX", "PosY", "PosZ" },
			scaleVectors = { "Gravity", "Acceleration" },
			-- ThicknessProfile is a multiplier over arc — scale-invariant.
		},
		retime = {
			multiplyNumbers = { "Rate", "WindFrequency", "TurbulenceFrequency", "Drag" },
			multiplyRanges = { "LaunchSpeed" },
			multiplyGraphs = { "Speed" },
			squareVectors = { "Gravity", "Acceleration" },
			divideRanges = { "Lifetime" },
		},
		clipboard = {
			{name = "Emission", props = {"Rate", "Lifetime", "GrowIn", "DeathMode", "DeathWindow", "PartLife", "Timescale", "EmitCount", "EmitDelay", "EmitDuration"}},
			{name = "Spawn", props = {"PinMode", "SpawnTarget", "PosMode", "PosX", "PosY", "PosZ", "PosXEven", "PosYEven", "PosZEven", "PositionEvenCycle", "RotOrder", "RotX", "RotY", "RotZ", "RotXEven", "RotYEven", "RotZEven", "RotationEvenCycle"}},
			{name = "Rope", props = {"SegmentCount", "RopeLength", "Slack", "Stiffness", "BendStiffness", "Damping", "Gravity", "WindAmplitude", "WindFrequency"}},
			{name = "Motion", props = {"MotionTarget", "EmissionDirection", "SpreadAngle", "MotionDirection", "LaunchSpeed", "Speed", "Acceleration", "Drag", "DisplacementMode", "PosOffsetX", "PosOffsetY", "PosOffsetZ", "Turbulence", "TurbulenceFrequency"}},
			{name = "Appearance", props = {"Material", "Color", "Brightness", "Transparency", "Thickness", "ThicknessProfile"}},
			{name = "Advanced", props = {"TotalKeyFrames", "Pool"}},
			{name = "Events", props = {"OnEmit", "OnDeath", "OnDestruction"}},
		},
	},
}

return Rope
