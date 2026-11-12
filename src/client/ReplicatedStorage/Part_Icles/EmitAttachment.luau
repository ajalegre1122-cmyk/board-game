--[[
	EmitAttachment Mixin  -  one-shot emit for Attachment particles, split from Emit.luau for the
	500-line cap. Composes in the nearest BasePart ancestor's space; motion math shared with
	Motion Preview via PreSimulateAttachmentForward.
]]

local GraphMod = require(script.Parent.Graph)
local RangeMod = require(script.Parent.Range)
local AxisLinksMod = require(script.Parent.AxisLinks)
local ParticlesMod = require(script.Parent.Particles)
local Constants = require(script.Parent.PartConstants)
local Pool = require(script.Parent.Pool)
local NestedEmit = require(script.Parent.NestedEmit)
local StaticPass = require(script.Parent.StaticPass)
local LinkCF = require(script.Parent.LinkCF)
local Turbulence = require(script.Parent.Turbulence)
local VisualHost = require(script.Parent.VisualHost)
local DirectionVectors = Constants.DirectionVectors

-- Walk up the parent chain to find the nearest BasePart. Attachment nested inside
-- Attachment(s) must compose through ancestors; we anchor the visual to the first
-- BasePart so its parent-local CFrame math behaves consistently with sibling-emit types.
local function _findBasePartAncestor(inst)
	local p = inst.Parent
	while p do
		if p:IsA("BasePart") then return p end
		p = p.Parent
	end
	return nil
end

return function(Particle)

-- Attachment variant  -  sim runs in parent-BasePart-local space. DirMode 3-way split:
-- Local = post-RotXYZ; Global = world axis rebased; RigidLocal = pre-RotXYZ.
function Particle:EmitAttachment(attachment, link, emitCtx)
	if not attachment or not attachment.Parent then return end
	local data = self:GetEmitData(attachment, emitCtx)
	if not data or not data.RenderTemplate then return end
	if emitCtx and emitCtx.IgnoreLink then
		link = nil
	else
		link = link or data.Link
	end

	local Time = RangeMod.RandomValueFromRange(data.Lifetime)
	if Time <= 0 then Time = 0.001 end

	-- Source world pose composes the full chain (Attachment-in-Attachment-in-BasePart).
	-- WorldCFrame is the only correct read when parent is non-BasePart; .CFrame alone
	-- yields parent-local relative to a non-BasePart frame that breaks compose math.
	local sourceWorldCF = attachment.WorldCFrame
	local spawnAxes = LinkCF.spawnAxes(data, emitCtx)
	local worldCF
	local originOverrideCF
	if emitCtx then
		if emitCtx.EventOriginResolver then originOverrideCF = emitCtx.EventOriginResolver() end
		if not originOverrideCF then originOverrideCF = emitCtx.EventOriginCF end
	end
	if originOverrideCF then
		if emitCtx and emitCtx.UseFullOrigin then
			worldCF = originOverrideCF -- AtCFrame: full source orientation
		else
			worldCF = CFrame.new(originOverrideCF.Position) * sourceWorldCF.Rotation
		end
	elseif link then
		worldCF = LinkCF.spawnFrame(data.LinkMode, link, attachment, sourceWorldCF, emitCtx and emitCtx._linkLocal, emitCtx and emitCtx._sourceParentCF, spawnAxes)
	else
		worldCF = sourceWorldCF
	end
	-- Visual parent, in priority: EmitParent (user intent) > the parent clone's copy of the source's
	-- BasePart ancestor (nested) > a carrier mirroring the source's BasePart ancestor (top-level, keeps
	-- parent-relative motion without parenting into the user's part) > the live folder.
	-- All downstream local-space math runs in actualParent-local.
	local actualParent = data.EmitParent or NestedEmit.resolveCloneParent(attachment, link, emitCtx)
	local carrier = nil
	if not actualParent then
		local anchor = _findBasePartAncestor(attachment)
		if anchor then
			carrier = VisualHost.acquireCarrier(anchor)
			actualParent = carrier
		else
			actualParent = self:GetFolder()
		end
	end
	local actualParentCF = (actualParent and actualParent:IsA("BasePart")) and actualParent.CFrame or CFrame.new()
	local localCF = actualParentCF:ToObjectSpace(worldCF)
	local dirInfo = DirectionVectors[data.EmissionDirection] or DirectionVectors[Enum.NormalId.Top]

	-- Initial rotation (always applied)
	local dirMode = data.DirMode or "RigidLocal"
	local rotS = AxisLinksMod.sampleRangeAxes(data, data.AxisLinks, {"RotX","RotY","RotZ"}, RangeMod, emitCtx)
	local RX, RY, RZ = rotS.RotX, rotS.RotY, rotS.RotZ
	-- Initial RotX/Y/Z compose through RotOrder; see EmitPart for the rationale.
	local rotXYZ = Constants.composeRotation(data.RotOrder or "Global", RX, RY, RZ)
	local rotatedLocalCF = localCF * rotXYZ

	-- Base direction (3-way: Local / RigidLocal / Global). Sim frame is parent-local.
	local baseDirection
	if dirMode == "Local" then
		baseDirection = rotatedLocalCF[dirInfo.vector] * dirInfo.multiplier
	elseif dirMode == "Global" then
		-- World-space axis converted to actualParent-local (handles nested-Attachment via
		-- the BasePart anchor we walked up to). Folder-anchored fallback stays world-space.
		local worldAxis = CFrame.new()[dirInfo.vector] * dirInfo.multiplier
		if actualParent and actualParent:IsA("BasePart") then
			baseDirection = actualParent.CFrame:VectorToObjectSpace(worldAxis)
		else
			baseDirection = worldAxis
		end
	else -- RigidLocal: pre-RotXYZ pose in actualParent-local
		baseDirection = localCF[dirInfo.vector] * dirInfo.multiplier
	end

	localCF = rotatedLocalCF

	-- simFrameCF = actualParentCF so applyPositionOffset converts world offset into
	-- actualParent-local space (matches our sim frame after the BasePart walk-up).
	-- posScale: scale the spawn Pos spread by the parent Model's scale at this emit moment.
	local posScale = 1
	local psInfo = emitCtx and emitCtx.ParentScale
	if psInfo and psInfo.ScaleMotion ~= false then
		posScale = Constants.getParentScaleFactor(psInfo, os.clock(), GraphMod)
	end
	localCF = Constants.applyPositionOffset(localCF, data, link, attachment, RangeMod, AxisLinksMod, emitCtx, actualParentCF, posScale)

	-- Global: apply inv(actualParent.Rotation) so parent cancels at engine-multiply,
	-- leaving rotXYZ alone. Uses actualParent (BasePart anchor) so nested-Attachment
	-- sources don't fall to identity here.
	if dirMode == "Global" then
		if actualParent and actualParent:IsA("BasePart") then
			localCF = CFrame.new(localCF.Position) * actualParent.CFrame.Rotation:Inverse() * rotXYZ
		else
			localCF = CFrame.new(localCF.Position) * rotXYZ
		end
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
		Speed = GraphMod.GenerateSeed(data.Speed),
		RotSpeedX = GraphMod.GenerateSeed(data.RotSpeedX),
		RotSpeedY = GraphMod.GenerateSeed(data.RotSpeedY),
		RotSpeedZ = GraphMod.GenerateSeed(data.RotSpeedZ),
		PosOffsetX = GraphMod.GenerateSeed(data.PosOffsetX),
		PosOffsetY = GraphMod.GenerateSeed(data.PosOffsetY),
		PosOffsetZ = GraphMod.GenerateSeed(data.PosOffsetZ),
		Timescale = GraphMod.GenerateSeed(data.Timescale),
	}
	-- Aliases: RotSpeed only (no Size on Attachments).
	AxisLinksMod.applyGraphAxisAliases(data, seeds, data.AxisLinks)

	local invertMotion = data.InvertMotion
	local simLocalCFrames = nil
	local simEffectiveTKF = nil

	if invertMotion then
		simLocalCFrames, simEffectiveTKF = self:PreSimulateAttachmentForward(data, seeds, localCF, baseDirection, spreadRotation, Time, nil, localCF.Rotation * rotXYZ:Inverse())
	end

	local visualAttachment = Pool.acquireOrCopyBare(data.RenderTemplate, "Attachment", data.Pool)
	visualAttachment.Archivable = false

	if invertMotion and simLocalCFrames then
		local endLocalCF = simLocalCFrames[simEffectiveTKF or data.TotalKeyFrames] or simLocalCFrames[0]
		localCF = endLocalCF
	end

	-- actualParent + actualParentCF computed earlier (before sim) so PreSimulate
	-- and rotation/shape compose operate in the right frame.

	visualAttachment.CFrame = localCF
	visualAttachment.Parent = actualParent
	-- Sibling Beams / Trails bind their ends to this visual: transformed ones when they emit
	-- (NestedEmit fires Attachment leaves first), stock ones in the parent copy right here
	-- (Pool.registerEmitted).
	if emitCtx and emitCtx._parentCloneMap then Pool.registerEmitted(emitCtx._parentCloneMap, attachment, visualAttachment) end

	-- Restore nested-Trail Enabled snapshot after Parent so they track from spawn pose.
	-- Mirrors the Part path at line ~273.
	Pool.restoreTrails(visualAttachment, "Attachment")

	-- pData.LocalCF in parentCF_now-local space (link path) or actualParent-local (unlinked).
	local pDataLocalCF = localCF
	if link then
		pDataLocalCF = LinkCF.emitAttachmentParentFrame(data.LinkMode, link, actualParent, emitCtx and emitCtx._linkLocal, spawnAxes, sourceWorldCF):ToObjectSpace(localCF)
	end

	-- RigidLocal: snapshot link's WORLD CFrame at emit. Per-frame Attachment Link
	-- consumers convert this to visualParent-local at sample time so a moving
	-- visualParent stays correct.
	local rigidLocalSnapshot = LinkCF.rigidWorldSnapshot(data.LinkMode, link, emitCtx and emitCtx._linkLocal, spawnAxes, sourceWorldCF)

	local pData = {
		Type = "Attachment",
		VisualPart = visualAttachment,
		_carrier = carrier,
		Link = link,
		LinkMode = data.LinkMode,
		LinkAxes = data.LinkAxes,
		_linkLocal = emitCtx and emitCtx._linkLocal or nil,
		_rigidLocalParentCF = rigidLocalSnapshot,
		Events = data.Events,

		StartTime = os.clock(),
		TotalKeyFrames = invertMotion and simEffectiveTKF or math.max(1, data.TotalKeyFrames),
		CurrentStep = 0,
		AccumulatedDT = 0,
		LifeTime = Time,
		PartLife = data.PartLife,
		LocalCF = pDataLocalCF,
		_localWorldCF = pDataLocalCF, -- seed for LinkTrack frame 0
		BaseDirection = baseDirection,
		_accelVel = Vector3.zero,
		SpeedMultiplier = 1,
		_spinRate = Vector3.zero,
		_spinAccumX = 0, _spinAccumY = 0, _spinAccumZ = 0,
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

		-- PosOffsetX/Y/Z trajectory graph state (see Part emit above for semantics).
		SpawnRotation = pDataLocalCF.Rotation,
		SpawnEmitterRotation = pDataLocalCF.Rotation * rotXYZ:Inverse(),
		DisplacementMode = data.DisplacementMode,
		-- Attachment has no Size; 1.0 fallback for the sleep point-velocity check.
		_sleepRadius = 1.0,
		_prevWorldOff = Vector3.zero,
		HasPosOffsetGraphs = data.PosOffsetX ~= nil or data.PosOffsetY ~= nil or data.PosOffsetZ ~= nil,

		NeedsFullIteration = data.VelocityVectored,
		NeedsRotAccum = (data.RotMode == "Speed") and not data.VelocityVectored,
		HasDrag = data.ParticleData.Drag ~= 0,
		HasAccel = data.ParticleData.Acceleration.Magnitude > 0,

		Graphs = {
			Speed = data.Speed,
			RotSpeedX = data.RotSpeedX, RotSpeedY = data.RotSpeedY, RotSpeedZ = data.RotSpeedZ,
			PosOffsetX = data.PosOffsetX, PosOffsetY = data.PosOffsetY, PosOffsetZ = data.PosOffsetZ,
			Timescale = data.Timescale,
		},
		Seeds = seeds,
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.Timescale, seeds.Timescale, Time),
	}

	-- 1-frame pop prevention for PosOffset (see EmitPart for semantics).
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

	pData._sourceItem = attachment
	Particle._seedTsOverride(pData, attachment)
	-- Nested-Model scale: attachment particles also read the parent's scale (motion/rotation).
	if emitCtx and emitCtx.ParentScale then
		pData.ParentScale = emitCtx.ParentScale
	end
	if data.Pool ~= false then pData._sourceRT, pData._poolKind = data.RenderTemplate, "Attachment" end
	-- Static-graph short-circuit: constant-valued graphs nil out + stamp pData._static<Name>.
	StaticPass.apply(pData)
	self:_applyEmitVisualPasses(pData)
	pData._nestedAlive = { true }
	self:_registerEmit(pData, emitCtx)

	for _, desc in visualAttachment:GetDescendants() do
		if desc:IsA("ParticleEmitter") then desc.Enabled = false end
	end
	local aliveAtt = self:_makeAliveCheck()
	for _, child in visualAttachment:GetChildren() do
		if child:IsA("Attachment") then ParticlesMod.EnableEmitChildrenAndRepeatForAttachments(child, aliveAtt) end
		ParticlesMod.EnableEmitSingle(child, aliveAtt)
	end

	-- Nested Part-Icles: source-walk; link = visualAttachment drives position.
	-- The inherited Model-scale chain node is forwarded to deeper nested particles.
	NestedEmit.walk(self, data.RenderTemplate, visualAttachment, pData._nestedAlive, emitCtx, pData.ParentScale)
end

end
