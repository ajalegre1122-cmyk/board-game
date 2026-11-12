--[[
	Rope Mixin  -  Emit + Animate + Update for verlet-chain ropes. The chain is
	pure kinematic simulation (VerletSim.luau) driving anchored segment Parts
	via BulkMoveTo  -  identical cost in edit and running games, no engine
	physics involved.

	Timescale: verlet is not time-reversible  -  freeze/reverse holds the pose
	(physDt = 0) while color/transparency graphs keep playing backwards. Same
	rule as Rocks' native path; consumer note lives at the UpdateRope header.

	The rig Model stamps _lightningBolt so EmitPointLight fans nested lights out
	per segment (PointLight.luau reads it)  -  glowing rope for free.
]]

local GraphMod = require(script.Parent.Graph)
local RangeMod = require(script.Parent.Range)
local Pool = require(script.Parent.Pool)
local NestedEmit = require(script.Parent.NestedEmit)
local ParticlesMod = require(script.Parent.Particles)
local TurbulenceMod = require(script.Parent.Turbulence)
local Constants = require(script.Parent.PartConstants)
local VerletSim = require(script.VerletSim)
local Anchors = require(script.Anchors)
local PDataBuilder = require(script.PDataBuilder)

local MAX_ROPE_SEGMENTS = 48
local FAR_CFRAME = CFrame.new(1e9, 1e9, 1e9)

-- Weak-keyed by rig Model so buffers survive pool release/acquire cycles.
local Rigs = setmetatable({}, { __mode = "k" })

return function(Particle)

-- Rope discriminator; shared by init.luau Emit dispatch + Lifecycle EmitAnimate dispatch.
function Particle._isRope(item)
	return item:IsA("BasePart") and item:GetAttribute("IsRope") == true
end

-- One segment part cloned from the RT. copyBare strips Transformed children
-- (nested source Part-Icles fire once per ROPE via NestedEmit.walk).
local function buildSegment(rt)
	local seg = Pool.copyBare(rt)
	seg.Anchored = true
	seg.CanCollide = false
	seg.CanQuery = false
	seg.CanTouch = false
	seg.Massless = true
	seg.Locked = true
	seg.Archivable = false
	local decal = seg:FindFirstChildWhichIsA("Decal") or seg:FindFirstChildWhichIsA("Texture")
	return seg, decal
end

local function segCapFor(data)
	return math.clamp(math.floor((data.SegmentCount and data.SegmentCount.Max or 12) + 0.5), 2, MAX_ROPE_SEGMENTS)
end

local function buildRig(data)
	local cap = segCapFor(data)
	local model = Instance.new("Model")
	model.Name = "Rope"
	model.Archivable = false
	-- Consumed by EmitPointLight: nested lights fan out per segment (PointLight.luau).
	model:SetAttribute("_lightningBolt", true)
	local rig = {
		segCap = cap,
		partCount = cap,
		parts = table.create(cap),
		decals = table.create(cap),
		segLen = table.create(cap),
		widthScale = table.create(cap),
		writeCFs = table.create(cap),
		posBuf = table.create(cap + 1),
		prevPosBuf = table.create(cap + 1),
	}
	for i = 1, cap do
		local seg, decal = buildSegment(data.RenderTemplate)
		seg.Name = "Seg" .. i
		seg.CFrame = FAR_CFRAME
		seg.Parent = model
		rig.parts[i] = seg
		rig.decals[i] = decal
		rig.segLen[i] = 0.05
		rig.widthScale[i] = 1
		rig.writeCFs[i] = FAR_CFRAME
	end
	Rigs[model] = rig
	return model, rig
end

-- Pool acquire with defensive rig re-check (foreign / layout-drifted models rebuild).
local function acquireRope(data)
	local expected = segCapFor(data)
	if data.Pool == true then
		local model = Pool.acquire(data.RenderTemplate, "Rope")
		if model then
			local rig = Rigs[model]
			if rig and rig.segCap == expected and rig.parts[1] and rig.parts[1].Parent == model then
				model:SetAttribute("_PartIcleEmit", true)
				return model, rig
			end
			pcall(function() model:Destroy() end)
		end
	end
	local model, rig = buildRig(data)
	model:SetAttribute("_PartIcleEmit", true)
	return model, rig
end

-- Step-gated visual write: transparency/color/brightness/thickness over every
-- segment + decal. Size.Z comes from segLen (stretch handled by writeSegments).
local function writeVisuals(pData, t)
	local graphs, seeds = pData.Graphs, pData.Seeds
	local trans = graphs.Transparency and GraphMod.QueryPointsWithTime(t, graphs.Transparency, seeds.Transparency) or 0
	if pData.SkipTransparency then trans = pData._curTrans or trans end
	local bright = graphs.Brightness and GraphMod.QueryPointsWithTime(t, graphs.Brightness, seeds.Brightness) or 1
	local color
	if graphs.Color and not pData.SkipColor then
		local c = GraphMod.QueryColorPointWithTime(t, graphs.Color)
		color = Color3.new(math.min(c.R * bright, 1), math.min(c.G * bright, 1), math.min(c.B * bright, 1))
	end
	local thick = graphs.Thickness and GraphMod.QueryPointsWithTime(t, graphs.Thickness, seeds.Thickness)
	local rig = pData._rig
	local thickChanged = thick and thick ~= pData._curThick
	if thick then pData._curThick = thick end
	pData._curTrans = trans
	for i = 1, rig.segCap do
		local seg = rig.parts[i]
		seg.Transparency = trans
		if color then seg.Color = color end
		local decal = rig.decals[i]
		if decal then
			decal.Transparency = trans
			if color then decal.Color3 = color end
		end
		if thickChanged then
			local w = math.max(0.05, thick * rig.widthScale[i])
			seg.Size = Vector3.new(w, w, rig.segLen[i])
		end
	end
end

-- Point buffers → segment CFrames + lengths. Size.Z tracks the ACTUAL point
-- distance so a stretched rope never shows gaps. atEmit writes CFrames direct
-- (model unparented; BulkMoveTo needs workspace ancestry).
local function writeSegments(pData, atEmit)
	local rig = pData._rig
	local pos = rig.posBuf
	local n = pData._segCount
	local thick = pData._curThick or 0.15
	for i = 1, n do
		local p0 = pos[i]
		local p1 = pos[i + 1]
		local seg = p1 - p0
		local len = seg.Magnitude
		local mid = (p0 + p1) * 0.5
		if len > 1e-4 then
			rig.writeCFs[i] = CFrame.lookAt(mid, p1)
		else
			rig.writeCFs[i] = CFrame.new(mid)
		end
		if math.abs(len - rig.segLen[i]) > 0.01 then
			rig.segLen[i] = math.max(len, 0.05)
			local w = math.max(0.05, thick * rig.widthScale[i])
			rig.parts[i].Size = Vector3.new(w, w, rig.segLen[i])
		end
	end
	for i = n + 1, rig.segCap do
		rig.writeCFs[i] = FAR_CFRAME
	end
	if atEmit then
		for i = 1, rig.segCap do
			rig.parts[i].CFrame = rig.writeCFs[i]
		end
	else
		workspace:BulkMoveTo(rig.parts, rig.writeCFs, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- Spawn one rope.
function Particle:EmitRope(item, link, emitCtx)
	if not item or not item.Parent then return end
	local data = self:GetEmitData(item, emitCtx)
	if not data or not data.RenderTemplate then return end

	local lifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	if lifeTime <= 0 then lifeTime = 0.001 end

	local model, rig = acquireRope(data)
	local pData = PDataBuilder.build(item, data, model, rig, lifeTime, emitCtx, link)

	Particle._seedTsOverride(pData, item)
	if data.Pool == true then
		pData._sourceRT, pData._poolKind = data.RenderTemplate, "Rope"
	end

	Anchors.seedPose(pData)
	pData._curThick = data.Thickness and GraphMod.QueryPointsWithTime(0, data.Thickness, pData.Seeds.Thickness) or 0.15
	writeSegments(pData, true)
	writeVisuals(pData, 0)
	model.Parent = data.EmitParent or self:GetFolder()
	Pool.restoreTrails(model, "Rope")
	ParticlesMod.EnableEmit(model, self:_makeAliveCheck())

	pData._nestedAlive = { true }
	self:_registerEmit(pData, emitCtx)
	NestedEmit.walk(self, data.RenderTemplate, model, pData._nestedAlive, emitCtx)
end

-- Animate mode: singleton persistent rope per source (fresh rig, never pooled).
function Particle:EmitRopeAnimate(item, link, emitCtx)
	if not item or not item.Parent then return end
	if self.ActiveAnimates[item] then return end
	local data = self:GetEmitData(item, emitCtx)
	if not data or not data.RenderTemplate then return end

	local lifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	if lifeTime <= 0 then lifeTime = 0.001 end

	local model, rig = buildRig(data)
	model:SetAttribute("_PartIcleEmit", true)
	local pData = PDataBuilder.build(item, data, model, rig, lifeTime, emitCtx, link)
	pData.IsAnimate = true
	pData.AnimateItem = item

	Particle._seedTsOverride(pData, item)
	Anchors.seedPose(pData)
	pData._curThick = data.Thickness and GraphMod.QueryPointsWithTime(0, data.Thickness, pData.Seeds.Thickness) or 0.15
	writeSegments(pData, true)
	writeVisuals(pData, 0)
	model.Parent = data.EmitParent or self:GetFolder()
	ParticlesMod.EnableEmit(model, self:_makeAliveCheck())

	pData._nestedAlive = { true }
	self.ActiveAnimates[item] = pData
	self:_registerEmit(pData, emitCtx)
	NestedEmit.walk(self, data.RenderTemplate, model, pData._nestedAlive, emitCtx)
end

-- Per-frame update: fixed-substep verlet with anchors re-pinned every substep.
-- Reverse Timescale: the chain simulates FORWARD while all authored inputs
-- (anchors, graphs, Speed drift, Launch arc) rewind; Timescale 0 freezes.
function Particle:UpdateRope(pData, dt, currentTime)
	-- Signed-reverse timescale header: see Lightning/init.luau UpdateLightning.
	local real_i = math.min(math.max((currentTime - pData.StartTime) / pData.LifeTime, 0), 1)
	local ts
	if pData._tsOverride ~= nil and currentTime < (pData._tsOverrideUntil or 0) then
		ts = pData._tsOverride
	else
		ts = pData.Graphs.Timescale and GraphMod.QueryPointsWithTime(real_i, pData.Graphs.Timescale, pData.Seeds.Timescale) or 1
	end
	local dtTs = dt * ts
	local lifeTime = pData.LifeTime
	local prevEff = pData._effectiveElapsed or 0
	local newEff = prevEff + (pData._timeFrozen and 0 or dtTs)
	if newEff < 0 then newEff = 0 end
	if newEff > lifeTime then newEff = lifeTime end
	pData._effectiveElapsed = newEff

	local model = pData.VisualPart
	if not model or not model.Parent then return true end
	if pData.TotalKeyFrames <= 0 then return true end
	local isDying = real_i >= 1 and (newEff >= lifeTime or newEff <= 0)

	if not isDying then
		-- Reverse Timescale: the chain SIMULATES FORWARD (verlet isn't time-
		-- reversible) while every authored input rewinds — anchors, Displacement
		-- graphs, Turbulence, Speed drift (signed), the Launch arc. The rope
		-- physically reacts to its inputs playing backwards. Timescale 0 /
		-- freeze stops everything.
		local frozen = pData._timeFrozen == true
		local simDt = frozen and 0 or math.min(math.abs(dtTs), 0.25)
		-- Signed accumulation uses the CLAMPED effective-time delta: once the
		-- clock pins at 0 (or LifeTime) the drift stops instead of over-running.
		local motionDt = math.clamp(newEff - prevEff, -0.25, 0.25)
		local physDtEarly = simDt
		local li = math.min(math.max(newEff / lifeTime, 0), 1)
		-- Lifecycle length: GrowIn pays out over the first window, Retract reels
		-- back over the death window, Release drops every pin once.
		local lenFactor = 1
		if pData._growIn > 0 and li < pData._growIn then
			lenFactor = math.max(li / pData._growIn, 0.02)
		end
		if pData._deathMode == "Retract" then
			local deathStart = 1 - pData._deathWindow
			if li > deathStart then
				lenFactor = lenFactor * math.max(1 - (li - deathStart) / pData._deathWindow, 0.02)
			end
		elseif pData._deathMode == "Release" and not pData._released and li > 1 - pData._deathWindow then
			pData._released = true
			pData._pinStart = false
			pData._pinEnd = false
		end
		pData._restLenEff = pData._restLen * lenFactor

		-- Signed accumulation: reverse Timescale un-winds the Speed/Accel drift.
		if pData._hasMotion and motionDt ~= 0 then
			local sp = pData.Graphs.Speed and GraphMod.QueryPointsWithTime(li, pData.Graphs.Speed, pData.Seeds.Speed) or 0
			if pData._drag ~= 0 then sp = sp * math.exp(-pData._drag * newEff) end
			pData._motionAccelVel = pData._motionAccelVel + pData._accel * motionDt
			pData._motionOffset = pData._motionOffset
				+ (pData._speedDir or pData._motionDir) * (sp * motionDt)
				+ pData._motionAccelVel * motionDt
		end
		if pData._hasDisp or pData._hasTurb or pData._hasMotion then
			local off = Vector3.zero
			if pData._hasDisp then
				local graphs, seeds = pData.Graphs, pData.Seeds
				off = Vector3.new(
					graphs.PosOffsetX and GraphMod.QueryPointsWithTime(li, graphs.PosOffsetX, seeds.PosOffsetX) or 0,
					graphs.PosOffsetY and GraphMod.QueryPointsWithTime(li, graphs.PosOffsetY, seeds.PosOffsetY) or 0,
					graphs.PosOffsetZ and GraphMod.QueryPointsWithTime(li, graphs.PosOffsetZ, seeds.PosOffsetZ) or 0)
			end
			if pData._hasTurb then
				off = off + TurbulenceMod.sampleRaw(pData.Graphs.Turbulence, pData.Seeds.Turbulence,
					pData._turbSeed, pData._turbFreq, lifeTime, li)
			end
			if pData._dispMode ~= "Global" then
				off = Anchors.resolveStart(pData).Rotation:VectorToWorldSpace(off)
			end
			if pData._hasMotion then
				off = off + pData._motionOffset
			end
			pData._anchorOffWorld = off
		else
			pData._anchorOffWorld = nil
		end
		if pData._pinMode == "Launch" then
			-- The hook BITES once (latch is permanent — reverse Timescale rewinds
			-- only pre-bite flight, and AnimateLoop cycles keep the bite):
			-- aimed = live target on arrival; blind = the world point where the
			-- rope first went taut (source then swings from it — ODM gear).
			if pData._launchArrived then
				if pData._launchT then
					local target = pData._target
					if target and target.Parent then
						pData._launchPos = Constants.resolveLinkCFrame(target).Position
					end
				end
			elseif pData._launchT and newEff >= pData._launchT then
				pData._launchArrived = true
				local target = pData._target
				if target and target.Parent then
					pData._launchPos = Constants.resolveLinkCFrame(target).Position
				end
			else
				local delta = pData._launchVel * newEff + pData._gravity * (0.5 * newEff * newEff)
				if not pData._launchT then
					local maxLen = pData._restLen * pData._segCount
					if delta.Magnitude >= maxLen then
						delta = delta.Unit * maxLen
						pData._launchArrived = true
					end
				end
				pData._launchPos = pData._launchOrigin + delta
			end
		end

		local physDt = physDtEarly
		if physDt > 1e-6 then
			pData._windPhase = pData._windPhase + pData._windFreq * physDt
			local rig = pData._rig
			-- Slow Timescale SHRINKS the substep (smooth slow motion, one step
			-- per frame) instead of thinning the cadence, which would play
			-- full-speed steps rarely — a stutter that reads as "timescale
			-- ignored". Fast Timescale keeps 1/60 steps and adds more of them.
			-- VerletSim's time-corrected velocity handles the changing h.
			local h = math.min(physDt, VerletSim.SUBSTEP)
			local accum = pData._accum + physDt
			local steps = 0
			while accum >= h and steps < VerletSim.MAX_SUBSTEPS do
				Anchors.repin(pData)
				VerletSim.step(rig.posBuf, rig.prevPosBuf, pData._segCount, pData, h, pData._windPhase)
				accum -= h
				steps += 1
			end
			-- Drop excess at the cap: a hitch slows the rope, never explodes it.
			pData._accum = steps == VerletSim.MAX_SUBSTEPS and 0 or accum
			Anchors.repin(pData)
			writeSegments(pData, false)
		end
	end

	local targetStep = math.floor(math.min(math.max(newEff / lifeTime, 0), 1) * pData.TotalKeyFrames)
	if targetStep ~= pData.CurrentStep then
		pData.CurrentStep = targetStep
		writeVisuals(pData, targetStep / pData.TotalKeyFrames)
	end

	return isDying
end

-- AnimateLoop per-cycle refresh (EngineReplay dispatch). POSE-PRESERVING: the
-- point buffers survive when the chain layout (segCount + restLen) is
-- unchanged, so a looping rope never pops; layout change = full re-seed.
function Particle:_refreshRopeAnimate(pData, freshData)
	-- Generic replay assigns pData.Link from freshData; Rope resolves anchors itself.
	pData.Link = nil
	local oldSeg = pData._segCount
	local oldRest = pData._restLen

	local expected = segCapFor(freshData)
	local rebuilt = false
	if expected ~= pData._rig.segCap and freshData.RenderTemplate then
		local oldModel = pData.VisualPart
		local parent = oldModel and oldModel.Parent
		local model, rig = buildRig(freshData)
		model:SetAttribute("_PartIcleEmit", true)
		pData.VisualPart = model
		pData._rig = rig
		model.Parent = parent or self:GetFolder()
		if oldModel then pcall(function() oldModel:Destroy() end) end
		rebuilt = true
	end

	PDataBuilder.readRopeParams(pData, freshData, pData._rig)
	if rebuilt then pcall(function() pData.VisualPart.WorldPivot = Anchors.resolveStart(pData) end) end
	pData._accum = 0
	pData._released = false
	pData.SkipColor = nil

	-- Launch is pose-preserving too: a bitten hook stays bitten across cycles
	-- (persistent grapple / ODM); per-cast re-throws come from Emit mode. The
	-- latch (_launchArrived / _launchPos) deliberately survives the refresh.
	if rebuilt or pData._segCount ~= oldSeg or math.abs((pData._restLen or 0) - (oldRest or 0)) > 1e-4 then
		Anchors.seedPose(pData)
		pData._launchArrived = false
		pData._launchPos = nil
	end
	pData._curThick = freshData.Thickness and GraphMod.QueryPointsWithTime(0, freshData.Thickness, pData.Seeds.Thickness) or pData._curThick
	writeSegments(pData, false)
	writeVisuals(pData, 0)
end

end
