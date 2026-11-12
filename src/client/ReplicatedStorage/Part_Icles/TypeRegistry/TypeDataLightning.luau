-- TypeDataLightning  -  Property table + Types entry for the Lightning type
-- (procedural part-based lightning bolts). Shape + schema identical to TypeData  -
-- see that file's header for the property-entry format.
--
-- Lightning is a transformed BasePart discriminated from Part by the IsLightning
-- item attribute. Part's classCheck excludes it (TypeData.luau) so the two
-- predicates stay disjoint under getTypeFor's unordered iteration.

local Lightning = {}

Lightning.LightningProperties = {
	-- Graph properties (sampled over bolt lifetime)
	Color          = { type = "ColorSequence",  default = ColorSequence.new(Color3.new(1, 1, 1)) },
	-- SPATIAL gradient along the bolt arc (source → tip); multiplies with the
	-- temporal Color graph. Forks inherit the color at their branch arc position.
	Gradient       = { type = "ColorSequence",  default = ColorSequence.new(Color3.new(1, 1, 1)) },
	Brightness     = { type = "NumberSequence", default = NumberSequence.new(1) },
	Transparency   = { type = "NumberSequence", default = NumberSequence.new(0) },
	-- Segment cross-section in studs; drives clone Size X/Y each visual step
	-- (writeVisuals floors the part width at 0.05, so negatives are safe).
	Thickness      = { type = "NumberSequence", default = NumberSequence.new(0.15) },
	-- Taper: width along the ARC (0 = source, 1 = tip) multiplying Thickness. Forks continue
	-- their parent's profile from the branch point to the tip value over their own length.
	ThicknessProfile = { type = "NumberSequence", default = NumberSequence.new(1) },
	-- Timescale graph: see TypeData.PartProperties for full semantics.
	Timescale      = { type = "NumberSequence", default = NumberSequence.new(1) },
	-- Impact disk at the strike point (Lightning/ImpactDisk): normal to the surface, shown only
	-- while the strike ray hits something, tinted by the bolt tip. DiskMode "Follow" scales the
	-- disk with the bolt's thickness and fades it with the bolt's transparency; "Manual" drives
	-- it from the DiskSize / DiskTransparency / DiskBrightness graphs.
	DiskEnabled      = { type = "boolean",        default = false },
	DiskMode         = { type = "string",         default = "Follow" },
	DiskSize         = { type = "NumberSequence", default = NumberSequence.new(2) },
	DiskTransparency = { type = "NumberSequence", default = NumberSequence.new(0) },
	DiskBrightness   = { type = "NumberSequence", default = NumberSequence.new(1) },
	DiskTexture      = { type = "string",         default = "" },
	DiskOffset       = { type = "number",         default = 0.05 },

	-- Spawning
	Rate           = { type = "number",      default = 10 },
	Lifetime       = { type = "NumberRange", default = NumberRange.new(1) },
	Enabled        = { type = "boolean",     default = false },
	-- "Directional" = bolt shoots along EmissionDirection ± SpreadAngle for Length studs.
	-- "Point" = bolt arcs from the source to the Target ObjectValue child instance.
	-- "Seek" = bolt snaps to a RANDOM nearby surface within SeekRadius (Kutsuna
	-- arc-grounding); fires OnHit per strike acquisition.
	TargetMode     = { type = "string",      default = "Directional" },
	SeekRadius     = { type = "NumberRange", default = NumberRange.new(30), nonNegative = true },
	-- true = re-scan every jitter roll (strike point flickers at JitterRate).
	SeekRetarget   = { type = "boolean",     default = false },
	-- 0 = pure random among found surfaces; 1 = strongly prefer the nearest.
	SeekBias       = { type = "number",      default = 0, nonNegative = true },
	-- Strike point GLIDES toward each new target at this speed (studs/s);
	-- 0 = instant snap. Continuous destructive-zap drag across surfaces.
	RetargetSpeed  = { type = "number",      default = 0, nonNegative = true },
	Length         = { type = "NumberRange", default = NumberRange.new(20) },
	-- Tip-extension speed in studs/s, rolled per bolt; 0 = full bolt appears instantly.
	-- Negative reveals from the FAR end toward the source (reverse strike).
	GrowthSpeed    = { type = "NumberRange", default = NumberRange.new(0) },
	SpreadAngle    = { type = "Vector2",     default = Vector2.new(0, 0) },
	EmissionDirection = { type = "enum", enumType = "NormalId", default = Enum.NormalId.Top },

	-- Bolt shape (procedural). All NumberRanges  -  each bolt rolls its own value at
	-- emit, so multi-bolt emitters get natural variety. Engine clamps SegmentCount to
	-- 2..64 total parts (rig is sized for the range's Max).
	SegmentCount    = { type = "NumberRange", default = NumberRange.new(12) },
	-- Lateral midpoint displacement as a fraction of bolt length. Negative mirrors
	-- the Scroll-mode wave side.
	Amplitude       = { type = "NumberRange", default = NumberRange.new(0.15) },
	-- Amplitude multiplier per subdivision level (0..1); lower = smoother tips.
	AmplitudeDecay  = { type = "NumberRange", default = NumberRange.new(0.5), nonNegative = true },
	-- Shape re-roll frequency in Hz; 0 = bolt shape frozen after spawn.
	JitterRate      = { type = "NumberRange", default = NumberRange.new(15), nonNegative = true },
	ForkChance      = { type = "NumberRange", default = NumberRange.new(0), nonNegative = true },
	ForkDepth       = { type = "NumberRange", default = NumberRange.new(0), nonNegative = true },
	-- Fork length/amplitude/thickness all scale by this factor per fork generation.
	ForkLengthScale = { type = "NumberRange", default = NumberRange.new(0.4), nonNegative = true },
	-- Parabolic droop of the base path, fraction of bolt length. Negative arches
	-- upward. Droop direction follows DisplacementMode (Global = world down,
	-- Local / RigidLocal = origin-frame down).
	Sag             = { type = "NumberRange", default = NumberRange.new(0) },
	-- Sag profile, rolled per bolt: 1 = parabola (higher = pointier), 0.5 = true
	-- circular arc (sagitta = sag depth; past a semicircle it wraps as a horseshoe),
	-- 0 = square trough; values between blend.
	SagShape        = { type = "NumberRange", default = NumberRange.new(1), nonNegative = true },
	-- Jitter = random re-rolls only; Scroll = traveling Perlin wave (JitterRate then
	-- re-rolls forks only); JitterScroll = zigzag base + wave layered.
	ShapeMode       = { type = "string", default = "Jitter" },
	-- Wave cycles passing a point per second (Beam TextureSpeed analogy); negative reverses.
	ScrollSpeed     = { type = "NumberRange", default = NumberRange.new(1) },
	-- How many Perlin undulations fit along the bolt.
	Waves           = { type = "NumberRange", default = NumberRange.new(3), nonNegative = true },

	-- Spawn Shape (Part-emitter semantics, shared keys): bolt START scatters within
	-- the volume; Directional mode fires along the shape's outward normal (ShapeInOut
	-- flips inward). ShapePart ObjectValue overrides the sampled volume.
	UseShape        = { type = "boolean", default = false },
	Shape           = { type = "enum", enumType = "ParticleEmitterShape", default = Enum.ParticleEmitterShape.Box },
	ShapeInOut      = { type = "enum", enumType = "ParticleEmitterShapeInOut", default = Enum.ParticleEmitterShapeInOut.Outward },
	ShapePartial    = { type = "number", default = 0 },
	-- "Emitter" = bolts keep the authored Direction ± Spread (shape scatters starts
	-- only); "Radial" = bolts fire along the shape's outward normal (nova). Box/
	-- Cylinder/Disc normals are mostly horizontal, so Radial-by-default read as
	-- "bolts laid flat".
	ShapeDirection  = { type = "string", default = "Emitter" },

	-- Spawn offsets/rotation (Part-emitter keys: even-distribution dots + rolling
	-- cycles + axis links come from the shared machinery). Pos offsets the bolt
	-- ORIGIN in the origin frame (PosMode Global = world axes); Rot rotates the
	-- Directional launch frame (RotOrder composes the axes).
	PosX              = { type = "NumberRange", default = NumberRange.new(0) },
	PosY              = { type = "NumberRange", default = NumberRange.new(0) },
	PosZ              = { type = "NumberRange", default = NumberRange.new(0) },
	PosXEven          = { type = "boolean", default = false },
	PosYEven          = { type = "boolean", default = false },
	PosZEven          = { type = "boolean", default = false },
	PositionEvenCycle = { type = "NumberRange", default = NumberRange.new(0) },
	PosMode           = { type = "string", default = "Local" },
	RotX              = { type = "NumberRange", default = NumberRange.new(0) },
	RotY              = { type = "NumberRange", default = NumberRange.new(0) },
	RotZ              = { type = "NumberRange", default = NumberRange.new(0) },
	RotXEven          = { type = "boolean", default = false },
	RotYEven          = { type = "boolean", default = false },
	RotZEven          = { type = "boolean", default = false },
	RotationEvenCycle = { type = "NumberRange", default = NumberRange.new(0) },
	RotOrder          = { type = "string", default = "Global" },
	-- RigidLocal (default) = direction ignores per-bolt RotXYZ (Rot positions only  -
	-- rings keep their facing); Local = direction rotates with RotXYZ (radial crown);
	-- Global = world-axis direction.
	DirMode           = { type = "string", default = "RigidLocal" },
	-- Origin motion (Part Movement keys): Speed moves the origin along the launch
	-- direction; PosOffset graphs displace it over life in the DisplacementMode frame.
	Speed             = { type = "NumberSequence", default = NumberSequence.new(0) },
	Acceleration      = { type = "Vector3", default = Vector3.new(0, 0, 0) },
	Drag              = { type = "number", default = 0 },
	PosOffsetX        = { type = "NumberSequence", default = NumberSequence.new(0) },
	PosOffsetY        = { type = "NumberSequence", default = NumberSequence.new(0) },
	PosOffsetZ        = { type = "NumberSequence", default = NumberSequence.new(0) },
	DisplacementMode  = { type = "string", default = "Global" },
	-- Perlin wander on the bolt origin (Turbulence.luau).
	Turbulence          = { type = "NumberSequence", default = NumberSequence.new(0) },
	TurbulenceFrequency = { type = "number", default = 1 },

	-- Axis-link metadata (QOL snapshot + Randomizer read these).
	PosXLinkedTo      = { type = "string", default = "" },
	PosYLinkedTo      = { type = "string", default = "" },
	PosZLinkedTo      = { type = "string", default = "" },
	RotXLinkedTo      = { type = "string", default = "" },
	RotYLinkedTo      = { type = "string", default = "" },
	RotZLinkedTo      = { type = "string", default = "" },
	PosOffsetXLinkedTo = { type = "string", default = "" },
	PosOffsetYLinkedTo = { type = "string", default = "" },
	PosOffsetZLinkedTo = { type = "string", default = "" },

	-- Advanced
	TotalKeyFrames = { type = "number",  default = 100 },
	PartLife       = { type = "number",  default = 0, nonNegative = true },
	Pool           = { type = "boolean", default = false },
}

Lightning.Types = {
	Lightning = {
		classCheck = function(item)
			return item:IsA("BasePart") and item:GetAttribute("IsLightning") == true
				and item:FindFirstChild("PartIcleProperties") ~= nil
		end,
		pDataType = "Lightning",
		uiSection = "Lightnings",
		properties = Lightning.LightningProperties,

		resize = {
			scaleGraphs = { "Thickness", "Speed", "PosOffsetX", "PosOffsetY", "PosOffsetZ", "Turbulence", "DiskSize" },
			scaleVectors = { "Acceleration" },
			scaleRanges = { "Length", "PosX", "PosY", "PosZ", "SeekRadius", "GrowthSpeed" },
			scaleNumbers = { "RetargetSpeed", "DiskOffset" },
		},
		retime = {
			multiplyNumbers = { "Rate", "Drag", "TurbulenceFrequency", "RetargetSpeed" },
			multiplyRanges = { "JitterRate", "ScrollSpeed", "GrowthSpeed" },
			multiplyGraphs = { "Speed" },
			squareVectors = { "Acceleration" },
			divideRanges = { "Lifetime" },
		},
		clipboard = {
			{name = "Emission", props = {"Rate", "Lifetime", "PartLife", "Timescale", "EmitCount", "EmitDelay", "EmitDuration"}},
			{name = "Bolt", props = {"TargetMode", "SeekRadius", "SeekRetarget", "SeekBias", "RetargetSpeed", "EmissionDirection", "SpreadAngle", "Length", "GrowthSpeed", "ShapeMode", "SegmentCount", "Amplitude", "AmplitudeDecay", "JitterRate", "ScrollSpeed", "Waves", "Sag", "SagShape", "ForkChance", "ForkDepth", "ForkLengthScale"}},
			{name = "Spawn", props = {"DirMode", "RotOrder", "RotX", "RotY", "RotZ", "RotXEven", "RotYEven", "RotZEven", "RotationEvenCycle", "PosMode", "PosX", "PosY", "PosZ", "PosXEven", "PosYEven", "PosZEven", "PositionEvenCycle", "UseShape", "Shape", "ShapeDirection", "ShapeInOut", "ShapePartial"}},
			{name = "Motion", props = {"Speed", "Acceleration", "Drag", "DisplacementMode", "PosOffsetX", "PosOffsetY", "PosOffsetZ", "Turbulence", "TurbulenceFrequency"}},
			{name = "Appearance", props = {"Material", "Color", "Gradient", "Brightness", "Transparency", "Thickness", "ThicknessProfile"}},
			{name = "Impact", props = {"DiskEnabled", "DiskMode", "DiskSize", "DiskTransparency", "DiskBrightness", "DiskTexture", "DiskOffset"}},
			{name = "Advanced", props = {"TotalKeyFrames", "Pool"}},
			{name = "Events", props = {"OnEmit", "OnDeath", "OnDestruction"}},
		},
	},
}

return Lightning
