--[[
	Rope/PDataBuilder  -  per-rope pData construction, shared by Emit + Animate
	+ the AnimateLoop refresh (refresh re-reads via readRopeParams so live edits
	apply each cycle). Rope length: RopeLength <= 0 = auto (anchor distance ×
	Slack; 10 × Slack when unpinned/no Target).
]]

local GraphMod = require(script.Parent.Parent.Graph)
local RangeMod = require(script.Parent.Parent.Range)
local Constants = require(script.Parent.Parent.PartConstants)
local Turbulence = require(script.Parent.Parent.Turbulence)
local AxisLinksMod = require(script.Parent.Parent.AxisLinks)
local Anchors = require(script.Parent.Anchors)

local DirectionVectors = Constants.DirectionVectors

local PDataBuilder = {}

-- Flat-zero displacement graphs read as "no motion" so idle ropes skip sampling.
local function liveGraph(seq)
	if not seq then return nil end
	if GraphMod.IsStatic(seq) and GraphMod.GetStaticValue(seq, 0) == 0 then return nil end
	return seq
end

-- Rope-parameter block, written onto pData. Refresh calls this too, so every
-- field here must be safe to overwrite mid-life.
function PDataBuilder.readRopeParams(pData, data, rig, emitCtx)
	pData._pinMode = data.PinMode or "BothEnds"
	pData._target = data.Target
	pData._pinStart = true
	pData._pinEnd = (pData._pinMode == "BothEnds" and data.Target ~= nil) or pData._pinMode == "Launch"
	pData._segCount = math.clamp(math.floor(RangeMod.RandomValueFromRange(data.SegmentCount) + 0.5), 2, rig.segCap)
	pData._stiffness = math.clamp(math.floor((data.Stiffness or 4) + 0.5), 1, 10)
	pData._bendStiffness = math.clamp(data.BendStiffness or 0, 0, 1)
	pData._damping = math.clamp(data.Damping or 0.03, 0, 0.5)
	pData._gravity = data.Gravity or Vector3.new(0, -40, 0)
	pData._windAmp = RangeMod.RandomValueFromRange(data.WindAmplitude)
	pData._windFreq = data.WindFrequency or 2

	-- Lifecycle: GrowIn pays the rope out over the first fraction of life;
	-- DeathMode ends it (Retract reels back in, Release drops all pins).
	pData._growIn = math.clamp(data.GrowIn or 0, 0, 0.9)
	pData._deathMode = data.DeathMode or "None"
	pData._deathWindow = math.clamp(data.DeathWindow or 0.2, 0.05, 0.9)

	-- Taper: ThicknessProfile sampled along the ARC (0 = root, 1 = tip) into the
	-- per-segment width scale; writeVisuals/writeSegments multiply Thickness by it.
	local profile = data.ThicknessProfile
	local flatProfile = not profile or GraphMod.IsStatic(profile)
	local profileSeed = (not flatProfile) and GraphMod.GenerateSeed(profile) or nil
	for i = 1, rig.segCap do
		if flatProfile then
			rig.widthScale[i] = profile and GraphMod.GetStaticValue(profile, 1) or 1
		else
			rig.widthScale[i] = math.max(GraphMod.QueryPointsWithTime((i - 0.5) / rig.segCap, profile, profileSeed), 0.05)
		end
	end

	-- Anchor motion: Displacement graphs + Turbulence aimed at one anchor.
	pData._motionTarget = data.MotionTarget or "Start"
	pData._dispMode = data.DisplacementMode or "Global"
	local ox = liveGraph(data.PosOffsetX)
	local oy = liveGraph(data.PosOffsetY)
	local oz = liveGraph(data.PosOffsetZ)
	pData.Graphs.PosOffsetX = ox
	pData.Graphs.PosOffsetY = oy
	pData.Graphs.PosOffsetZ = oz
	pData._hasDisp = (ox or oy or oz) ~= nil
	if ox then pData.Seeds.PosOffsetX = pData.Seeds.PosOffsetX or GraphMod.GenerateSeed(ox) end
	if oy then pData.Seeds.PosOffsetY = pData.Seeds.PosOffsetY or GraphMod.GenerateSeed(oy) end
	if oz then pData.Seeds.PosOffsetZ = pData.Seeds.PosOffsetZ or GraphMod.GenerateSeed(oz) end
	local turb = Turbulence.isLive(data.Turbulence)
	pData.Graphs.Turbulence = turb
	pData._hasTurb = turb ~= nil
	if turb then
		pData.Seeds.Turbulence = pData.Seeds.Turbulence or GraphMod.GenerateSeed(turb)
		pData._turbFreq = data.TurbulenceFrequency or 1
		pData._turbSeed = pData._turbSeed or (math.random() * 997 + 0.5)
	end

	-- Spawn frame (Lightning parity): RotXYZ rolled per rope (even-distribution
	-- aware via emitCtx + rolling cycles) rotates the AIM and the Local spawn
	-- offset frame — rings, fans, crowns. Pos offset applies to the SpawnTarget
	-- anchor (Anchors resolves it; Local = source × RotXYZ frame, Global = world).
	local rotS = AxisLinksMod.sampleRangeAxes(data, data.AxisLinks, {"RotX", "RotY", "RotZ"}, RangeMod, emitCtx)
	local rotXYZ = Constants.composeRotation(data.RotOrder or "Global", rotS.RotX or 0, rotS.RotY or 0, rotS.RotZ or 0)
	pData._spawnRot = rotXYZ
	local posS = AxisLinksMod.sampleRangeAxes(data, data.AxisLinks, {"PosX", "PosY", "PosZ"}, RangeMod, emitCtx)
	pData._spawnOff = Vector3.new(posS.PosX or 0, posS.PosY or 0, posS.PosZ or 0)
	pData._spawnOffMode = data.PosMode or "Local"
	pData._spawnTarget = data.SpawnTarget or "Start"

	-- Emit-frame origin: needed for auto rope length + direction composition.
	local originCF = Anchors.resolveStart(pData)

	-- Aim = EmissionDirection in the RotXYZ-rotated frame ± SpreadAngle, world-
	-- composed at emit and FROZEN (a thrown hook doesn't re-aim when the source
	-- moves afterwards). Seeds StartOnly poses + aims Launch throws. Speed gets
	-- its OWN MotionDirection axis in the same rotated frame.
	local spread = data.SpreadAngle or Vector2.new(0, 0)
	local function composeDir(normalId)
		local dirInfo = DirectionVectors[normalId] or DirectionVectors[Enum.NormalId.Front]
		local axis = CFrame.new()[dirInfo.vector] * dirInfo.multiplier
		local cf = CFrame.lookAt(Vector3.zero, axis) * rotXYZ
		if spread.X > 0 or spread.Y > 0 then
			cf = cf * CFrame.Angles(
				math.rad((math.random() * 2 - 1) * spread.X),
				math.rad((math.random() * 2 - 1) * spread.Y), 0)
		end
		return originCF.Rotation:VectorToWorldSpace(cf.LookVector)
	end
	pData._motionDir = composeDir(data.EmissionDirection)
	pData._speedDir = composeDir(data.MotionDirection or data.EmissionDirection)

	-- Speed-along-direction + Acceleration drift + Drag, accumulated per frame
	-- by UpdateRope into _motionOffset (Lightning origin-motion pattern).
	local speedGraph = liveGraph(data.Speed)
	pData.Graphs.Speed = speedGraph
	if speedGraph then
		pData.Seeds.Speed = pData.Seeds.Speed or GraphMod.GenerateSeed(speedGraph)
	end
	pData._accel = data.Acceleration or Vector3.zero
	pData._drag = data.Drag or 0
	pData._hasMotion = speedGraph ~= nil or pData._accel.Magnitude > 0
	pData._motionOffset = Vector3.zero
	pData._motionAccelVel = Vector3.zero

	-- Launch: ballistic end anchor. With a Target the velocity is SOLVED so the
	-- arc passes through the target at T = distance / LaunchSpeed  -  the hook
	-- flies there and attaches (UpdateRope pins to the live target after T).
	-- Without a Target it throws blind along the composed direction.
	if pData._pinMode == "Launch" then
		local speed = math.max(RangeMod.RandomValueFromRange(data.LaunchSpeed), 1)
		pData._launchOrigin = originCF.Position
		pData._launchT = nil
		local targetPos
		if data.Target then
			local ok, endCF = pcall(Constants.resolveLinkCFrame, data.Target)
			if ok and endCF then targetPos = endCF.Position end
		end
		if targetPos then
			local delta = targetPos - originCF.Position
			local T = math.max(delta.Magnitude / speed, 0.05)
			pData._launchVel = delta * (1 / T) - pData._gravity * (0.5 * T)
			pData._launchT = T
		else
			pData._launchVel = pData._motionDir * speed
		end
	end

	-- Rest length needs the anchor span; resolve start/end the cheap way here
	-- (Anchors owns the live per-substep version).
	local ropeLen = RangeMod.RandomValueFromRange(data.RopeLength)
	if ropeLen <= 0 then
		local slack = math.max(data.Slack or 1.2, 1)
		local span = 10
		if (pData._pinMode == "BothEnds" or pData._pinMode == "Launch") and data.Target then
			local ok, endCF = pcall(Constants.resolveLinkCFrame, data.Target)
			if ok and endCF then
				span = math.max((endCF.Position - originCF.Position).Magnitude, 1)
			end
		end
		ropeLen = span * slack
	end
	pData._restLen = math.max(ropeLen / pData._segCount, 0.05)
end

function PDataBuilder.build(item, data, model, rig, lifeTime, emitCtx, link)
	local seeds = {
		Brightness = GraphMod.GenerateSeed(data.Brightness),
		Transparency = GraphMod.GenerateSeed(data.Transparency),
		Thickness = GraphMod.GenerateSeed(data.Thickness),
		Timescale = GraphMod.GenerateSeed(data.Timescale),
	}
	local pData = {
		Type = "Rope",
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
			Brightness = data.Brightness,
			Transparency = data.Transparency,
			Thickness = data.Thickness,
			Timescale = data.Timescale,
		},
		Seeds = seeds,
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.Timescale, seeds.Timescale, lifeTime),
		_parentLink = link,
		_accum = 0,
		_windPhase = 0,
		_windSeedA = math.random() * 1000,
		_windSeedB = 500 + math.random() * 1000,
	}

	-- Event-origin override freezes the start anchor at the event's frame.
	if emitCtx then
		local oCF
		if emitCtx.EventOriginResolver then oCF = emitCtx.EventOriginResolver() end
		oCF = oCF or emitCtx.EventOriginCF
		if oCF then
			pData._startCFOverride = (emitCtx.UseFullOrigin and oCF) or CFrame.new(oCF.Position) * item.CFrame.Rotation
		end
	end

	PDataBuilder.readRopeParams(pData, data, rig, emitCtx)
	-- The rig Model has no PrimaryPart, so an unset WorldPivot tracks the live bbox, which the
	-- 1e9-parked slots drag away; stamp the start anchor so nested links read it (Lightning does the same).
	pcall(function() model.WorldPivot = Anchors.resolveStart(pData) end)
	-- Fresh emit = un-bitten hook + unreleased pins. The AnimateLoop refresh
	-- calls readRopeParams WITHOUT resetting these so the states survive cycles.
	pData._launchArrived = false
	pData._released = false
	return pData
end

return PDataBuilder
