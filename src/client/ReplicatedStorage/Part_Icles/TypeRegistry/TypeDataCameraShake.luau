--[[
	TypeDataCameraShake  -  CameraShake type definition (positional trauma-style
	camera shake; runtime in Modules/Part/CameraShake/). Merged into TypeData.Types
	at the bottom of TypeData.luau (TypeDataLightning pattern).

	ShakeAmplitude / ShakeRotAmplitude are the authored envelopes over life  -  no
	amp-squared perceptual remap is applied, the curve IS what plays. math.noise
	spans roughly ±0.5, so effective peak offset ≈ half the amplitude value.
]]

local CameraShake = {}

CameraShake.CameraShakeProperties = {
	-- Envelopes over normalized life.
	ShakeAmplitude    = { type = "NumberSequence", default = NumberSequence.new(1) },
	ShakeRotAmplitude = { type = "NumberSequence", default = NumberSequence.new(0.6) },
	Timescale         = { type = "NumberSequence", default = NumberSequence.new(1) },

	-- Noise frequency over life (direction changes per second-ish); the runtime integrates it
	-- into a phase so a changing frequency never jumps the noise.
	ShakeFrequency = { type = "NumberSequence", default = NumberSequence.new(10) },
	-- Linear distance attenuation in studs; 0 = global (no falloff).
	ShakeFalloff   = { type = "number", default = 0, nonNegative = true },

	Lifetime       = { type = "NumberRange", default = NumberRange.new(0.5) },
	Rate           = { type = "number",  default = 10 },
	Enabled        = { type = "boolean", default = false },
	TotalKeyFrames = { type = "number",  default = 100 },
}

CameraShake.Types = {
	CameraShake = {
		-- IsCameraShake stamped by Actions.TransformSelectionAsCameraShake BEFORE
		-- Transform; config-child requirement keeps this disjoint from Part's
		-- classCheck exclusion during the transform window.
		classCheck = function(item)
			return item:IsA("BasePart") and item:GetAttribute("IsCameraShake") == true
				and item:FindFirstChild("PartIcleProperties") ~= nil
		end,
		pDataType = "CameraShake",
		uiSection = "Camera Shakes",
		properties = CameraShake.CameraShakeProperties,

		resize = {
			scaleGraphs = { "ShakeAmplitude" },
			scaleNumbers = { "ShakeFalloff" },
			-- ShakeRotAmplitude excluded: degrees are scale-invariant.
		},
		retime = {
			multiplyNumbers = { "Rate" },
			multiplyGraphs = { "ShakeFrequency" },
			divideRanges = { "Lifetime" },
		},
		clipboard = {
			{name = "Emission", props = {"Rate", "Lifetime", "Timescale", "EmitCount", "EmitDelay", "EmitDuration"}},
			{name = "Shake", props = {"ShakeAmplitude", "ShakeRotAmplitude", "ShakeFrequency", "ShakeFalloff"}},
			{name = "Advanced", props = {"TotalKeyFrames"}},
			{name = "Events", props = {"OnEmit", "OnDeath", "OnDestruction"}},
		},
	},
}

return CameraShake
