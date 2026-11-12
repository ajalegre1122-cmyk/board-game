--[[
	CameraShake Mixin  -  Emit + Animate + Update for positional camera-shake emitters.

	No visual clone: pData.VisualPart is nil (every engine teardown path guards it).
	Each live shake samples six decorrelated Perlin channels per frame, attenuates
	by camera distance to the emitter (ShakeFalloff, 0 = global), and adds the
	result to CameraShake/Apply's accumulator; Engine applies the summed offset to
	workspace.CurrentCamera once per step. Multiple shakes sum linearly (small-angle
	Euler addition on the rotational channels).

	Nested emitters UNDER a shake's RenderTemplate never fire (no clone to link) -
	shake AS a nested child of Part/Model/Lightning works and its falloff origin
	rides the moving parent clone.
]]

local RunService = game:GetService("RunService")

local GraphMod = require(script.Parent.Graph)
local RangeMod = require(script.Parent.Range)
local Constants = require(script.Parent.PartConstants)
local Apply = require(script.Apply)
local Log = require(script.Parent.Log)

-- Non-integer channel offsets (math.noise returns 0 on the integer lattice).
local KX, KY, KZ = 0.17, 137.7, 291.3
local KRX, KRY, KRZ = 431.1, 557.5, 683.9

local warnedServer = false

return function(Particle)

-- CameraShake discriminator; shared by init.luau Emit dispatch + Lifecycle EmitAnimate dispatch.
function Particle._isCameraShake(item)
	return item:IsA("BasePart") and item:GetAttribute("IsCameraShake") == true
end

local function buildPData(item, data, lifeTime, emitCtx)
	local seeds = {
		ShakeAmplitude = GraphMod.GenerateSeed(data.ShakeAmplitude),
		ShakeRotAmplitude = GraphMod.GenerateSeed(data.ShakeRotAmplitude),
		ShakeFrequency = GraphMod.GenerateSeed(data.ShakeFrequency),
		Timescale = GraphMod.GenerateSeed(data.Timescale),
	}
	local pData = {
		Type = "CameraShake",
		VisualPart = nil,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = math.max(1, data.TotalKeyFrames),
		CurrentStep = -1,
		LifeTime = lifeTime,
		PartLife = 0,
		_sourceItem = item,
		Graphs = {
			ShakeAmplitude = data.ShakeAmplitude,
			ShakeRotAmplitude = data.ShakeRotAmplitude,
			ShakeFrequency = data.ShakeFrequency,
			Timescale = data.Timescale,
		},
		Seeds = seeds,
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.Timescale, seeds.Timescale, lifeTime),
		-- Noise phase = integral of ShakeFrequency over effective time (reverse timescale rewinds it).
		_shakePhase = 0,
		_falloff = data.ShakeFalloff or 0,
		_shakeSeed = math.random() * 997 + 0.5,
		_lastOriginPos = item.Position,
	}
	-- Event origin override (EnableEmitAt / Events AtPosition chains): falloff
	-- measures from the resolved origin for the shake's whole life.
	if emitCtx then
		local originCF
		if emitCtx.EventOriginResolver then originCF = emitCtx.EventOriginResolver() end
		originCF = originCF or emitCtx.EventOriginCF
		if originCF then pData._originOverride = originCF.Position end
	end
	return pData
end

function Particle:EmitCameraShake(item, link, emitCtx)
	if not item or not item.Parent then return end
	-- Server has no camera; Heartbeat-driven server engines skip shakes entirely.
	if not RunService:IsClient() then
		if not warnedServer then
			warnedServer = true
			Log.warn("[Part-Icles] CameraShake ignored on the server (no camera).")
		end
		return
	end
	local data = self:GetData(item)
	if not data then return end

	local lifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	if lifeTime <= 0 then lifeTime = 0.001 end

	local pData = buildPData(item, data, lifeTime, emitCtx)
	-- Nested emit: falloff origin rides the emitted parent clone.
	pData._parentLink = link
	Particle._seedTsOverride(pData, item)
	self:_registerEmit(pData, emitCtx)
end

-- Animate mode: singleton looping shake per source (no clone at all).
function Particle:EmitCameraShakeAnimate(item, link, emitCtx)
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

-- Per-frame update: sample envelopes (step-gated), noise channels (every frame,
-- smoothness), attenuate by distance, accumulate. Zero allocation.
function Particle:UpdateCameraShake(pData, dt, currentTime)
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

	-- Falloff origin: live parent clone → live source → frozen last-known.
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

	local li = newEff / lifeTime
	local targetStep = math.floor(math.min(math.max(li, 0), 1) * pData.TotalKeyFrames)
	if targetStep ~= pData.CurrentStep then
		pData.CurrentStep = targetStep
		local si = targetStep / pData.TotalKeyFrames
		pData._curAmp = pData.Graphs.ShakeAmplitude and GraphMod.QueryPointsWithTime(si, pData.Graphs.ShakeAmplitude, pData.Seeds.ShakeAmplitude) or 0
		pData._curRotAmp = pData.Graphs.ShakeRotAmplitude and GraphMod.QueryPointsWithTime(si, pData.Graphs.ShakeRotAmplitude, pData.Seeds.ShakeRotAmplitude) or 0
		pData._curFreq = pData.Graphs.ShakeFrequency and GraphMod.QueryPointsWithTime(si, pData.Graphs.ShakeFrequency, pData.Seeds.ShakeFrequency) or 10
	end
	if not pData._timeFrozen then
		pData._shakePhase = (pData._shakePhase or 0) + dtTs * (pData._curFreq or 10)
	end

	local atten = 1
	local falloff = pData._falloff
	if falloff > 0 then
		local cam = workspace.CurrentCamera
		if cam then
			atten = math.clamp(1 - (cam.CFrame.Position - origin).Magnitude / falloff, 0, 1)
		else
			atten = 0
		end
	end

	local amp = (pData._curAmp or 0) * atten
	local rotAmp = math.rad(pData._curRotAmp or 0) * atten
	if amp ~= 0 or rotAmp ~= 0 then
		local t = pData._shakePhase
		local s = pData._shakeSeed
		Apply.accumulate(
			amp * math.noise(t, s, KX), amp * math.noise(t, s, KY), amp * math.noise(t, s, KZ),
			rotAmp * math.noise(t, s, KRX), rotAmp * math.noise(t, s, KRY), rotAmp * math.noise(t, s, KRZ))
	end

	return false
end

-- AnimateLoop per-cycle refresh (EngineReplay dispatch). Graphs/seeds/LifeTime are
-- refreshed by the generic replay; only the scalar shake fields re-read here.
-- Noise seed and phase persist so the loop reads as one continuous rumble.
function Particle:_refreshCameraShakeAnimate(pData, freshData)
	pData.Link = nil
	pData._falloff = freshData.ShakeFalloff or 0
	pData._curAmp = nil
	pData._curRotAmp = nil
	pData._curFreq = nil
	pData.CurrentStep = -1
end

end
