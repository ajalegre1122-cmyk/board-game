--[[
	Emit Mixin  -  per-type one-shot emit for Part / Beam (Attachment lives in EmitAttachment.luau).
	Clones RT, computes initial CFrame + direction, pushes pData onto Particle.ActiveEmits.
	Motion math shared with Motion Preview via PreSimulateForward / PreSimulateAttachmentForward.
]]

local GraphMod = require(script.Parent.Graph)
local RangeMod = require(script.Parent.Range)
local AxisLinksMod = require(script.Parent.AxisLinks)
local ParticlesMod = require(script.Parent.Particles)
local MeshFlipMod = require(script.Parent.Flipbook)
local Constants = require(script.Parent.PartConstants)
local Pool = require(script.Parent.Pool)
local NestedEmit = require(script.Parent.NestedEmit)
local StaticPass = require(script.Parent.StaticPass)
local LinkCF = require(script.Parent.LinkCF)
local Turbulence = require(script.Parent.Turbulence)
local DecalLayersMod = require(script.Parent.DecalLayers)
local MeshFramesMod = require(script.Parent.MeshFrames)
local DirectionVectors = Constants.DirectionVectors
local shapeFunctions = Constants.shapeFunctions

return function(Particle)

-- One Part emit. Initial CFrame: link/LinkMode → Shape offset → RotXYZ → Position offset
-- → strip rotation if DirMode=Global. InvertMotion pre-simulates to endpoint.
-- emitCtx (optional): {ChainCtx, EmitIndex, EventOriginCF, EventOriginResolver, IgnoreLink, UseFullOrigin}
-- EventOriginResolver wins over EventOriginCF (live vs snapshot).
function Particle:EmitPart(part, link, emitCtx)
	if not part or not part.Parent then return end
	local data = self:GetEmitData(part, emitCtx)
	if not data or not data.RenderTemplate then return end
	if emitCtx and emitCtx.IgnoreLink then
		link = nil
	else
		link = link or data.Link
	end

	local Time = RangeMod.RandomValueFromRange(data.Lifetime)
	if Time <= 0 then Time = 0.001 end

	local spawnAxes = LinkCF.spawnAxes(data, emitCtx)
	-- Follow drops link rotation; Weld/Pivot compose it.
	local unrotatedCF
	local originOverrideCF
	if emitCtx then
		if emitCtx.EventOriginResolver then originOverrideCF = emitCtx.EventOriginResolver() end
		if not originOverrideCF then originOverrideCF = emitCtx.EventOriginCF end
	end
	if originOverrideCF then
		if emitCtx and emitCtx.UseFullOrigin then
			unrotatedCF = originOverrideCF -- AtCFrame: full source orientation
		else
			-- AtPosition / AtSource: replace position only, keep target rotation.
			unrotatedCF = CFrame.new(originOverrideCF.Position) * part.CFrame.Rotation
		end
	elseif link then
		unrotatedCF = LinkCF.spawnFrame(data.LinkMode, link, part, part.CFrame, emitCtx and emitCtx._linkLocal, emitCtx and emitCtx._sourceParentCF, spawnAxes)
	else unrotatedCF = part.CFrame end
	local dirInfo = DirectionVectors[data.EmissionDirection] or DirectionVectors[Enum.NormalId.Top]
	local rawWorldDirection = unrotatedCF[dirInfo.vector] * dirInfo.multiplier

	-- Shape branch. UseShape gates; shape function returns offset / rotation / outward direction.
	-- ShapePart override: when set, sample volume + spawn position in ShapePart's frame.
	-- nil falls back to existing source-frame behavior (unrotatedCF).
	local localOffset = Vector3.new()
	local shapeDir = nil
	local initialCF = unrotatedCF
	if data.UseShape then
		local shapeFunc = shapeFunctions[data.ParticleData.Shape]
		if shapeFunc then
			local shapeSrc = data.ShapePart or part
			local shapeCF = data.ShapePart and data.ShapePart.CFrame or unrotatedCF
			local sOffset, sRotation, sDirVec = shapeFunc(shapeSrc, data.ParticleData)
			localOffset = sOffset
			local sio = data.ParticleData.ShapeInOut
			if sio == Enum.ParticleEmitterShapeInOut.Inward then
				sDirVec = -sDirVec
			elseif sio == Enum.ParticleEmitterShapeInOut.InAndOut then
				if math.random() < 0.5 then sDirVec = -sDirVec end
			end
			shapeDir = (shapeCF - shapeCF.Position):VectorToWorldSpace(sDirVec)
			if data.ParticleData.LookAtInitially then
				local rx, ry, rz = initialCF:ToEulerAnglesXYZ()
				initialCF = CFrame.new((shapeCF * CFrame.new(localOffset)).Position)
					* sRotation * CFrame.Angles(rx, ry, rz)
			else
				initialCF = CFrame.new((shapeCF * CFrame.new(localOffset)).Position) * initialCF.Rotation
			end
		else
			initialCF = CFrame.new((initialCF * CFrame.new(localOffset)).Position) * initialCF.Rotation
		end
	else
		initialCF = CFrame.new((initialCF * CFrame.new(localOffset)).Position) * initialCF.Rotation
	end

	local dirMode = data.DirMode or "RigidLocal"
	local rotS = AxisLinksMod.sampleRangeAxes(data, data.AxisLinks, {"RotX","RotY","RotZ"}, RangeMod, emitCtx)
	local RX, RY, RZ = rotS.RotX, rotS.RotY, rotS.RotZ
	local rotXYZ = Constants.composeRotation(data.RotOrder or "Global", RX, RY, RZ)
	initialCF = initialCF * rotXYZ

	-- Nested-Model scale: scatter the spawn Pos spread by the parent Model's scale at THIS
	-- emit moment (Pos spread is a one-time spawn offset; per-frame motion scales separately).
	local posScale = 1
	local psInfo = emitCtx and emitCtx.ParentScale
	if psInfo and psInfo.ScaleMotion ~= false then
		posScale = Constants.getParentScaleFactor(psInfo, os.clock(), GraphMod)
	end
	initialCF = Constants.applyPositionOffset(initialCF, data, link, part, RangeMod, AxisLinksMod, emitCtx, nil, posScale)

	-- Global DirMode: drop emitter+link rotation; keep RotXYZ.
	if dirMode == "Global" then
		initialCF = CFrame.new(initialCF.Position) * rotXYZ
	end

	local baseDirection
	if shapeDir then
		baseDirection = shapeDir
	elseif dirMode == "Local" then
		baseDirection = initialCF[dirInfo.vector] * dirInfo.multiplier
	elseif dirMode == "Global" then
		baseDirection = CFrame.new()[dirInfo.vector] * dirInfo.multiplier
	else
		baseDirection = rawWorldDirection
	end
	local randomX, randomY = 0, 0
	if data.ParticleData.SpreadAngle.X > 0 or data.ParticleData.SpreadAngle.Y > 0 then
		randomX = (math.random() * 2 - 1) * data.ParticleData.SpreadAngle.X
		randomY = (math.random() * 2 - 1) * data.ParticleData.SpreadAngle.Y
	end
	local spreadRotation = CFrame.Angles(math.rad(randomX), math.rad(randomY), 0)

	local cf = CFrame.lookAt(Vector3.new(), baseDirection)
	cf = cf * spreadRotation
	baseDirection = cf.LookVector

	local seeds = {
		SizeX = GraphMod.GenerateSeed(data.SizeX), SizeY = GraphMod.GenerateSeed(data.SizeY), SizeZ = GraphMod.GenerateSeed(data.SizeZ),
		RotSpeedX = GraphMod.GenerateSeed(data.RotSpeedX), RotSpeedY = GraphMod.GenerateSeed(data.RotSpeedY), RotSpeedZ = GraphMod.GenerateSeed(data.RotSpeedZ),
		PosOffsetX = GraphMod.GenerateSeed(data.PosOffsetX), PosOffsetY = GraphMod.GenerateSeed(data.PosOffsetY), PosOffsetZ = GraphMod.GenerateSeed(data.PosOffsetZ),
		Speed = GraphMod.GenerateSeed(data.Speed), Brightness = GraphMod.GenerateSeed(data.Brightness),
		Transparency = GraphMod.GenerateSeed(data.Transparency),
		AccelStrength = GraphMod.GenerateSeed(data.AccelStrength),
		Timescale = GraphMod.GenerateSeed(data.Timescale),
	}

	-- Axis-link alias: followers adopt primary's seed + graph; mutates data + seeds in-place.
	AxisLinksMod.applyGraphAxisAliases(data, seeds, data.AxisLinks)

	local invertMotion = data.InvertMotion
	local simLocalCFrames = nil
	local simEffectiveTKF = nil

	if invertMotion then
		simLocalCFrames, simEffectiveTKF = self:PreSimulateForward(data, seeds, initialCF, baseDirection, spreadRotation, link, Time, nil, initialCF.Rotation * rotXYZ:Inverse(), emitCtx and emitCtx._linkLocal, spawnAxes and part.CFrame or nil)
	end

	local visualPart = Pool.acquireOrCopyBare(data.RenderTemplate, "Part", data.Pool)
	visualPart.Archivable = false
	local parentCF_now = LinkCF.emitParentFrame(data.LinkMode, link, emitCtx and emitCtx._linkLocal, spawnAxes, part.CFrame)
	local localCF

	if invertMotion and simLocalCFrames then
		-- Place at endpoint of forward sim. Index by effective TKF since presim caps at 500.
		local endLocalCF = simLocalCFrames[simEffectiveTKF or data.TotalKeyFrames] or simLocalCFrames[0]
		localCF = endLocalCF
		visualPart.CFrame = parentCF_now * localCF
	else
		localCF = link and parentCF_now:ToObjectSpace(initialCF) or initialCF
		visualPart.CFrame = parentCF_now * localCF
	end

	local pData = {
		Type = "Part",
		VisualPart = visualPart,
		Link = link,
		LinkMode = data.LinkMode,
		LinkAxes = data.LinkAxes,
		_linkLocal = emitCtx and emitCtx._linkLocal or nil,
		-- RigidLocal: snapshot the link's at-emit parent CFrame. Per-frame Link
		-- consumers (LinkTrack / getLinkCF / Bounce) read this instead of the live
		-- link CFrame. nil for non-RigidLocal modes.
		_rigidLocalParentCF = LinkCF.rigidSnapshot(data.LinkMode, link, parentCF_now),
		Events = data.Events,
		SpecialMesh = visualPart:FindFirstChildOfClass('SpecialMesh'),
		Decal = visualPart:FindFirstChildOfClass('Decal'),
		-- SurfaceAppearance: flipbook routes to ColorMap, Transparency/Color graphs drive MeshPart
		-- because SurfaceAppearance has no per-instance Transparency / Color3 surface.
		SurfaceAppearance = visualPart:FindFirstChildOfClass('SurfaceAppearance'),

		StartTime = os.clock(),
		TotalKeyFrames = invertMotion and simEffectiveTKF or math.max(1, data.TotalKeyFrames),
		CurrentStep = 0,
		AccumulatedDT = 0,
		LifeTime = Time,
		PartLife = data.PartLife,
		CurrentPosition = visualPart.Position,
		LocalCF = localCF,

		BaseDirection = baseDirection,
		-- Accumulated velocity contribution from Acceleration. Tracked explicitly so OnHit
		-- Bounce can reflect it along the hit normal (a closed-form `accel * elapsedSec`
		-- would keep integrating from t=0 across a bounce, diverging from physics).
		_accelVel = Vector3.zero,
		-- Speed multiplier: scales the speed graph's output. Compounds across bounces
		-- when Bounciness < 1  -  each bounce loses energy along the normal, so the
		-- particle's effective speed decreases on impact.
		SpeedMultiplier = 1,
		-- Persistent angular velocity from collision impulses (deg/sec, world axes).
		-- Bounce's tangential drag converts to spin; this rate compounds with each
		-- glancing impact. _spinAccum tracks the integrated rotation contribution.
		_spinRate = Vector3.zero,
		_spinAccumX = 0,
		_spinAccumY = 0,
		_spinAccumZ = 0,
		EmissionDirection = data.EmissionDirection,
		SpreadRotation = spreadRotation,
		Acceleration = data.ParticleData.Acceleration,
		Drag = data.ParticleData.Drag,
		VelocityVectored = data.VelocityVectored,

		InvertMotion = invertMotion,
		SimLocalCFrames = simLocalCFrames,

		RotMode = data.RotMode or "OverLife",
		RotOrder = data.RotOrder or "Global",
		AccRotX = 0, AccRotY = 0, AccRotZ = 0,

		Orientation = data.Orientation,
		ZOffset = data.ZOffset,
		_localWorldCF = localCF, -- seed for LinkTrack frame 0

		-- PosOffsetX/Y/Z trajectory state. DisplacementMode selects which rotation
		-- to apply: Local = SpawnRotation (post-RotXYZ particle frame); RigidLocal
		-- = SpawnEmitterRotation (same frame as SpawnRotation but with the per-
		-- particle RotXYZ contribution algebraically removed via rotXYZ:Inverse());
		-- Global = no rotation. HasPosOffsetGraphs gates per-frame work.
		SpawnRotation = localCF.Rotation,
		SpawnEmitterRotation = localCF.Rotation * rotXYZ:Inverse(),
		DisplacementMode = data.DisplacementMode,
		-- Body bbox half-diagonal for Jolt-style point-velocity sleep check.
		-- Captures rotation-induced edge speed when CoM is near-stationary.
		_sleepRadius = (visualPart and visualPart:IsA("BasePart") and visualPart.Size.Magnitude * 0.5) or 1.0,
		_prevWorldOff = Vector3.zero,
		HasPosOffsetGraphs = data.PosOffsetX ~= nil or data.PosOffsetY ~= nil or data.PosOffsetZ ~= nil,

		-- Target-accel: target.Position read live each frame, target ref fixed at emit.
		-- Disabled with InvertMotion (cached SimLocalCFrames can't track moving targets).
		HasTargetAccel = data.AccelerationTowardsInstance == true and data.AccelTarget ~= nil and data.AccelStrength ~= nil and not data.InvertMotion,
		AccelTarget = data.AccelTarget,
		TargetVel = Vector3.zero,
		NeedsFullIteration = data.VelocityVectored,
		NeedsRotAccum = (data.RotMode == "Speed") and not data.VelocityVectored,
		HasDrag = data.ParticleData.Drag ~= 0,
		HasAccel = data.ParticleData.Acceleration.Magnitude > 0,
		HasDecal = visualPart:FindFirstChildOfClass('Decal') ~= nil,
		DecalLayersMode = data.DecalLayersMode,

		Graphs = {
			SizeX = data.SizeX, SizeY = data.SizeY, SizeZ = data.SizeZ,
			RotSpeedX = data.RotSpeedX, RotSpeedY = data.RotSpeedY, RotSpeedZ = data.RotSpeedZ,
			PosOffsetX = data.PosOffsetX, PosOffsetY = data.PosOffsetY, PosOffsetZ = data.PosOffsetZ,
			Speed = data.Speed, Brightness = data.Brightness,
			Transparency = data.Transparency, Color = data.Color,
			AccelStrength = data.AccelStrength,
			Timescale = data.Timescale,
		},

		Seeds = seeds,
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.Timescale, seeds.Timescale, Time),
	}

	-- 1-frame pop prevention for PosOffset graphs: sample at t=0, apply to spawn
	-- pose so frame-0 visual already includes the initial offset. Initialize
	-- _prevWorldOff to worldOff(0) so the first Update step's delta is measured
	-- from this baseline (not from zero  -  which would cause a teleport at step 1
	-- for front-loaded curves where posOff ramps fast initially).
	if pData.HasPosOffsetGraphs then
		local oX = pData.Graphs.PosOffsetX and GraphMod.QueryPointsWithTime(0, pData.Graphs.PosOffsetX, pData.Seeds.PosOffsetX) or 0
		local oY = pData.Graphs.PosOffsetY and GraphMod.QueryPointsWithTime(0, pData.Graphs.PosOffsetY, pData.Seeds.PosOffsetY) or 0
		local oZ = pData.Graphs.PosOffsetZ and GraphMod.QueryPointsWithTime(0, pData.Graphs.PosOffsetZ, pData.Seeds.PosOffsetZ) or 0
		local worldOff = Constants.resolveDisplacement(Vector3.new(oX, oY, oZ),
			data.DisplacementMode or "Global", pData.SpawnRotation, pData.SpawnEmitterRotation)
		pData._prevWorldOff = worldOff
		if oX ~= 0 or oY ~= 0 or oZ ~= 0 then
			pData.LocalCF = pData.LocalCF + worldOff
			pData.VisualPart.CFrame = pData.VisualPart.CFrame + worldOff
		end
	end
	Turbulence.buildInto(pData, data)

	-- 1-frame pop prevention.
	local startSize = Vector3.new(GraphMod.QueryPointsWithTime(0, pData.Graphs.SizeX, pData.Seeds.SizeX), GraphMod.QueryPointsWithTime(0, pData.Graphs.SizeY, pData.Seeds.SizeY), GraphMod.QueryPointsWithTime(0, pData.Graphs.SizeZ, pData.Seeds.SizeZ))
	local startTrans = GraphMod.QueryPointsWithTime(0, pData.Graphs.Transparency, pData.Seeds.Transparency)
	local startColor = GraphMod.QueryColorPointWithTime(0, pData.Graphs.Color)
	local startBright = GraphMod.QueryPointsWithTime(0, pData.Graphs.Brightness, pData.Seeds.Brightness)

	if pData.SpecialMesh then
		pData.SpecialMesh.Scale = startSize
	else
		pData.VisualPart.Size = startSize
	end

	if pData.SurfaceAppearance then
		-- Color graph tints SA.Color raw; Brightness graph drives SA.EmissiveTint only.
		-- EmissiveTint write pcall-guarded for older Studio builds without the property.
		pData.VisualPart.Transparency = startTrans
		pData.VisualPart.Color = Color3.fromRGB(startColor.R * 255, startColor.G * 255, startColor.B * 255)
		pData.SurfaceAppearance.Color = Color3.fromRGB(startColor.R * 255, startColor.G * 255, startColor.B * 255)
		pcall(function() pData.SurfaceAppearance.EmissiveTint = Color3.new(startColor.R * startBright, startColor.G * startBright, startColor.B * startBright) end)
	elseif pData.Decal and not data.DecalLayersMode then
		pData.Decal.Transparency = startTrans
		pData.Decal.Color3 = Color3.fromRGB(startColor.R * 255 * startBright, startColor.G * 255 * startBright, startColor.B * 255 * startBright)
	else
		-- Mesh: Brightness scales the mesh colour in decal-layers mode; legacy plain meshes ignore it.
		local meshBright = data.DecalLayersMode and startBright or 1
		pData.VisualPart.Transparency = startTrans
		pData.VisualPart.Color = Color3.fromRGB(startColor.R * 255 * meshBright, startColor.G * 255 * meshBright, startColor.B * 255 * meshBright)
	end

	-- Disable PEs BEFORE Parent so they don't auto-emit on workspace entry;
	-- EnableEmitSingle below controls their timing.
	for _, desc in visualPart:GetDescendants() do
		if desc:IsA("ParticleEmitter") then desc.Enabled = false end
	end

	visualPart.Parent = data.EmitParent or self:GetFolder()

	for _, desc in visualPart:GetDescendants() do
		if desc:IsA("Trail") then
			if desc:GetAttribute("Transformed") then continue end
			local underTransformed = false
			local cur = desc.Parent
			while cur and cur ~= visualPart do
				if cur:GetAttribute("Transformed") then underTransformed = true; break end
				cur = cur.Parent
			end
			if underTransformed then continue end
			local dur = desc:GetAttribute("EmitDuration")
			if dur ~= nil then
				if desc.Enabled ~= true then
					desc.Enabled = true
				end
				if desc:GetAttribute("_pooledTrailEnabled") ~= nil then
					desc:SetAttribute("_pooledTrailEnabled", true)
				end
			end
		end
	end

	-- Restore pooled Trails (deferred 1 Heartbeat). Snapshot was synced above
	-- so this is consistent with our pre-Parent enable for fresh emits.
	Pool.restoreTrails(visualPart, "Part")

	-- EnableEmitSingle schedules the EmitDuration-end Trail.Enabled=false and
	-- the PE Emit(count) burst. Trail.Enabled=true was already set above; this
	-- just registers the disable timer + PE emission.
	local alive = self:_makeAliveCheck()
	for _, child in visualPart:GetChildren() do
		if child:IsA("Attachment") then ParticlesMod.EnableEmitChildrenAndRepeatForAttachments(child, alive) end
		ParticlesMod.EnableEmitSingle(child, alive)
	end

	if emitCtx and emitCtx.ParentScale then
		pData.ParentScale = emitCtx.ParentScale
	end

	pData._sourceItem = part
	Particle._seedTsOverride(pData, part)
	if data.Pool ~= false then pData._sourceRT, pData._poolKind = data.RenderTemplate, "Part" end
	-- Static-graph short-circuit: constant-valued graphs nil out + stamp pData._static<Name>.
	StaticPass.apply(pData)
	-- _applyEmitVisualPasses MUST precede _registerEmit (OnEmit payload reads post-pass CFrame).
	self:_applyEmitVisualPasses(pData)
	pData._nestedAlive = { true }
	self:_registerEmit(pData, emitCtx)

	-- Decal layers bind after Parent: the layer flipbook task exits while the visual is unparented.
	DecalLayersMod.attach(pData, data, visualPart, Time, false)
	MeshFramesMod.attach(pData, data, visualPart, Time, false)
	-- Flipbook target: SA.ColorMap if present, else Decal.Texture, else MeshPart.TextureID
	-- when the visual is a plain MeshPart with no Decal/SA child to write to. Textured mesh
	-- frames carry their own TextureID through ApplyMesh, so they take the MeshPart instead.
	if data.CachedMeshTextures and #data.CachedMeshTextures > 0 then
		local flipTarget = pData.SurfaceAppearance
		if not flipTarget and not data.DecalLayersMode and not data.MeshFramesTextured then flipTarget = pData.Decal end
		if not flipTarget and visualPart:IsA("MeshPart") and not pData.Layers and not data.MeshFramesTextured then flipTarget = visualPart end
		if flipTarget then
			MeshFlipMod.Flip(pData, data.ParticleData, data.CachedMeshTextures, flipTarget, Time)
		end
	end

	-- Nested Part-Icles: source-walk; link = visualPart drives position. See NestedEmit.luau.
	-- The inherited Model-scale chain node is forwarded to deeper nested
	-- particles, so Model→Part→Part keeps scaling (a Part adds no factor, just propagates).
	NestedEmit.walk(self, data.RenderTemplate, visualPart, pData._nestedAlive, emitCtx, pData.ParentScale)
end

-- Beams: no spatial motion (welded to Attachment0/1). Animation via per-prop graphs,
-- GraphBlender, and BeamFlipbooks. Static graphs read once at emit.
function Particle:EmitBeam(beam, link, emitCtx)
	if not beam or not beam.Parent then return end
	local data = self:GetEmitData(beam, emitCtx)
	if not data or not data.RenderTemplate then return end

	-- PoolHide flipped Enabled=false on release; flip back here.
	local visualBeam = Pool.acquireOrClone(data.RenderTemplate, "Beam", data.Pool)
	visualBeam.Archivable = false
	visualBeam.Enabled = true
	if data.FaceCamera ~= nil then visualBeam.FaceCamera = data.FaceCamera end
	if data.ZOffset ~= nil then visualBeam.ZOffset = data.ZOffset end
	if data.TextureMode ~= nil then visualBeam.TextureMode = data.TextureMode end

	-- Bind the ends from the AUTHORED RT references (a pooled visual still carries a previous
	-- parent's clone attachments): the parent clone's copy when one exists, else the source.
	local map = emitCtx and emitCtx._parentCloneMap
	local a0, a1 = data.RenderTemplate.Attachment0, data.RenderTemplate.Attachment1
	local c0 = map and a0 and map[a0]
	local c1 = map and a1 and map[a1]
	visualBeam.Attachment0 = (c0 and c0.Parent) and c0 or a0
	visualBeam.Attachment1 = (c1 and c1.Parent) and c1 or a1

	-- Static / animated beam property split.
	local animatedProps = {}
	for name, sequence in pairs(data.BeamProps) do
		if sequence then
			if GraphMod.IsStatic(sequence) then
				visualBeam[name] = GraphMod.GetStaticValue(sequence, visualBeam[name])
			else
				local seed = GraphMod.GenerateSeed(sequence)
				animatedProps[name] = { Sequence = sequence, Seed = seed }
				if name ~= "TextureSpeed" then
					local initVal = GraphMod.QueryPointsWithTime(0, sequence, seed)
					if name == "Segments" then initVal = math.max(20, math.round(initVal)) end
					visualBeam[name] = initVal
				end
			end
		end
	end

	-- Disable engine TextureSpeed accumulation; UpdateBeam computes offset.
	if animatedProps.TextureSpeed then
		visualBeam.TextureSpeed = 0
	end

	local transStates, colorStates = GraphMod.CollectGraphStates(data.GraphBlender)

	-- Cache merged keypoint times per adjacent pair.
	local transMergedTimes = {}
	for idx = 1, #transStates - 1 do
		transMergedTimes[idx] = GraphMod.PrecomputeMergedTimes(transStates[idx].Graph, transStates[idx + 1].Graph)
	end
	local colorMergedTimes = {}
	for idx = 1, #colorStates - 1 do
		colorMergedTimes[idx] = GraphMod.PrecomputeMergedColorTimes(colorStates[idx].Graph, colorStates[idx + 1].Graph)
	end

	-- Apply initial blender state (1-frame pop prevention).
	if #transStates > 0 then visualBeam.Transparency = transStates[1].Graph end
	if #colorStates > 0 then visualBeam.Color = colorStates[1].Graph end

	visualBeam.Parent = data.EmitParent or self:GetFolder()

	local safeLifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	if safeLifeTime <= 0 then safeLifeTime = 0.001 end
	local beamTimescaleSeed = GraphMod.GenerateSeed(data.BeamTimescale)

	local pData = {
		Type = "Beam",
		VisualPart = visualBeam,
		Link = link,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = math.max(1, data.TotalKeyFrames),
		CurrentStep = 0,
		LifeTime = safeLifeTime,
		PartLife = data.PartLife or 0,

		AnimatedProps = animatedProps,

		TransStates = transStates,
		ColorStates = colorStates,
		TransMergedTimes = transMergedTimes,
		ColorMergedTimes = colorMergedTimes,

		Graphs = { Timescale = data.BeamTimescale },
		Seeds = { Timescale = beamTimescaleSeed },
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.BeamTimescale, beamTimescaleSeed, safeLifeTime),
	}

	-- Inherit parent model scale; cache bases for static props.
	if emitCtx and emitCtx.ParentScale then
		pData.ParentScale = emitCtx.ParentScale
		pData._baseWidth0 = visualBeam.Width0
		pData._baseWidth1 = visualBeam.Width1
		pData._baseCurveSize0 = visualBeam.CurveSize0
		pData._baseCurveSize1 = visualBeam.CurveSize1
		pData._baseTextureLength = visualBeam.TextureLength
		pData._baseSegments = visualBeam.Segments
	end

	pData._sourceItem = beam
	Particle._seedTsOverride(pData, beam)
	if data.Pool ~= false then pData._sourceRT, pData._poolKind = data.RenderTemplate, "Beam" end
	-- No _applyEmitVisualPasses for Beam (spatial-mesh only).
	self:_registerEmit(pData, emitCtx)

	if data.CachedBeamTextures and #data.CachedBeamTextures > 0 and data.FlipbookParticle then
		MeshFlipMod.FlipBeam(pData, data.FlipbookParticle, data.CachedBeamTextures, visualBeam, safeLifeTime)
	end
end

end
