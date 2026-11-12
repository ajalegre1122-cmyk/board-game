--[[
	Lightning Mixin  -  Emit + Animate + Update for procedural part-based lightning bolts.

	Visual = Model of up to MAX_BOLT_PARTS segment parts cloned from the RenderTemplate
	(the user's styled template part). Geometry rolls via BoltGen midpoint displacement
	at JitterRate Hz; per-frame work is transparency/color stepping + tip-extension
	reveal only. All roll buffers live on a per-model "rig" (weak-keyed) so pooled
	reuse allocates nothing.

	Endpoint modes: "Point" (bolt arcs from source to the Target ObjectValue instance,
	re-resolved live every roll) and "Directional" (EmissionDirection ± SpreadAngle for
	Length studs, rolled per emit). GrowthSpeed > 0 reveals segments in arc order.

	Animate mode is clone-animate (like Screen types): a singleton persistent bolt per
	source; the source RT is never mutated, so cancel just destroys the clone.
]]

local GraphMod = require(script.Parent.Graph)
local RangeMod = require(script.Parent.Range)
local Pool = require(script.Parent.Pool)
local Constants = require(script.Parent.PartConstants)
local AxisLinksMod = require(script.Parent.AxisLinks)
local NestedEmit = require(script.Parent.NestedEmit)
local ParticlesMod = require(script.Parent.Particles)
local TurbulenceMod = require(script.Parent.Turbulence)
local EventsMod = require(script.Parent.Events)
local BoltGen = require(script.BoltGen)

local DirectionVectors = Constants.DirectionVectors

-- Rig construction + pool acquire live in Lightning/Rig (500-line cap split);
-- it owns the weak-keyed Rigs map.
local RigMod = require(script.Rig)
local buildRig = RigMod.buildRig
local acquireBolt = RigMod.acquireBolt
local layoutFor = RigMod.layoutFor
local flushCFrames = RigMod.flushCFrames
local FAR_CFRAME = RigMod.FAR_CFRAME

-- Per-frame roll budget (Heartbeat-scoped module state). Engages only under
-- frame pressure so steady scenes stay bit-identical; during a hitch it caps
-- FRESH geometry rolls per frame, deferring the rest one frame via
-- pData._rollPending (bypasses the cap on landing — no starvation).
local ROLL_BUDGET = 8
local PRESSURE_ON = 1 / 40
local PRESSURE_OFF = 1 / 55
local _frameStamp = -1
local _rollsUsed = 0
local _budgetActive = false
local _calmFrames = 0

return function(Particle)

-- Lightning discriminator; shared by init.luau Emit dispatch + Lifecycle EmitAnimate dispatch.
function Particle._isLightning(item)
	return item:IsA("BasePart") and item:GetAttribute("IsLightning") == true
end

-- Spawn-shape sampling + live endpoint resolution live in Lightning/Endpoints
-- (500-line cap split).
local EndpointsMod = require(script.Endpoints)
local ImpactDisk = require(script.ImpactDisk)
local sampleShape = EndpointsMod.sampleShape
local resolveEndpoints = EndpointsMod.resolveEndpoints

-- Flush planned Size writes. BoltGen.planSizes decides which LIVE parts actually
-- changed (exact compares; parked slots skip). Every Size write path must route
-- through here or the plan caches lie.
local function writeSizes(rig, thick, force)
	local writes = BoltGen.planSizes(rig, thick, force)
	for k = 1, writes do
		local i = rig.sizeWriteIdx[k]
		local w = math.max(0.05, thick * rig.widthScale[i] * rig.taper[i])
		rig.parts[i].Size = Vector3.new(w, w, rig.segLen[i])
	end
end

-- One geometry roll: endpoints → BoltGen → scroll overlay → Size writes → flush.
local function applyRoll(pData, atEmit)
	local rig = pData._rig
	local startCF, startPos, endPos = resolveEndpoints(pData)
	pData._totalLen = BoltGen.roll(rig, pData, startPos, endPos, FAR_CFRAME)
	if pData._shapeMode ~= "Jitter" then
		BoltGen.applyScroll(rig, pData, pData._scrollPhase or 0)
		BoltGen.applyScrollForks(rig, pData, pData._scrollPhase or 0)
	end
	RigMod.applyTaper(rig, pData.Graphs.ThicknessProfile, pData.Seeds.ThicknessProfile, pData._totalLen)
	-- Parked→live transitions re-apply cached visuals (stale from before the slot
	-- parked). Skipped at emit: writeVisuals(0) follows and covers every live part.
	-- Gradient colors are handled by the roll-time gradient loop below.
	local newlyLive = BoltGen.diffLive(rig)
	local gradient = pData.Graphs.Gradient
	if not atEmit and newlyLive > 0 then
		local trans = pData._curTrans
		local color = not gradient and pData._curColor or nil
		for k = 1, newlyLive do
			local idx = rig.newlyLiveIdx[k]
			local seg = rig.parts[idx]
			if trans then seg.Transparency = trans end
			if color then seg.Color = color end
			local decal = rig.decals[idx]
			if decal then
				if trans then decal.Transparency = trans end
				if color then decal.Color3 = color end
			end
		end
	end
	-- Spatial Gradient: sample per live part at its arc position and apply the
	-- composed color NOW. Roll-time application is required — with a static
	-- temporal Color, writeVisuals runs once at step 0, so re-rolled arcs and
	-- revived fork slots would otherwise keep stale colors forever.
	if gradient and not pData.SkipColor then
		local invReveal = 1 / math.max(rig.maxReveal or 0, 1e-4)
		local tint = pData._curTint
		for i = 1, rig.partCount do
			if rig.prevLive[i] then
				local arcFrac = math.clamp((rig.revealDist[i] + rig.segLen[i] * 0.5) * invReveal, 0, 1)
				local g = GraphMod.QueryColorPointWithTime(arcFrac, gradient)
				rig.gradColor[i] = g
				if not atEmit then
					local c = tint
						and Color3.new(math.min(g.R * tint.R, 1), math.min(g.G * tint.G, 1), math.min(g.B * tint.B, 1))
						or g
					rig.parts[i].Color = c
					local decal = rig.decals[i]
					if decal then decal.Color3 = c end
				end
			end
		end
	end
	writeSizes(rig, pData._curThick or 0.15, atEmit)
	pcall(function() pData.VisualPart.WorldPivot = CFrame.new(startPos) * startCF.Rotation end)
	flushCFrames(pData, atEmit)
	if pData._impactDisk then ImpactDisk.place(pData, startPos, endPos) end
end

-- Step-gated visual write: sample graphs at stepped t, cache scalars, batch-apply.
-- Parked slots (prevLive false) skip: they sit at FAR_CFRAME and applyRoll
-- re-applies the caches when a slot revives.
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
	pData._curBright = bright
	if color then
		pData._curColor = color
		-- Tint cache for the roll-time Gradient compose (applyRoll).
		pData._curTint = color
	end
	local gradient = graphs.Gradient
	for i = 1, rig.partCount do
		if rig.prevLive[i] then
			local seg = rig.parts[i]
			seg.Transparency = trans
			local decal = rig.decals[i]
			if decal then decal.Transparency = trans end
			if color then
				local c = color
				if gradient then
					local g = rig.gradColor[i]
					if g then
						c = Color3.new(math.min(g.R * color.R, 1), math.min(g.G * color.G, 1), math.min(g.B * color.B, 1))
					end
				end
				seg.Color = c
				if decal then decal.Color3 = c end
			end
		end
	end
	if thickChanged then
		writeSizes(rig, thick, false)
	end
	if pData._impactDisk then ImpactDisk.write(pData, t) end
end

-- Per-bolt pData construction lives in Lightning/PDataBuilder (500-line cap split).
local PDataBuilder = require(script.PDataBuilder)
local buildPData = PDataBuilder.build

-- Seek-mode raycast params: OnHit cfg filters + both engine folders excluded by
-- ancestry + RespectCanCollide (Rocks buildRockParams pattern).
local function buildSeekParams(self, pData)
	if pData._endpointMode ~= "Seek" then return end
	local p = EventsMod.makeHitParams(pData)
	p.RespectCanCollide = true
	pcall(function()
		p:AddToFilter(self:GetFolder())
		p:AddToFilter(self:GetPoolFolder())
	end)
	pData._seekRayFn = function(origin, disp)
		return workspace:Raycast(origin, disp, p)
	end
end

-- OnHit per strike-point acquisition (emit + each retarget), Seek mode only.
-- Payload carries the seek raycast's real hit; the global per-frame event
-- budget (Events.reserveFrameFire) guards retarget spam.
local function fireSeekHit(self, pData)
	if not pData._seekNewHit then return end
	-- Glide (RetargetSpeed > 0) holds the fire until the strike point arrives.
	if not EndpointsMod.glideArrived(pData) then return end
	pData._seekNewHit = nil
	if not (pData.Events and pData.Events.OnHit and pData._seekHit) then return end
	local hit = pData._seekHit
	local payload = EventsMod.makePayload(self, pData, "OnHit", nil)
	payload.HitInstance = hit.Instance
	payload.Other = hit.Instance
	payload.HitPosition = hit.Position
	payload.HitNormal = hit.Normal
	EventsMod.fire(self, pData, "OnHit", pData.EventChainCtx, payload)
end

-- Spawn one bolt clone.
function Particle:EmitLightning(item, link, emitCtx)
	if not item or not item.Parent then return end
	local data = self:GetEmitData(item, emitCtx)
	if not data or not data.RenderTemplate then return end

	local lifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	if lifeTime <= 0 then lifeTime = 0.001 end

	local model, rig = acquireBolt(data)
	local pData = buildPData(item, data, model, rig, lifeTime, emitCtx)
	-- Nested emit: link = the emitted parent clone; resolveEndpoints prefers its
	-- LIVE CFrame so the bolt origin rides the moving particle. nil for top-level.
	pData._parentLink = link

	-- Event origin override (EnableEmitAt / Events AtPosition chains): freeze the
	-- resolved origin as the bolt start for its whole life.
	if emitCtx then
		local originCF
		if emitCtx.EventOriginResolver then originCF = emitCtx.EventOriginResolver() end
		originCF = originCF or emitCtx.EventOriginCF
		if originCF then
			pData._startCFOverride = (emitCtx.UseFullOrigin and originCF)
				or CFrame.new(originCF.Position) * item.CFrame.Rotation
		end
	end

	Particle._seedTsOverride(pData, item)
	if data.Pool ~= false then
		pData._sourceRT, pData._poolKind = data.RenderTemplate, "Lightning"
	end

	-- Frame-0: thickness seed, geometry roll (pre-parent → direct CFrame writes), visuals.
	pData._curThick = data.Thickness and GraphMod.QueryPointsWithTime(0, data.Thickness, pData.Seeds.Thickness) or 0.15
	buildSeekParams(self, pData)
	-- Emit rolls never defer (the bolt must appear this frame) but count
	-- against the frame budget.
	_rollsUsed += 1
	applyRoll(pData, true)
	writeVisuals(pData, 0)

	model.Parent = data.EmitParent or self:GetFolder()
	ImpactDisk.attach(self, pData, data)
	Pool.restoreTrails(model, "Lightning")
	ParticlesMod.EnableEmit(model, self:_makeAliveCheck())

	self:_registerEmit(pData, emitCtx)
	NestedEmit.walk(self, data.RenderTemplate, model, pData._nestedAlive, emitCtx)
	fireSeekHit(self, pData)
end

-- Animate mode: singleton persistent bolt per source (clone-animate; source RT untouched).
function Particle:EmitLightningAnimate(item, link, emitCtx)
	if not item or not item.Parent then return end
	if self.ActiveAnimates[item] then return end
	local data = self:GetEmitData(item, emitCtx)
	if not data or not data.RenderTemplate then return end

	local lifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	if lifeTime <= 0 then lifeTime = 0.001 end

	local model, rig = buildRig(data)
	model:SetAttribute("_PartIcleEmit", true)
	local pData = buildPData(item, data, model, rig, lifeTime, emitCtx)
	pData._parentLink = link
	pData.IsAnimate = true
	pData.AnimateItem = item

	Particle._seedTsOverride(pData, item)
	pData._curThick = data.Thickness and GraphMod.QueryPointsWithTime(0, data.Thickness, pData.Seeds.Thickness) or 0.15
	buildSeekParams(self, pData)
	-- Emit rolls never defer (the bolt must appear this frame) but count
	-- against the frame budget.
	_rollsUsed += 1
	applyRoll(pData, true)
	writeVisuals(pData, 0)

	model.Parent = data.EmitParent or self:GetFolder()
	ImpactDisk.attach(self, pData, data)
	ParticlesMod.EnableEmit(model, self:_makeAliveCheck())

	self.ActiveAnimates[item] = pData
	self:_registerEmit(pData, emitCtx)
	NestedEmit.walk(self, data.RenderTemplate, model, pData._nestedAlive, emitCtx)
	fireSeekHit(self, pData)
end

-- Per-frame Heartbeat update. Idle frame cost = time header + three comparisons;
-- zero allocation (roll-time writes go into pre-sized rig buffers).
function Particle:UpdateLightning(pData, dt, currentTime)
	-- Signed-reverse timescale header: see Highlight.luau UpdateHighlight.
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

	local rig = pData._rig

	-- Roll-budget frame bookkeeping: currentTime is shared by every particle in
	-- one Heartbeat step, so the first Lightning update of the frame resets the
	-- counter and re-evaluates the pressure gate (2-calm-frame hysteresis).
	if currentTime ~= _frameStamp then
		_frameStamp = currentTime
		_rollsUsed = 0
		if dt > PRESSURE_ON then
			_budgetActive = true
			_calmFrames = 0
		elseif _budgetActive then
			if dt < PRESSURE_OFF then
				_calmFrames += 1
				if _calmFrames >= 2 then
					_budgetActive = false
				end
			else
				_calmFrames = 0
			end
		end
	end

	-- Geometry work skipped on the death frame; the final keyframe write below still
	-- runs so a lingering bolt (PartLife) holds the end-of-graph look.
	if not isDying then
		-- Origin motion: Speed along the launch direction (drag-damped) + Acceleration
		-- drift, plus PosOffset displacement graphs. resolveEndpoints applies both at
		-- the next roll (JitterRate sets motion smoothness). Clamped effective-time
		-- delta, NOT raw dtTs: once the clock pins at 0 / LifeTime the signed drift
		-- stops instead of over-running (reverse Timescale past the start).
		local mdt = newEff - prevEff
		if pData._hasMotion and mdt ~= 0 then
			local li = math.min(math.max(newEff / lifeTime, 0), 1)
			local sp = pData.Graphs.Speed and GraphMod.QueryPointsWithTime(li, pData.Graphs.Speed, pData.Seeds.Speed) or 0
			if pData._drag ~= 0 then sp = sp * math.exp(-pData._drag * newEff) end
			pData._motionAccelVel = pData._motionAccelVel + pData._accel * mdt
			pData._motionOffset = pData._motionOffset
				+ (pData._lastDirWorld or Vector3.zero) * (sp * mdt)
				+ pData._motionAccelVel * mdt
		end
		if pData._hasDisp then
			local li = math.min(math.max(newEff / lifeTime, 0), 1)
			local ox = pData.Graphs.PosOffsetX and GraphMod.QueryPointsWithTime(li, pData.Graphs.PosOffsetX, pData.Seeds.PosOffsetX) or 0
			local oy = pData.Graphs.PosOffsetY and GraphMod.QueryPointsWithTime(li, pData.Graphs.PosOffsetY, pData.Seeds.PosOffsetY) or 0
			local oz = pData.Graphs.PosOffsetZ and GraphMod.QueryPointsWithTime(li, pData.Graphs.PosOffsetZ, pData.Seeds.PosOffsetZ) or 0
			pData._dispRaw = Vector3.new(ox, oy, oz)
		end
		if pData._hasTurb then
			local li = math.min(math.max(newEff / lifeTime, 0), 1)
			pData._turbRaw = TurbulenceMod.sampleRaw(pData.Graphs.Turbulence, pData.Seeds.Turbulence,
				pData._turbSeed, pData._turbFreq, lifeTime, li)
		end
		-- Pending roll deferred by the budget last frame: bypasses the cap (still
		-- counts) so worst case is one frame late — no starvation. A pending roll
		-- landing on a death frame is dropped silently (isDying skips geometry).
		if pData._rollPending and pData._rollPendingStamp ~= currentTime then
			pData._rollPending = nil
			pData._rollPendingStamp = nil
			pData._jitterAccum = 0
			_rollsUsed += 1
			applyRoll(pData, false)
			fireSeekHit(self, pData)
		end

		-- Seek glide: strike point advances toward the goal at RetargetSpeed studs/s.
		-- Jitter rolls pick the moved point up at JitterRate; a frozen-jitter bolt
		-- (rate 0) re-rolls itself here so the drag stays visible.
		if EndpointsMod.glideStep(pData, math.abs(mdt)) and pData._jitterInterval == math.huge then
			if _budgetActive and _rollsUsed >= ROLL_BUDGET then
				pData._rollPending = true
				pData._rollPendingStamp = currentTime
			else
				_rollsUsed += 1
				applyRoll(pData, false)
				fireSeekHit(self, pData)
			end
		end

		-- Jitter re-roll at JitterRate Hz. abs() so reversed time still flickers; a hitch
		-- rolls once, never queues a burst. Budget-deferred rolls keep the accumulator;
		-- the pending landing zeroes it.
		pData._jitterAccum += math.abs(dtTs)
		if pData._jitterAccum >= pData._jitterInterval and not pData._rollPending then
			if _budgetActive and _rollsUsed >= ROLL_BUDGET then
				pData._rollPending = true
				pData._rollPendingStamp = currentTime
			else
				pData._jitterAccum = 0
				_rollsUsed += 1
				applyRoll(pData, false)
				fireSeekHit(self, pData)
			end
		end

		-- Tip-extension reveal (GrowthSpeed). Effective-time-based → reversible.
		-- Scroll modes only advance _tipDist here (flushCFrames rebuilds the full
		-- mask every frame); reversed growth always full-rebuilds (<=64 comparisons).
		if pData._lSpeed ~= 0 then
			local tip = math.abs(pData._lSpeed) * newEff
			if tip ~= pData._tipDist then
				pData._tipDist = tip
				if pData._growReversed then
					if pData._shapeMode == "Jitter" then
						flushCFrames(pData, false)
					end
				elseif pData._shapeMode == "Jitter" then
					local order, rd, wcf, rcf = rig.revealOrder, rig.revealDist, rig.writeCFs, rig.rollCFs
					local ptr = pData._revealPtr
					local dirty = false
					while ptr < rig.partCount and rd[order[ptr + 1]] <= tip do
						ptr += 1
						local idx = order[ptr]
						wcf[idx] = rcf[idx]
						dirty = true
					end
					while ptr > 0 and rd[order[ptr]] > tip do
						local idx = order[ptr]
						wcf[idx] = FAR_CFRAME
						dirty = true
						ptr -= 1
					end
					pData._revealPtr = ptr
					if dirty then
						workspace:BulkMoveTo(rig.parts, rig.writeCFs, Enum.BulkMoveMode.FireCFrameChanged)
					end
				end
			end
		end

		-- Traveling Perlin wave (Scroll / JitterScroll): advance phase, recompute main
		-- segments, batch-flush. Signed + freeze-aware like the effective-time clock.
		if pData._shapeMode ~= "Jitter" then
			pData._scrollPhase += pData._scrollSpeed * (pData._timeFrozen and 0 or dtTs)
			BoltGen.applyScroll(rig, pData, pData._scrollPhase)
			BoltGen.applyScrollForks(rig, pData, pData._scrollPhase)
			-- Scroll never changes slot liveness (fork firing is roll-only), so no
			-- diffLive here; planSizes drops the writes for parked slots.
			writeSizes(rig, pData._curThick or 0.15, false)
			flushCFrames(pData, false)
		end
	end

	local targetStep = math.floor(math.min(math.max(newEff / lifeTime, 0), 1) * pData.TotalKeyFrames)
	if targetStep ~= pData.CurrentStep then
		pData.CurrentStep = targetStep
		writeVisuals(pData, targetStep / pData.TotalKeyFrames)
	end

	return isDying
end

-- AnimateLoop per-cycle refresh (Engine replay branch dispatch). Re-reads procedural
-- props, rerolls spread/length, resets growth + jitter; rebuilds the rig when a
-- SegmentCount / fork edit changed the part count.
function Particle:_refreshLightningAnimate(pData, freshData)
	-- Engine's generic replay assigns pData.Link from freshData. A bolt is never moved by
	-- LinkTrack: its origin rides _userLink through Endpoints, re-read here for the new cycle.
	pData.Link = nil
	pData._userLink = freshData.Link
	pData._originPivotRot = nil
	pData._originLinkCF = nil
	pData._endpointMode = freshData.TargetMode == "Seek" and "Seek"
		or ((freshData.TargetMode == "Point" and freshData.Target and freshData.Target.Parent) and "Point" or "Directional")
	pData._target = freshData.Target
	-- Seek: re-roll radius + drop the cached strike so each cycle re-acquires.
	pData._seekRadius = math.max(RangeMod.RandomValueFromRange(freshData.SeekRadius), 1)
	pData._seekRetarget = freshData.SeekRetarget == true
	pData._seekBias = math.clamp(freshData.SeekBias or 0, 0, 1)
	pData._retargetSpeed = math.max(freshData.RetargetSpeed or 0, 0)
	pData._seekHit = nil
	pData._seekFallbackDir = nil
	pData._seekNewHit = nil
	pData._seekCurrentPos = nil
	pData._seekGoalPos = nil
	buildSeekParams(self, pData)
	pData._length = math.max(0.1, RangeMod.RandomValueFromRange(freshData.Length))
	pData._amplitude = RangeMod.RandomValueFromRange(freshData.Amplitude)
	pData._decay = RangeMod.RandomValueFromRange(freshData.AmplitudeDecay)
	pData._forkChance = RangeMod.RandomValueFromRange(freshData.ForkChance)
	pData._forkDepth = math.floor(RangeMod.RandomValueFromRange(freshData.ForkDepth) + 0.5)
	pData._forkLenScale = RangeMod.RandomValueFromRange(freshData.ForkLengthScale)
	pData._sag = RangeMod.RandomValueFromRange(freshData.Sag)
	pData._sagShape = RangeMod.RandomValueFromRange(freshData.SagShape)
	pData._shapeMode = freshData.ShapeMode or "Jitter"
	pData._scrollSpeed = RangeMod.RandomValueFromRange(freshData.ScrollSpeed)
	pData._waves = math.max(0.25, RangeMod.RandomValueFromRange(freshData.Waves))
	pData._scrollPhase = 0
	pData._noiseSeedA = math.random() * 1000
	pData._noiseSeedB = 500 + math.random() * 1000
	local jitterHz = RangeMod.RandomValueFromRange(freshData.JitterRate)
	pData._jitterInterval = jitterHz > 0 and 1 / jitterHz or math.huge
	pData._jitterAccum = 0
	local growthSpeed = RangeMod.RandomValueFromRange(freshData.GrowthSpeed)
	pData._lSpeed = growthSpeed
	pData._growReversed = growthSpeed < 0
	pData._tipDist = 0
	pData._revealPtr = 0
	local dirInfo = DirectionVectors[freshData.EmissionDirection] or DirectionVectors[Enum.NormalId.Top]
	local localAxis = CFrame.new()[dirInfo.vector] * dirInfo.multiplier
	local spread = freshData.SpreadAngle or Vector2.new(0, 0)
	local rotS = AxisLinksMod.sampleRangeAxes(freshData, freshData.AxisLinks, {"RotX","RotY","RotZ"}, RangeMod, nil)
	local rotXYZ = Constants.composeRotation(freshData.RotOrder or "Global", rotS.RotX or 0, rotS.RotY or 0, rotS.RotZ or 0)
	local cf = CFrame.lookAt(Vector3.zero, localAxis)
	if freshData.DirMode == "Local" then cf = cf * rotXYZ end
	if spread.X > 0 or spread.Y > 0 then
		cf = cf * CFrame.Angles(
			math.rad((math.random() * 2 - 1) * spread.X),
			math.rad((math.random() * 2 - 1) * spread.Y), 0)
	end
	pData._dirLocalVec = cf.LookVector
	pData._dirGlobal = freshData.DirMode == "Global"
	pData._originRot = rotXYZ
	local posS = AxisLinksMod.sampleRangeAxes(freshData, freshData.AxisLinks, {"PosX","PosY","PosZ"}, RangeMod, nil)
	local px, py, pz = posS.PosX or 0, posS.PosY or 0, posS.PosZ or 0
	if px ~= 0 or py ~= 0 or pz ~= 0 then
		pData._originOffset = Vector3.new(px, py, pz)
		pData._originOffsetGlobal = freshData.PosMode == "Global"
	else
		pData._originOffset = nil
	end
	-- Origin motion resets per cycle (accumulators restart from the source pose).
	pData._accel = freshData.Acceleration or Vector3.zero
	pData._drag = freshData.Drag or 0
	pData._dispMode = freshData.DisplacementMode or "Global"
	pData._motionOffset = Vector3.zero
	pData._motionAccelVel = Vector3.zero
	pData._dispRaw = nil
	pData._hasMotion = PDataBuilder.liveGraph(freshData.Speed) ~= nil or pData._accel.Magnitude > 0
	pData._hasDisp = PDataBuilder.liveGraph(freshData.PosOffsetX) ~= nil
		or PDataBuilder.liveGraph(freshData.PosOffsetY) ~= nil
		or PDataBuilder.liveGraph(freshData.PosOffsetZ) ~= nil
	-- Gradient + Taper + Turbulence re-read per cycle; fresh noise seed varies the wander per loop.
	pData.Graphs.Gradient = PDataBuilder.liveColor(freshData.Gradient)
	pData.Graphs.ThicknessProfile = PDataBuilder.liveProfile(freshData.ThicknessProfile)
	pData.Seeds.ThicknessProfile = GraphMod.GenerateSeed(pData.Graphs.ThicknessProfile)
	pData.Graphs.Turbulence = TurbulenceMod.isLive(freshData.Turbulence)
	pData._hasTurb = pData.Graphs.Turbulence ~= nil
	pData._turbFreq = freshData.TurbulenceFrequency or 1
	pData._turbSeed = math.random() * 997 + 0.5
	pData._turbRaw = nil
	sampleShape(pData, freshData, pData.AnimateItem)

	local expected = layoutFor(freshData)
	if expected ~= pData._rig.partCount and freshData.RenderTemplate then
		local oldModel = pData.VisualPart
		local parent = oldModel and oldModel.Parent
		local model, rig = buildRig(freshData)
		model:SetAttribute("_PartIcleEmit", true)
		pData.VisualPart = model
		pData._rig = rig
		model.Parent = parent or self:GetFolder()
		if oldModel then pcall(function() oldModel:Destroy() end) end
	end
	-- Reroll after any rig rebuild so the clamp sees the current mainSegs.
	pData._segCount = math.clamp(math.floor(RangeMod.RandomValueFromRange(freshData.SegmentCount) + 0.5), 2, pData._rig.mainSegs)

	pData._curThick = freshData.Thickness and GraphMod.QueryPointsWithTime(0, freshData.Thickness, pData.Seeds.Thickness) or pData._curThick
	ImpactDisk.refresh(self, pData, freshData)
	-- Cycle-refresh rolls now; drop any budget-deferred roll from the old cycle.
	pData._rollPending = nil
	pData._rollPendingStamp = nil
	_rollsUsed += 1
	applyRoll(pData, false)
	writeVisuals(pData, 0)
	fireSeekHit(self, pData)
end

end
