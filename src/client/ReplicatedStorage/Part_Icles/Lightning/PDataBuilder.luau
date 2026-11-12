--[[
	Lightning/PDataBuilder  -  per-bolt pData construction shared by Emit + Animate.
	Split from Lightning/init (500-line cap). Rolls every per-bolt range, composes
	the launch frame (RotXYZ + DirMode + Spread), samples spawn Pos/Shape, and seeds
	the origin-motion state. emitCtx carries per-burst EmitIndex/EvenOffset fields
	for even-distribution sampling.
]]

local GraphMod = require(script.Parent.Parent.Graph)
local RangeMod = require(script.Parent.Parent.Range)
local AxisLinksMod = require(script.Parent.Parent.AxisLinks)
local Constants = require(script.Parent.Parent.PartConstants)
local TurbulenceMod = require(script.Parent.Parent.Turbulence)
local EndpointsMod = require(script.Parent.Endpoints)

local DirectionVectors = Constants.DirectionVectors

local PDataBuilder = {}

-- Flat-zero sequences (the writeDefaults stamp) count as "no graph" so idle
-- emitters skip the per-frame motion accumulation entirely.
function PDataBuilder.liveGraph(seq)
	if not seq then return nil end
	if GraphMod.IsStatic(seq) and GraphMod.GetStaticValue(seq, 0) == 0 then return nil end
	return seq
end

-- Static-white ColorSequence (the writeDefaults stamp) counts as "no gradient"
-- so default bolts keep the single-color fast path.
function PDataBuilder.liveColor(seq)
	if not seq or typeof(seq) ~= "ColorSequence" then return nil end
	local kp = seq.Keypoints
	if #kp <= 1 then
		local c = kp[1] and kp[1].Value
		if not c or (c.R > 0.999 and c.G > 0.999 and c.B > 0.999) then return nil end
	end
	return seq
end

-- Flat-one Taper profile (the writeDefaults stamp) counts as "no taper" so the
-- per-roll width pass is skipped.
function PDataBuilder.liveProfile(seq)
	if not seq or typeof(seq) ~= "NumberSequence" then return nil end
	if GraphMod.IsStatic(seq) and GraphMod.GetStaticValue(seq, 0) == 1 then return nil end
	return seq
end

function PDataBuilder.build(item, data, model, rig, lifeTime, emitCtx)
	-- Normalize motion graphs BEFORE seeding/aliasing so downstream flags see nil.
	data.ThicknessProfile = PDataBuilder.liveProfile(data.ThicknessProfile)
	data.Speed = PDataBuilder.liveGraph(data.Speed)
	data.PosOffsetX = PDataBuilder.liveGraph(data.PosOffsetX)
	data.PosOffsetY = PDataBuilder.liveGraph(data.PosOffsetY)
	data.PosOffsetZ = PDataBuilder.liveGraph(data.PosOffsetZ)
	data.Turbulence = TurbulenceMod.isLive(data.Turbulence)
	local seeds = {
		Brightness = GraphMod.GenerateSeed(data.Brightness),
		Transparency = GraphMod.GenerateSeed(data.Transparency),
		Thickness = GraphMod.GenerateSeed(data.Thickness),
		ThicknessProfile = GraphMod.GenerateSeed(data.ThicknessProfile),
		Timescale = GraphMod.GenerateSeed(data.Timescale),
		Speed = GraphMod.GenerateSeed(data.Speed),
		PosOffsetX = GraphMod.GenerateSeed(data.PosOffsetX),
		PosOffsetY = GraphMod.GenerateSeed(data.PosOffsetY),
		PosOffsetZ = GraphMod.GenerateSeed(data.PosOffsetZ),
		Turbulence = GraphMod.GenerateSeed(data.Turbulence),
	}
	-- Linked graph axes (PosOffset) adopt the primary's graph + seed.
	AxisLinksMod.applyGraphAxisAliases(data, seeds, data.AxisLinks)
	local accel = data.Acceleration or Vector3.zero
	local growthSpeed = RangeMod.RandomValueFromRange(data.GrowthSpeed)
	local pData = {
		Type = "Lightning",
		VisualPart = model,
		_rig = rig,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = math.max(1, data.TotalKeyFrames),
		CurrentStep = 0,
		LifeTime = lifeTime,
		PartLife = data.PartLife or 0,
		_sourceItem = item,

		Graphs = {
			Color = data.Color,
			Gradient = PDataBuilder.liveColor(data.Gradient),
			Brightness = data.Brightness,
			Transparency = data.Transparency,
			Thickness = data.Thickness,
			ThicknessProfile = data.ThicknessProfile,
			Timescale = data.Timescale,
			Speed = data.Speed,
			PosOffsetX = data.PosOffsetX,
			PosOffsetY = data.PosOffsetY,
			PosOffsetZ = data.PosOffsetZ,
			Turbulence = data.Turbulence,
		},
		Seeds = seeds,
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.Timescale, seeds.Timescale, lifeTime),

		_endpointMode = data.TargetMode == "Seek" and "Seek"
			or ((data.TargetMode == "Point" and data.Target and data.Target.Parent) and "Point" or "Directional"),
		_target = data.Target,
		-- The authored Link (Link section). A top-level bolt's origin rides it by LinkMode; a
		-- nested bolt rides its parent clone instead (Endpoints.resolveEndpoints).
		_userLink = data.Link,
		LinkMode = data.LinkMode,
		LinkAxes = data.LinkAxes,
		_seekRadius = math.max(RangeMod.RandomValueFromRange(data.SeekRadius), 1),
		_seekRetarget = data.SeekRetarget == true,
		_seekBias = math.clamp(data.SeekBias or 0, 0, 1),
		_retargetSpeed = math.max(data.RetargetSpeed or 0, 0),
		-- Seek fires OnHit from its own scan (fireSeekHit); the generic
		-- Events.afterUpdate raycast + Collision actions must skip this pData.
		_ownsOnHit = true,
		_length = math.max(0.1, RangeMod.RandomValueFromRange(data.Length)),
		-- Bolt-shape ranges roll ONCE per bolt (variety across a burst; stable within a bolt).
		_segCount = math.clamp(math.floor(RangeMod.RandomValueFromRange(data.SegmentCount) + 0.5), 2, rig.mainSegs),
		_amplitude = RangeMod.RandomValueFromRange(data.Amplitude),
		_decay = RangeMod.RandomValueFromRange(data.AmplitudeDecay),
		_forkChance = RangeMod.RandomValueFromRange(data.ForkChance),
		_forkDepth = math.floor(RangeMod.RandomValueFromRange(data.ForkDepth) + 0.5),
		_forkLenScale = RangeMod.RandomValueFromRange(data.ForkLengthScale),
		_sag = RangeMod.RandomValueFromRange(data.Sag),
		_sagShape = RangeMod.RandomValueFromRange(data.SagShape),
		_shapeMode = data.ShapeMode or "Jitter",
		_scrollSpeed = RangeMod.RandomValueFromRange(data.ScrollSpeed),
		_waves = math.max(0.25, RangeMod.RandomValueFromRange(data.Waves)),
		_scrollPhase = 0,
		_noiseSeedA = math.random() * 1000,
		_noiseSeedB = 500 + math.random() * 1000,
		_jitterAccum = 0,
		_lSpeed = growthSpeed,
		_growReversed = growthSpeed < 0,
		_tipDist = 0,
		_revealPtr = 0,
		_nestedAlive = { true },

		-- Origin motion (Speed along launch dir + Acceleration + Drag) and PosOffset
		-- displacement graphs. Accumulated per frame in UpdateLightning; applied to
		-- the origin by resolveEndpoints each roll.
		_accel = accel,
		_drag = data.Drag or 0,
		_dispMode = data.DisplacementMode or "Global",
		_motionOffset = Vector3.zero,
		_motionAccelVel = Vector3.zero,
		_hasMotion = data.Speed ~= nil or accel.Magnitude > 0,
		_hasDisp = data.PosOffsetX ~= nil or data.PosOffsetY ~= nil or data.PosOffsetZ ~= nil,
		-- Origin turbulence: sampled per frame into _turbRaw by UpdateLightning,
		-- applied by resolveEndpoints in the _dispMode frame.
		_hasTurb = data.Turbulence ~= nil,
		_turbFreq = data.TurbulenceFrequency or 1,
		_turbSeed = math.random() * 997 + 0.5,
		_turbRaw = nil,
	}
	local jitterHz = RangeMod.RandomValueFromRange(data.JitterRate)
	pData._jitterInterval = jitterHz > 0 and 1 / jitterHz or math.huge

	-- Directional launch axis in SOURCE-local space: EmissionDirection rotated by
	-- RotXYZ (even-distribution aware) ± SpreadAngle. Spawn Pos offsets the origin
	-- in the origin frame (PosMode Global = world axes); applied live per roll by
	-- resolveEndpoints so moving sources/links carry the pattern.
	local dirInfo = DirectionVectors[data.EmissionDirection] or DirectionVectors[Enum.NormalId.Top]
	local localAxis = CFrame.new()[dirInfo.vector] * dirInfo.multiplier
	local spread = data.SpreadAngle or Vector2.new(0, 0)
	local rotS = AxisLinksMod.sampleRangeAxes(data, data.AxisLinks, {"RotX","RotY","RotZ"}, RangeMod, emitCtx)
	local rotXYZ = Constants.composeRotation(data.RotOrder or "Global", rotS.RotX or 0, rotS.RotY or 0, rotS.RotZ or 0)
	local cf = CFrame.lookAt(Vector3.zero, localAxis)
	-- Direction picks up RotXYZ only in DirMode=Local. RigidLocal (default) keeps the
	-- authored facing so Rot drives the Pos frame alone  -  rings keep their direction.
	if data.DirMode == "Local" then cf = cf * rotXYZ end
	if spread.X > 0 or spread.Y > 0 then
		cf = cf * CFrame.Angles(
			math.rad((math.random() * 2 - 1) * spread.X),
			math.rad((math.random() * 2 - 1) * spread.Y), 0)
	end
	pData._dirLocalVec = cf.LookVector
	pData._dirGlobal = data.DirMode == "Global"
	-- Rotation applies BEFORE position offsets (Part-emitter order): Local Pos +
	-- displacement frames live in the per-bolt ROTATED frame (rings/spirals).
	pData._originRot = rotXYZ
	local posS = AxisLinksMod.sampleRangeAxes(data, data.AxisLinks, {"PosX","PosY","PosZ"}, RangeMod, emitCtx)
	local px, py, pz = posS.PosX or 0, posS.PosY or 0, posS.PosZ or 0
	if px ~= 0 or py ~= 0 or pz ~= 0 then
		pData._originOffset = Vector3.new(px, py, pz)
		pData._originOffsetGlobal = data.PosMode == "Global"
	else
		pData._originOffset = nil
	end
	EndpointsMod.sampleShape(pData, data, item)
	return pData
end

return PDataBuilder
