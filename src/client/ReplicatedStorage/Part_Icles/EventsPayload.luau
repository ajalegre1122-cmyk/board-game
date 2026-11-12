--[[
	EventsPayload  -  payload-builder + type-dispatched mutators bound to a fired event's payload.

	build(pData, eventName, emitCtx, cf)
	  Constructs the payload table the user's Module script receives. Per-event extras
	  (HitPosition / DeathPosition / EmitIndex / Age / LingerElapsed) are populated by
	  Events.fire / Events.afterUpdate after this call.

	apply* helpers (operate on pData directly; the payload.<Setter> closures wire to these):
	  applyColor          → visual.Color3 + pData.SkipColor=true
	  applyTransparency   → visual.Transparency + pData.SkipTransparency=true
	  applyTeleport       → visual.CFrame / :PivotTo + reset orientation / hit-check anchors
	  applyAddSpin        → pData._spinRate += vec (per-axis angular velocity)
	  applyAddImpulse     → pData._accelVel += vec (acceleration-velocity accumulator kick)
	  applyFreezeTime     → pData._frozen=on (suspends effective-elapsed advance)
	  applyPause          → applyFreezeTime(true) + auto-clear after seconds
	  applySetSize        → BasePart.Size / Model ScaleTo / ImageLabel UDim2
	  applySetVelocity    → BaseDirection (unit) + speed-override magnitude
	  applyResurrect      → clears _killedManually / _forceDead (undoes payload.Kill)

	attach* helpers (wire setter closures onto payload):
	  attachSkipSetters     → SetSkipColor / SetSkipTransparency / SetSkipSize
	  attachAdvancedSetters → AddSpin / AddImpulse / FreezeTime / Pause / SetSize / SetVelocity / Resurrect

	Convention: every Set* that mutates a graphed channel auto-flips the matching pData.Skip*
	so per-frame graph writes don't clobber the override on the next Heartbeat. SetSkip* expose
	manual control of the same gate without writing a value.
]]

local LinkCF = require(script.Parent.LinkCF)

local EventsPayload = {}

-- Construct a payload table for a fired event. Caller passes a precomputed `cf` (world CFrame
-- or nil for screen kinds) to avoid circular dependency on Events.getWorldCF. Includes:
--   • Source identity + visual aliases.
--   • Life-cycle state (LifeProgress, TimeRemaining, StartTime, LifeTime).
--   • Speed-related: SpeedMultiplier (raw scalar; user computes velocity via BaseDirection if needed).
--   • ChainDepth (0 for root events, increments per cross-emitter hop).
--   • EmitCount (burst-size for OnEmit; nil for other events).
--   • Per-event extras: EmitPosition, Age, DeathPosition, LingerElapsed.
function EventsPayload.build(pData, eventName, emitCtx, cf)
	local pos = cf and cf.Position or nil
	local now = os.clock()
	local elapsed = pData.StartTime and math.max(0, now - pData.StartTime) or 0
	local lifeTime = pData.LifeTime or 0
	local lifeProgress = (lifeTime > 0) and math.min(1, elapsed / lifeTime) or 0
	local timeRemaining = math.max(0, lifeTime - elapsed)
	local speedMult = pData.SpeedMultiplier or 1
	local p = {
		SourceItem      = pData._sourceItem,
		Source          = pData._sourceItem,
		Particle        = pData.VisualPart,
		RenderTemplate  = pData.VisualPart,
		WorldCFrame     = cf,
		WorldPosition   = pos,
		LifeProgress    = lifeProgress,
		TimeRemaining   = timeRemaining,
		StartTime       = pData.StartTime,
		LifeTime        = lifeTime,
		SpeedMultiplier = speedMult,
		ChainDepth      = pData.EventChainCtx and pData.EventChainCtx.Depth or 0,
		EmitCount       = emitCtx and emitCtx.EmitCount,
		_eventName      = eventName,
	}
	if eventName == "OnEmit" then
		p.EmitPosition = pos
		p.EmitIndex = emitCtx and emitCtx.EmitIndex
	elseif eventName == "OnDeath" then
		p.DeathPosition = pos
		-- Real wall-time age. Mid-life Kill reports < LifeTime; natural death equals it.
		if pData.StartTime then
			p.Age = math.max(0, now - pData.StartTime)
		else
			p.Age = pData.LifeTime
		end
	elseif eventName == "OnDestruction" then
		p.DeathPosition = pos
		-- Wall-time inside the linger window. PartLife=0 path has no linger so elapsed=0.
		if pData._lingerStartTime then
			p.LingerElapsed = math.max(0, now - pData._lingerStartTime)
		else
			p.LingerElapsed = 0
		end
	end
	return p
end

-- Color3 write per particle Type. Animatable color targets vary by kind:
-- Part/Model: BasePart.Color + SurfaceAppearance.Color (when present).
-- Beam: Color = ColorSequence.new(color)  -  beams take a sequence; collapse to a one-stop
--       sequence so the override sticks across the full beam length.
-- PointLight: Color (Color3 directly).
-- ImageLabel: ImageColor3.
-- Screen: ColorCorrection → TintColor; Atmosphere → Color. Blur/Bloom have no color.
function EventsPayload.applyColor(pData, color)
	if typeof(color) ~= "Color3" then return end
	pData.SkipColor = true
	-- VisualPart-less types (CameraShake, Distortion) have no colour/transparency channel: no-op.
	local v = pData.VisualPart
	if not v or not v.Parent then return end
	local t = pData.Type
	if t == "Part" or t == "Model" then
		if v:IsA("BasePart") then pcall(function() v.Color = color end) end
		local sa = v.FindFirstChildOfClass and v:FindFirstChildOfClass("SurfaceAppearance")
		if sa then pcall(function() sa.Color = color end) end
	elseif t == "Beam" or t == "TrailEmitter" or t == "BeamNative" then
		pcall(function() v.Color = ColorSequence.new(color) end)
	elseif t == "PointLight" then
		pcall(function() v.Color = color end)
	elseif t == "Highlight" then
		pcall(function() v.FillColor = color end)
		pcall(function() v.OutlineColor = color end)
	elseif t == "ImageLabel" then
		pcall(function() v.ImageColor3 = color end)
	elseif t == "Screen" then
		-- Kind strings come from ScreenEmit: "Blur" / "Bloom" / "CC" / "Atmosphere".
		if pData.Kind == "CC" then
			pcall(function() v.TintColor = color end)
		elseif pData.Kind == "Atmosphere" then
			pcall(function() v.Color = color end)
		end
	elseif t == "Lightning" or t == "Rocks" or t == "Rope" then
		-- Write every rig part; SkipColor keeps the graph writer from clobbering.
		local rig = pData._rig
		if rig then
			local n = rig.partCount or rig.chunkCap
			pcall(function()
				for i = 1, n do rig.parts[i].Color = color end
			end)
		end
	end
end

-- Scalar 0..1 transparency write per particle Type.
-- PointLight has no transparency; cache the authored Brightness on first call (via
-- _baseBrightness) and modulate as base * (1 - amount) so SetTransparency(1) snuffs the
-- light and SetTransparency(0) restores it. Without the snapshot, repeated calls would
-- compound the multiplicative attenuation.
-- Screen kinds without a transparency analog (Blur/Bloom/Atmosphere) are no-ops; the
-- SkipTransparency flag still flips so the user can use it as a trigger for other logic.
function EventsPayload.applyTransparency(pData, amount)
	if type(amount) ~= "number" then return end
	amount = math.max(0, math.min(1, amount))
	pData.SkipTransparency = true
	-- VisualPart-less types (CameraShake, Distortion) have no colour/transparency channel: no-op.
	local v = pData.VisualPart
	if not v or not v.Parent then return end
	local t = pData.Type
	if t == "Part" or t == "Model" then
		if v:IsA("BasePart") then pcall(function() v.Transparency = amount end) end
		local d = v.FindFirstChildOfClass and v:FindFirstChildOfClass("Decal")
		if d then pcall(function() d.Transparency = amount end) end
	elseif t == "Beam" or t == "TrailEmitter" or t == "BeamNative" then
		pcall(function() v.Transparency = NumberSequence.new(amount) end)
	elseif t == "PointLight" then
		local base = pData._baseBrightness or v.Brightness
		pData._baseBrightness = base
		pcall(function() v.Brightness = base * (1 - amount) end)
	elseif t == "Highlight" then
		pcall(function() v.FillTransparency = amount end)
		pcall(function() v.OutlineTransparency = amount end)
	elseif t == "ImageLabel" then
		pcall(function() v.ImageTransparency = amount end)
	elseif t == "Lightning" or t == "Rocks" or t == "Rope" then
		pData._curTrans = amount
		local rig = pData._rig
		if rig then
			local n = rig.partCount or rig.chunkCap
			pcall(function()
				for i = 1, n do rig.parts[i].Transparency = amount end
			end)
		end
	end
end

-- Attach Skip* setters in one call. Each flips the corresponding
-- pData.Skip{Color,Transparency,Size} flag. Update branches gate per-frame writes.
-- SkipColor / SkipTransparency: Part / Beam / PointLight / ImageLabel / Screen.
-- SkipSize: Part (Update.luau) + ImageLabel (ImageEmit). Beam Width / PointLight
-- Range still write; symmetric coverage deferred.
-- SetSkipRotation NOT yet wired  -  Update.luau's rotation is interleaved with position
-- accumulation (NeedsRotAccum/VelocityVectored coupling); skipping requires deeper rework.
function EventsPayload.attachSkipSetters(payload, pData)
	payload.SetSkipColor = function(value) pData.SkipColor = value == true end
	payload.SetSkipTransparency = function(value) pData.SkipTransparency = value == true end
	payload.SetSkipSize = function(value) pData.SkipSize = value == true end
end

-- Teleport  -  write a new world CFrame to the visual + reset position-accumulator state.
-- Part / Attachment: VisualPart.CFrame = cf. Recompute LocalCF as parent's ToObjectSpace
-- of cf (or cf itself when unlinked). Resets _localWorldCF and _postUpdateCF so Orientation
-- + ZOffset overlays compose against the new pose. LastHitCheckPos resets to cf.Position so
-- the next OnHit raycast doesn't span the teleport gap and fire on a wall the particle
-- "passed through."
-- Model: VisualPart:PivotTo(cf). Same LocalCF / cache resets.
-- Beam / PointLight / ImageLabel / Screen kinds: no-op (no per-particle CFrame; PointLight
-- inherits its parent's position).
-- Wake a settled particle. Called from Teleport / AddImpulse / SetVelocity so
-- script-driven re-launch resumes natural physics with no stale settle state.
local function _clearSettleState(pData)
	pData._settleEngaged = false
	pData._restTimer = 0
	pData._settleRotDamp = 1
	pData._settleContactPos = nil
	pData._settleSpawnHalf = nil
	pData._lastHitNormal = nil
	pData._collisionStopped = false
	pData._displacementMirrorX = nil
	pData._displacementMirrorY = nil
	pData._displacementMirrorZ = nil
end

function EventsPayload.applyTeleport(pData, cf)
	if typeof(cf) ~= "CFrame" then return end
	_clearSettleState(pData)
	local v = pData.VisualPart
	if not v or not v.Parent then return end
	local t = pData.Type
	if t == "Part" then
		pcall(function() v.CFrame = cf end)
	elseif t == "Attachment" then
		-- Attachment.CFrame is parent-local; convert world cf via parent.
		local parent = v.Parent
		if parent and parent:IsA("BasePart") then
			pcall(function() v.CFrame = parent.CFrame:ToObjectSpace(cf) end)
		else
			pcall(function() v.CFrame = cf end)
		end
	elseif t == "Model" then
		pcall(function() v:PivotTo(cf) end)
	else
		return
	end
	-- Recompute LocalCF in the frame the Update functions compose against (LinkCF.parentFrame /
	-- attachmentParentFrame): live, frozen or snapshot link frame, identity when never linked.
	if t == "Attachment" then
		local visualParent = v.Parent
		local parentLocalCF = visualParent and LinkCF.toParentSpace(cf, visualParent) or cf
		local linkParentCF = LinkCF.attachmentParentFrame(pData)
		pData.LocalCF = linkParentCF:ToObjectSpace(parentLocalCF)
	else
		local parentCF = LinkCF.parentFrame(pData)
		pData.LocalCF = parentCF:ToObjectSpace(cf)
	end
	pData._localWorldCF = pData.LocalCF
	-- _postUpdateCF mirrors the live VisualPart.CFrame readout (init.luau:165). For
	-- Attachment that's parent-local (matches what was just written above); for
	-- Part/Model that's world. Re-read from the visual rather than re-deriving.
	if t == "Attachment" then
		pData._postUpdateCF = v.CFrame
	elseif t == "Model" then
		pData._postUpdateCF = v:GetPivot()
	else
		pData._postUpdateCF = cf
	end
	pData.CurrentPosition = cf.Position
	pData.LastHitCheckPos = cf.Position
	pData._lastOrientPos = nil -- next ApplyOrientation reseeds velocity from this frame
end

-- Add a Vector3 angular kick to pData._spinRate. EventsCollision.handleBounce
-- already populates this from `nrm × v_t`; user adds further tumble via this helper.
function EventsPayload.applyAddSpin(pData, vec)
	if typeof(vec) ~= "Vector3" then return end
	pData._spinRate = (pData._spinRate or Vector3.zero) + vec
end

-- Add a Vector3 impulse to pData._accelVel (acceleration-velocity accumulator). Update.luau's
-- per-step accel integration reads + writes _accelVel; user-added impulses persist into next step.
function EventsPayload.applyAddImpulse(pData, vec)
	if typeof(vec) ~= "Vector3" then return end
	_clearSettleState(pData)
	pData._accelVel = (pData._accelVel or Vector3.zero) + vec
end

-- Toggle pData._timeFrozen. Update branches gate effective-elapsed advance on this flag.
-- Marks `_freezeTimeExplicit` so a concurrent Pause's auto-clear doesn't undo the user's
-- indefinite freeze.
function EventsPayload.applyFreezeTime(pData, on)
	pData._timeFrozen = on == true
	pData._freezeTimeExplicit = on == true
end

-- Temporary FreezeTime: set _timeFrozen, schedule clear. Multi-call windows: a later Pause
-- bumps the gen so the earlier delay's clear is invalidated. Auto-clear respects an
-- explicit FreezeTime  -  if user has called FreezeTime(true), Pause's clear is a no-op so
-- the explicit freeze persists.
function EventsPayload.applyPause(pData, seconds)
	if type(seconds) ~= "number" or seconds <= 0 then return end
	pData._timeFrozen = true
	local gen = (pData._pauseGen or 0) + 1
	pData._pauseGen = gen
	task.delay(seconds, function()
		if pData._pauseGen == gen and not pData._freezeTimeExplicit then
			pData._timeFrozen = false
		end
	end)
end

-- Direct VisualPart.Size write + auto-flip SkipSize so per-frame Size graphs don't clobber.
-- Type-dispatch: BasePart Size (Vector3), Attachment has no Size, ImageLabel uses UDim2  -  for
-- ImageLabel pass a UDim2 instead of Vector3 (gated by typeof).
function EventsPayload.applySetSize(pData, size)
	pData.SkipSize = true
	local v = pData.VisualPart
	if not v or not v.Parent then return end
	local t = pData.Type
	if t == "Part" or t == "Model" then
		if typeof(size) == "Vector3" and v:IsA("BasePart") then
			pcall(function() v.Size = size end)
		elseif typeof(size) == "Vector3" and t == "Model" then
			-- Model has no Size; map to ScaleTo using x component as uniform scale.
			pcall(function() v:ScaleTo(math.max(0.001, size.X)) end)
		end
	elseif t == "ImageLabel" then
		if typeof(size) == "UDim2" then pcall(function() v.Size = size end) end
	end
end

-- Replace baseDirection (unit) + override speed magnitude. Update.luau's speed sampling
-- reads pData._speedOverride when set, bypassing authored Speed graph + speedMult. Pass nil
-- vec to clear the override and resume authored sampling.
function EventsPayload.applySetVelocity(pData, vec)
	if vec == nil then
		pData._speedOverride = nil
		return
	end
	if typeof(vec) ~= "Vector3" then return end
	_clearSettleState(pData)
	local mag = vec.Magnitude
	if mag < 1e-4 then
		pData.SpeedMultiplier = 0
		pData._speedOverride = 0
		return
	end
	pData.BaseDirection = vec / mag
	pData._speedOverride = mag
end

-- Clear _killedManually + _forceDead. Must run BEFORE next Heartbeat processes the death
-- frame, OR inside the same OnHit Module body that called Kill. After the death-frame, visual
-- is destroyed/hidden  -  too late to revive.
function EventsPayload.applyResurrect(pData)
	pData._killedManually = false
	pData._forceDead = false
end

-- Wire all advanced setters in one call. Keeps Events.luau slim (one line per attach instead
-- of seven). Caller passes the live payload + pData refs.
function EventsPayload.attachAdvancedSetters(payload, pData)
	payload.AddSpin = function(vec) EventsPayload.applyAddSpin(pData, vec) end
	payload.AddImpulse = function(vec) EventsPayload.applyAddImpulse(pData, vec) end
	payload.FreezeTime = function(on) EventsPayload.applyFreezeTime(pData, on) end
	payload.Pause = function(seconds) EventsPayload.applyPause(pData, seconds) end
	payload.SetSize = function(size) EventsPayload.applySetSize(pData, size) end
	payload.SetVelocity = function(vec) EventsPayload.applySetVelocity(pData, vec) end
	payload.Resurrect = function() EventsPayload.applyResurrect(pData) end
end

return EventsPayload
