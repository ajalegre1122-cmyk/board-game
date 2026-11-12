--[[
	GetDataScreen - config readers for the screen-effect types (CameraShake,
	Distortion). Both keep every prop FLAT on data - no ParticleData table
	(Engine's animate replay indexes freshData.ParticleData.Acceleration
	unguarded; a partial ParticleData table would crash the Heartbeat).
	Called only from GetData.luau.
]]

local GetDataScreen = {}

-- Read Sound props onto data (Volume / PlaybackSpeed envelopes; Lifetime 0 = clip length).
function GetDataScreen.readSound(data, config)
	data.Lifetime = config:GetAttribute("Lifetime") or NumberRange.new(0)
	data.Rate = config:GetAttribute("Rate") or 10
	data.SndVolume = config:GetAttribute("SndVolume")
	data.SndPlaybackSpeed = config:GetAttribute("SndPlaybackSpeed")
	data.SndTimescale = config:GetAttribute("SndTimescale")
	data.RollOffMin = config:GetAttribute("RollOffMin") or 10
	data.RollOffMax = config:GetAttribute("RollOffMax") or 10000
	data.Looped = config:GetAttribute("Looped") == true
	data.StartOffset = config:GetAttribute("StartOffset") or 0
	data.Local2D = config:GetAttribute("Local2D") == true
	return data
end

-- Read CameraShake props onto data. Positional trauma shake.
function GetDataScreen.readCameraShake(data, config)
	data.PartLife = 0
	data.Lifetime = config:GetAttribute("Lifetime") or NumberRange.new(0.5)
	data.Rate = config:GetAttribute("Rate") or 10
	data.ShakeAmplitude = config:GetAttribute("ShakeAmplitude")
	data.ShakeRotAmplitude = config:GetAttribute("ShakeRotAmplitude")
	-- Items saved before ShakeFrequency became a graph still hold a number.
	local frequency = config:GetAttribute("ShakeFrequency")
	if type(frequency) == "number" then frequency = NumberSequence.new(frequency) end
	data.ShakeFrequency = frequency
	data.ShakeFalloff = config:GetAttribute("ShakeFalloff") or 0
	data.Timescale = config:GetAttribute("Timescale")
	return data
end

-- Read Distortion props onto data. Screen-space glass-canvas field.
function GetDataScreen.readDistortion(data, config)
	data.PartLife = 0
	data.Lifetime = config:GetAttribute("Lifetime") or NumberRange.new(0.5)
	data.Rate = config:GetAttribute("Rate") or 10
	data.FieldKind = config:GetAttribute("FieldKind") or "Ripple"
	data.Amplitude = config:GetAttribute("Amplitude")
	data.Transparency = config:GetAttribute("Transparency")
	data.Wavelength = config:GetAttribute("Wavelength") or 1.5
	data.Speed = config:GetAttribute("Speed") or 3
	data.Direction = config:GetAttribute("Direction") or 0
	data.NoiseScale = config:GetAttribute("NoiseScale") or 2
	data.LensRadius = config:GetAttribute("LensRadius") or 1.5
	data.EpicenterMode = config:GetAttribute("EpicenterMode") or "WorldPoint"
	data.Falloff = config:GetAttribute("Falloff") or 0
	data.Strength = config:GetAttribute("Strength") or 1
	data.Amplify = config:GetAttribute("Amplify") or 0
	data.AllowOverdrive = config:GetAttribute("AllowOverdrive") == true
	data.Resolution = config:GetAttribute("Resolution") or 24
	data.Timescale = config:GetAttribute("Timescale")
	return data
end

return GetDataScreen
