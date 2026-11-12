--[[
	Sound Mixin  -  Emit + Update for Sound emitters (native Sound instance as the RenderTemplate).

	Each emit plays a copy of the RT: positional under Emit Into, the link clone (a Model resolves
	to its middle part) or a carrier mirroring the source's parent; Local2D copies play through
	SoundService instead. In Studio edit mode every copy plays non-positionally under the plugin's
	audio widget (VisualHost.getEditAudioHost), the only parent Studio plays plugin Sounds from.
	Volume / PlaybackSpeed are stepped envelopes over Lifetime; Lifetime 0
	runs until the clip ends. Timescale drives the clip as well as the envelopes: the copy
	plays at the envelope's speed times the timescale and pauses while time stands still or
	runs backwards. Animate-less like Lights (a sound has no in-place state to loop).
	Every copy is destroyed on release (LifecycleRelease._releaseVisual: no pool kind).
]]

local SoundService = game:GetService("SoundService")

local GraphMod = require(script.Parent.Graph)
local RangeMod = require(script.Parent.Range)
local VisualHost = require(script.Parent.VisualHost)

-- Lifetime 0 with a clip whose length is not known (still loading, or looped): the Ended signal
-- ends the particle, this only bounds it. A loading clip's real length replaces it on load.
local UNBOUNDED_LIFETIME = 3600
-- Below this timescale the clip is paused: a Sound cannot play backwards, and a PlaybackSpeed
-- of 0 still advances TimePosition in Studio.
local MIN_PLAY_RATE = 0.01

return function(Particle)

function Particle._isSound(item)
	return item:IsA("Sound")
end

-- Emit Into > link clone > carrier mirroring the source's parent (mirrors EmitPointLight).
local function resolveHost(item, data, link)
	local host = data.EmitParent or link
	local carrier = nil
	if not host then
		local anchor = item.Parent
		if anchor and (anchor:IsA("BasePart") or anchor:IsA("Attachment")) then
			carrier = VisualHost.acquireCarrier(anchor)
			host = carrier
		else
			host = anchor
		end
	end
	if host and host:IsA("Model") then
		local parts = nil
		for _, child in ipairs(host:GetChildren()) do
			if child:IsA("BasePart") then
				parts = parts or {}
				parts[#parts + 1] = child
			end
		end
		if parts then host = parts[math.ceil(#parts / 2)] end
	end
	return host, carrier
end

function Particle:UpdateSound(pData, dt, currentTime)
	-- Signed-reverse timescale header: see Update.luau UpdatePart.
	local real_i = math.min(math.max((currentTime - pData.StartTime) / pData.LifeTime, 0), 1)
	local ts
	if pData._tsOverride ~= nil and currentTime < (pData._tsOverrideUntil or 0) then
		ts = pData._tsOverride
	else
		ts = pData.Graphs.Timescale and GraphMod.QueryPointsWithTime(real_i, pData.Graphs.Timescale, pData.Seeds.Timescale) or 1
	end
	local lifeTime = pData.LifeTime
	local newEff = (pData._effectiveElapsed or 0) + (pData._timeFrozen and 0 or dt * ts)
	if newEff < 0 then newEff = 0 end
	if newEff > lifeTime then newEff = lifeTime end
	pData._effectiveElapsed = newEff

	local sound = pData.VisualPart
	if not sound or not sound.Parent then return true end
	if pData._parentAlive and not pData._parentAlive[1] then return true end
	if pData._clipEnded then return true end
	if pData.TotalKeyFrames <= 0 then return true end
	local isDying = real_i >= 1 and (newEff >= lifeTime or newEff <= 0)

	local targetStep = math.floor(math.min(math.max(newEff / lifeTime, 0), 1) * pData.TotalKeyFrames)
	if targetStep ~= pData.CurrentStep then
		pData.CurrentStep = targetStep
		local steppedI = targetStep / pData.TotalKeyFrames
		if pData.Graphs.SndVolume then
			sound.Volume = GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.SndVolume, pData.Seeds.SndVolume)
		end
		if pData.Graphs.SndPlaybackSpeed then
			pData._envelopeSpeed = GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.SndPlaybackSpeed, pData.Seeds.SndPlaybackSpeed)
		end
	end

	-- Every frame, not per keyframe: the timescale (graph or SetTimescale) moves between steps.
	local rate = ts
	if pData._timeFrozen then
		rate = 0
	end
	if rate < MIN_PLAY_RATE then
		-- _started: the copy plays only once its clip has loaded, and is not paused before that.
		if pData._started and not pData._heldByTimescale then
			pData._heldByTimescale = true
			sound:Pause()
		end
	else
		local speed = pData._envelopeSpeed * rate
		if speed ~= pData._appliedSpeed then
			pData._appliedSpeed = speed
			sound.PlaybackSpeed = speed
		end
		if pData._heldByTimescale then
			pData._heldByTimescale = false
			sound:Resume()
		end
	end
	return isDying
end

function Particle:EmitSound(item, link, emitCtx)
	if not item or not item.Parent then return end
	local data = self:GetEmitData(item, emitCtx)
	if not data or not data.RenderTemplate then return end

	local sound = Instance.fromExisting(data.RenderTemplate)
	sound.Archivable = false
	sound.Playing = false
	sound.Looped = data.Looped == true
	sound.RollOffMinDistance = data.RollOffMin or 10
	sound.RollOffMaxDistance = data.RollOffMax or 10000
	pcall(function() sound:SetAttribute("_PartIcleEmit", true) end)

	local seedVolume = data.SndVolume and GraphMod.GenerateSeed(data.SndVolume) or {}
	local seedSpeed = data.SndPlaybackSpeed and GraphMod.GenerateSeed(data.SndPlaybackSpeed) or {}
	local seedTimescale = GraphMod.GenerateSeed(data.SndTimescale)
	local speed0 = data.SndPlaybackSpeed and GraphMod.QueryPointsWithTime(0, data.SndPlaybackSpeed, seedSpeed) or 1
	if data.SndVolume then sound.Volume = GraphMod.QueryPointsWithTime(0, data.SndVolume, seedVolume) end
	sound.PlaybackSpeed = speed0

	-- Lifetime 0 = the clip's own length at the starting speed; unknown until loaded.
	local lifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	local clipBound = lifeTime <= 0
	if clipBound then
		local length = sound.IsLoaded and sound.TimeLength or 0
		lifeTime = (length > 0 and not sound.Looped) and (length / math.max(speed0, 0.01)) or UNBOUNDED_LIFETIME
	end
	if lifeTime <= 0 then lifeTime = 0.001 end

	local editAudioHost = VisualHost.getEditAudioHost()
	local host, carrier = nil, nil
	if editAudioHost then
		host = editAudioHost
	elseif data.Local2D then
		host = SoundService
	else
		host, carrier = resolveHost(item, data, link)
	end
	if not host then return end

	local pData = {
		Type = "Sound",
		VisualPart = sound,
		_carrier = carrier,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = math.max(1, data.TotalKeyFrames),
		CurrentStep = -1,
		LifeTime = lifeTime,
		PartLife = 0,
		Graphs = {
			SndVolume = data.SndVolume,
			SndPlaybackSpeed = data.SndPlaybackSpeed,
			Timescale = data.SndTimescale,
		},
		Seeds = {
			SndVolume = seedVolume,
			SndPlaybackSpeed = seedSpeed,
			Timescale = seedTimescale,
		},
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.SndTimescale, seedTimescale, lifeTime),
		-- The envelope's playback speed; UpdateSound multiplies it by the timescale.
		_envelopeSpeed = speed0,
		_appliedSpeed = speed0,
		_started = false,
		_heldByTimescale = false,
	}
	pData._sourceItem = item
	-- Riding an emitted parent clone: die with it (see UpdatePointLight).
	if emitCtx and emitCtx._parentAlive and not data.EmitParent then
		pData._parentAlive = emitCtx._parentAlive
	end
	Particle._seedTsOverride(pData, item)

	sound.Parent = host
	local function play()
		if not sound.Parent then return end
		-- A copy is rarely loaded at emit, so its clip length was unknown there. The lifetime the
		-- envelopes and the timescale graph run over is the clip's, set here and counted from here.
		if clipBound and pData.LifeTime == UNBOUNDED_LIFETIME and sound.TimeLength > 0 and not sound.Looped then
			pData.LifeTime = sound.TimeLength / math.max(speed0, 0.01)
			pData._effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.SndTimescale, seedTimescale, pData.LifeTime)
		end
		pData.StartTime = os.clock()
		sound.TimePosition = data.StartOffset or 0
		if data.Local2D and not editAudioHost then
			SoundService:PlayLocalSound(sound)
		else
			sound:Play()
		end
		pData._started = true
	end
	if clipBound then
		sound.Ended:Once(function() pData._clipEnded = true end)
	end
	-- Play gates on the clip being loaded so the first note is never cut.
	if sound.IsLoaded then
		play()
	else
		sound.Loaded:Once(play)
	end

	self:_registerEmit(pData, emitCtx)
end

end
