--[[
	GetDataRig  -  config readers for the rig-based procedural types (Rocks,
	Rope). Split from GetData.luau (500-line cap). All props FLAT on data  -
	never inside data.ParticleData (Engine replay indexes
	ParticleData.Acceleration unguarded; a partial table would crash the step).
]]

local GetDataRig = {}

-- Coerce legacy scalar attributes so pre-range saves keep working unedited.
local function asRange(v, default)
	if typeof(v) == "NumberRange" then return v end
	if typeof(v) == "number" then return NumberRange.new(v) end
	return default
end

function GetDataRig.readRocks(data, item, config, safeEnum)
	data.PartLife = config:GetAttribute("PartLife") or 0
	data.Lifetime = config:GetAttribute("Lifetime") or NumberRange.new(3)
	data.Rate = config:GetAttribute("Rate") or 2

	data.BurstMode = config:GetAttribute("BurstMode") or "Directional"
	data.EmissionDirection = safeEnum(Enum.NormalId, config:GetAttribute("EmissionDirection"), Enum.NormalId.Top)
	data.SpreadAngle = config:GetAttribute("SpreadAngle") or Vector2.new(25, 25)
	data.Speed = config:GetAttribute("Speed")
	data.ChunkCount = asRange(config:GetAttribute("ChunkCount"), NumberRange.new(6, 10))
	data.ChunkScale = asRange(config:GetAttribute("ChunkScale"), NumberRange.new(0.5, 1.5))

	data.PosX = asRange(config:GetAttribute("PosX"), NumberRange.new(0))
	data.PosY = asRange(config:GetAttribute("PosY"), NumberRange.new(0))
	data.PosZ = asRange(config:GetAttribute("PosZ"), NumberRange.new(0))
	data.PosMode = config:GetAttribute("PosMode") or "Local"
	data.PosXEven = config:GetAttribute("PosXEven") == true
	data.PosYEven = config:GetAttribute("PosYEven") == true
	data.PosZEven = config:GetAttribute("PosZEven") == true

	data.Gravity = asRange(config:GetAttribute("Gravity"), NumberRange.new(196.2))
	data.Bounciness = asRange(config:GetAttribute("Bounciness"), NumberRange.new(0.3, 0.5))
	data.Friction = asRange(config:GetAttribute("Friction"), NumberRange.new(0.3))
	data.TumbleSpeed = asRange(config:GetAttribute("TumbleSpeed"), NumberRange.new(90, 360))
	data.SinkOut = config:GetAttribute("SinkOut") ~= false
	data.HitPerChunk = config:GetAttribute("HitPerChunk") == true
	data.InheritFloor = config:GetAttribute("InheritFloor") == true

	data.Scale = config:GetAttribute("Scale")
	data.Color = config:GetAttribute("Color")
	data.Brightness = config:GetAttribute("Brightness")
	data.Transparency = config:GetAttribute("Transparency")
	data.Timescale = config:GetAttribute("Timescale")

	data.Pool = config:GetAttribute("Pool")
	return data
end

function GetDataRig.readRope(data, item, config, safeEnum)
	data.PartLife = config:GetAttribute("PartLife") or 0
	data.Lifetime = config:GetAttribute("Lifetime") or NumberRange.new(2)
	data.Rate = config:GetAttribute("Rate") or 1

	data.SegmentCount = asRange(config:GetAttribute("SegmentCount"), NumberRange.new(12))
	data.PinMode = config:GetAttribute("PinMode") or "BothEnds"
	local targetValue = item:FindFirstChild("Target")
	data.Target = (targetValue and targetValue:IsA("ObjectValue")) and targetValue.Value or nil
	data.RopeLength = asRange(config:GetAttribute("RopeLength"), NumberRange.new(0))
	data.Slack = config:GetAttribute("Slack") or 1.2

	data.Stiffness = config:GetAttribute("Stiffness") or 4
	data.Damping = config:GetAttribute("Damping") or 0.03
	data.Gravity = config:GetAttribute("Gravity") or Vector3.new(0, -40, 0)
	data.WindAmplitude = asRange(config:GetAttribute("WindAmplitude"), NumberRange.new(0))
	data.WindFrequency = config:GetAttribute("WindFrequency") or 2

	data.SpawnTarget = config:GetAttribute("SpawnTarget") or "Start"
	data.PosX = asRange(config:GetAttribute("PosX"), NumberRange.new(0))
	data.PosY = asRange(config:GetAttribute("PosY"), NumberRange.new(0))
	data.PosZ = asRange(config:GetAttribute("PosZ"), NumberRange.new(0))
	data.PosXEven = config:GetAttribute("PosXEven") == true
	data.PosYEven = config:GetAttribute("PosYEven") == true
	data.PosZEven = config:GetAttribute("PosZEven") == true
	data.PosMode = config:GetAttribute("PosMode") or "Local"
	data.RotX = asRange(config:GetAttribute("RotX"), NumberRange.new(0))
	data.RotY = asRange(config:GetAttribute("RotY"), NumberRange.new(0))
	data.RotZ = asRange(config:GetAttribute("RotZ"), NumberRange.new(0))
	data.RotXEven = config:GetAttribute("RotXEven") == true
	data.RotYEven = config:GetAttribute("RotYEven") == true
	data.RotZEven = config:GetAttribute("RotZEven") == true
	data.RotOrder = config:GetAttribute("RotOrder") or "Global"

	data.GrowIn = config:GetAttribute("GrowIn") or 0
	data.DeathMode = config:GetAttribute("DeathMode") or "None"
	data.DeathWindow = config:GetAttribute("DeathWindow") or 0.2
	data.BendStiffness = config:GetAttribute("BendStiffness") or 0
	data.ThicknessProfile = config:GetAttribute("ThicknessProfile")
	data.MotionDirection = safeEnum(Enum.NormalId, config:GetAttribute("MotionDirection"), Enum.NormalId.Front)

	data.MotionTarget = config:GetAttribute("MotionTarget") or "Start"
	data.Speed = config:GetAttribute("Speed")
	data.Acceleration = config:GetAttribute("Acceleration") or Vector3.new(0, 0, 0)
	data.Drag = config:GetAttribute("Drag") or 0
	data.PosOffsetX = config:GetAttribute("PosOffsetX")
	data.PosOffsetY = config:GetAttribute("PosOffsetY")
	data.PosOffsetZ = config:GetAttribute("PosOffsetZ")
	data.Turbulence = config:GetAttribute("Turbulence")
	data.TurbulenceFrequency = config:GetAttribute("TurbulenceFrequency") or 1
	data.DisplacementMode = config:GetAttribute("DisplacementMode") or "Global"

	data.LaunchSpeed = asRange(config:GetAttribute("LaunchSpeed"), NumberRange.new(40))
	data.EmissionDirection = safeEnum(Enum.NormalId, config:GetAttribute("EmissionDirection"), Enum.NormalId.Front)
	data.SpreadAngle = config:GetAttribute("SpreadAngle") or Vector2.new(0, 0)

	data.Color = config:GetAttribute("Color")
	data.Brightness = config:GetAttribute("Brightness")
	data.Transparency = config:GetAttribute("Transparency")
	data.Thickness = config:GetAttribute("Thickness")
	data.Timescale = config:GetAttribute("Timescale")

	data.Pool = config:GetAttribute("Pool")
	return data
end

return GetDataRig
