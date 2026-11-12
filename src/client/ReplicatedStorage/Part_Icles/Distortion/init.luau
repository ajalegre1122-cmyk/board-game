--[[
	Distortion Mixin  -  Emit + Animate + Update for screen-space distortion
	emitters (glass canvas fields: Ripple / Wave / Noise / Bulge / Pinch).

	No visual clone: pData.VisualPart is nil (every engine teardown path guards
	it  -  CameraShake contract). Each live effect projects its epicenter to the
	screen, samples its Amplitude envelope (step-gated), integrates phase from
	effective time (Timescale-reversible), and pushes ONE contribution into
	Distortion/Canvas; Engine composites all contributions onto the shared glass
	plane once per step, AFTER CameraShakeApply.

	Nested emitters UNDER a Distortion RenderTemplate never fire (no clone to
	link); Distortion AS a nested child of Part/Model works and its epicenter
	rides the moving parent clone.

	Known engine limits (documented): desktop graphics quality ~8+ only;
	transparent objects behind the canvas are invisible while a distortion is
	active  -  design for short bursts.
]]

local RunService = game:GetService("RunService")

local GraphMod = require(script.Parent.Graph)
local RangeMod = require(script.Parent.Range)
local Constants = require(script.Parent.PartConstants)
local Canvas = require(script.Canvas)
local Log = require(script.Parent.Log)

local KIND_IDS = { Ripple = 1, Wave = 2, Noise = 3, Bulge = 4, Pinch = 5 }

local warnedServer = false

return function(Particle)

-- Distortion discriminator; shared by init.luau Emit dispatch + Lifecycle EmitAnimate dispatch.
function Particle._isDistortion(item)
	return item:IsA("BasePart") and item:GetAttribute("IsDistortion") == true
end

local function buildPData(item, data, lifeTime, emitCtx)
	local seeds = {
		Amplitude = GraphMod.GenerateSeed(data.Amplitude),
		Transparency = GraphMod.GenerateSeed(data.Transparency),
		Timescale = GraphMod.GenerateSeed(data.Timescale),
	}
	local eff0 = GraphMod.InitialEffectiveElapsed(data.Timescale, seeds.Timescale, lifeTime)
	local speed = data.Speed or 3
	local pData = {
		Type = "Distortion",
		VisualPart = nil,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = math.max(1, data.TotalKeyFrames),
		CurrentStep = -1,
		LifeTime = lifeTime,
		PartLife = 0,
		_sourceItem = item,
		Graphs = {
			Amplitude = data.Amplitude,
			Transparency = data.Transparency,
			Timescale = data.Timescale,
		},
		Seeds = seeds,
		_effectiveElapsed = eff0,
		_kindId = KIND_IDS[data.FieldKind] or 1,
		_wavelength = math.max(data.Wavelength or 1.5, 0.02),
		_speed = speed,
		_dirRad = math.rad(data.Direction or 0),
		_noiseScale = math.max(data.NoiseScale or 2, 0.05),
		_lensRadius = math.max(data.LensRadius or 1.5, 0.02),
		_screenCenter = data.EpicenterMode == "ScreenCenter",
		_falloff = data.Falloff or 0,
		_strength = data.Strength or 1,
		_amplify = data.Amplify or 0,
		_allowOver = data.AllowOverdrive == true,
		-- Mesh grid width request; the shared plane takes the highest active.
		_resolution = math.clamp(math.floor(data.Resolution or 24), 8, 96),
		-- Phase seeded from initial effective time so a reverse-start Timescale
		-- plays the field animation backward from its END state (family contract),
		-- not from a negative radius.
		_phase = eff0 * speed * 0.1,
		_noiseSeed = math.floor(math.random() * 100000),
		_lastOriginPos = item.Position,
	}
	-- Event origin override (EnableEmitAt / Events AtPosition chains): the
	-- epicenter projects from the resolved origin for the effect's whole life.
	if emitCtx then
		local originCF
		if emitCtx.EventOriginResolver then originCF = emitCtx.EventOriginResolver() end
		originCF = originCF or emitCtx.EventOriginCF
		if originCF then pData._originOverride = originCF.Position end
	end
	return pData
end

function Particle:EmitDistortion(item, link, emitCtx)
	if not item or not item.Parent then return end
	-- Server has no camera/screen; skip entirely.
	if not RunService:IsClient() then
		if not warnedServer then
			warnedServer = true
			Log.warn("[Part-Icles] Distortion ignored on the server (no screen).")
		end
		return
	end
	local data = self:GetData(item)
	if not data then return end

	local lifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	if lifeTime <= 0 then lifeTime = 0.001 end

	local pData = buildPData(item, data, lifeTime, emitCtx)
	-- Nested emit: the epicenter rides the emitted parent clone.
	pData._parentLink = link
	Particle._seedTsOverride(pData, item)
	self:_registerEmit(pData, emitCtx)
end

-- Animate mode: singleton persistent field per source (no clone at all).
function Particle:EmitDistortionAnimate(item, link, emitCtx)
	if not item or not item.Parent then return end
	if self.ActiveAnimates[item] then return end
	if not RunService:IsClient() then return end
	local data = self:GetData(item)
	if not data then return end

	local lifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	if lifeTime <= 0 then lifeTime = 0.001 end

	local pData = buildPData(item, data, lifeTime, emitCtx)
	pData._parentLink = link
	pData.IsAnimate = true
	pData.AnimateItem = item

	Particle._seedTsOverride(pData, item)
	self.ActiveAnimates[item] = pData
	self:_registerEmit(pData, emitCtx)
end

-- Per-frame update: envelope (step-gated) + phase integral (per frame) +
-- epicenter projection, then one Canvas contribution. Zero allocation.
function Particle:UpdateDistortion(pData, dt, currentTime)
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
	local newEff = (pData._effectiveElapsed or 0) + (pData._timeFrozen and 0 or dtTs)
	if newEff < 0 then newEff = 0 end
	if newEff > lifeTime then newEff = lifeTime end
	pData._effectiveElapsed = newEff

	if pData.TotalKeyFrames <= 0 then return true end
	local isDying = real_i >= 1 and (newEff >= lifeTime or newEff <= 0)
	if isDying then return true end

	-- Phase integral (Speed is signed; Timescale reverse rewinds the field).
	-- 0.1 keeps authored Speed values in a friendly 1-10 range.
	if not pData._timeFrozen then
		pData._phase += dtTs * pData._speed * 0.1
	end

	-- Envelope, step-gated by TotalKeyFrames.
	local li = newEff / lifeTime
	local targetStep = math.floor(math.min(math.max(li, 0), 1) * pData.TotalKeyFrames)
	if targetStep ~= pData.CurrentStep then
		pData.CurrentStep = targetStep
		local si = targetStep / pData.TotalKeyFrames
		pData._curAmp = pData.Graphs.Amplitude and GraphMod.QueryPointsWithTime(si, pData.Graphs.Amplitude, pData.Seeds.Amplitude) or 0
		-- Above 1 = overdrive request (engine-quirk zone; effective ~4-10).
		local trans = pData.Graphs.Transparency and GraphMod.QueryPointsWithTime(si, pData.Graphs.Transparency, pData.Seeds.Transparency)
		pData._curTrans = trans and math.clamp(trans, 0, 10) or nil
	end

	local cam = workspace.CurrentCamera
	if not cam then return false end

	-- Epicenter: screen center, or the live world origin projected each frame
	-- (override → parent clone → source → frozen last-known).
	local epicU, epicV = 0.5, 0.5
	local atten = 1
	if not pData._screenCenter or pData._falloff > 0 then
		local origin = pData._originOverride
		if not origin then
			local link = pData._parentLink
			if link and link.Parent then
				origin = Constants.resolveLinkCFrame(link).Position
			else
				local src = pData._sourceItem
				origin = (src and src.Parent) and src.Position or pData._lastOriginPos
			end
		end
		pData._lastOriginPos = origin
		if pData._falloff > 0 then
			atten = math.clamp(1 - (cam.CFrame.Position - origin).Magnitude / pData._falloff, 0, 1)
		end
		if not pData._screenCenter then
			local vp, _ = cam:WorldToViewportPoint(origin)
			local vps = cam.ViewportSize
			epicU = vp.X / math.max(1, vps.X)
			-- Canvas plane-local V runs bottom-up; viewport Y runs top-down.
			epicV = 1 - vp.Y / math.max(1, vps.Y)
			-- Behind-camera fade (no 1-frame pop when the camera crosses the
			-- epicenter plane).
			atten *= math.clamp(vp.Z / 2, 0, 1)
		end
	end

	-- Contribute every live frame, even at amp 0: the transparency channel must
	-- stay continuous through amplitude zero crossings and Falloff/behind-camera
	-- fades, or the plane blinks (idle-dim pop mid-life). Canvas pulls the
	-- transparency toward 1 by atten so both channels fade together.
	local amp = (pData._curAmp or 0) * pData._strength * atten
	Canvas.accumulate(pData._kindId, amp, pData._wavelength, pData._phase,
		pData._dirRad, pData._noiseScale, pData._lensRadius,
		epicU, epicV, pData._noiseSeed, pData._amplify, pData._allowOver,
		pData._curTrans, atten, pData._resolution)

	return false
end

-- AnimateLoop per-cycle refresh (EngineReplay dispatch). Graphs/seeds/LifeTime
-- are refreshed by the generic replay; scalars re-read here. Phase reseed lives
-- in _reseedDistortionPhase, which EngineReplay calls AFTER it recomputes
-- _effectiveElapsed from the fresh Timescale graph + re-rolled LifeTime.
function Particle:_refreshDistortionAnimate(pData, freshData)
	pData.Link = nil
	pData._kindId = KIND_IDS[freshData.FieldKind] or 1
	pData._wavelength = math.max(freshData.Wavelength or 1.5, 0.02)
	pData._speed = freshData.Speed or 3
	pData._dirRad = math.rad(freshData.Direction or 0)
	pData._noiseScale = math.max(freshData.NoiseScale or 2, 0.05)
	pData._lensRadius = math.max(freshData.LensRadius or 1.5, 0.02)
	pData._screenCenter = freshData.EpicenterMode == "ScreenCenter"
	pData._falloff = freshData.Falloff or 0
	pData._strength = freshData.Strength or 1
	pData._amplify = freshData.Amplify or 0
	pData._allowOver = freshData.AllowOverdrive == true
	pData._resolution = math.clamp(math.floor(freshData.Resolution or 24), 8, 96)
	pData._curAmp = nil
	pData._curTrans = nil
	pData.CurrentStep = -1
end

-- Per-kind phase policy: Noise/Wave keep phase (continuous shimmer);
-- Ripple/Bulge/Pinch restart from the initial effective time so reverse-start
-- loops play backward from the end state. Must run AFTER EngineReplay's
-- _effectiveElapsed recompute (fresh Timescale graph + re-rolled LifeTime) or
-- ranged-Lifetime reverse loops seed the phase from the prior cycle's length.
function Particle:_reseedDistortionPhase(pData)
	if pData._kindId == 1 or pData._kindId == 4 or pData._kindId == 5 then
		pData._phase = (pData._effectiveElapsed or 0) * pData._speed * 0.1
	end
end

end
