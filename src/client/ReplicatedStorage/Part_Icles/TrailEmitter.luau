--[[
	TrailEmitter Mixin  -  Emit + Update for Trail particles (emitter mode, post-Transform-as-Emitter).
	Mirrors Beam emitter pattern: static spatial position (welded to existing Attachment0/Attachment1),
	animation entirely via graphs. Width / Transparency / Color drive through TrailGraphBlender;
	Brightness / LightEmission / LightInfluence / TextureLength / MinLength / MaxLength are
	per-frame scalar graphs sampled at the current step's i.

	Cross-file invariants:
	  - pData.Type = "TrailEmitter"  -  Heartbeat dispatch routes to UpdateTrail
	  - Lifecycle.cancelAnimation reads pData.TrailEmitterSnapshot to restore live RT (animate mode)
	  - PoolHide kind "TrailEmitter" → Enabled=false on release / true on acquire
	  - data.RenderTemplate is the cloned Trail; clones share its Attachment0/Attachment1 references
]]

local GraphMod = require(script.Parent.Graph)
local EMPTY_SEED = {}
local RangeMod = require(script.Parent.Range)
local TrailGraphBlender = require(script.Parent.TrailGraphBlender)
local Pool = require(script.Parent.Pool)
local MeshFlipbook = require(script.Parent.Flipbook)

return function(Particle)

-- Per-particle scalar graphs sampled at each step. Keep aligned with TrailEmitterProperties.
local SCALAR_GRAPHS = {"Brightness", "LightEmission", "LightInfluence", "TextureLength", "MinLength", "MaxLength"}

local function _writeBlenderState(visual, propName, states, mergedTimesList, lastIdxField, pData, t)
	if not states or #states == 0 then return end
	if #states == 1 then
		visual[propName] = states[1].Graph
		return
	end
	local lastIdx = pData[lastIdxField] or 1
	if t < states[lastIdx].Time then lastIdx = 1 end
	local pairIdx = #states - 1
	for idx = lastIdx, #states - 1 do
		if t >= states[idx].Time and t <= states[idx + 1].Time then
			pairIdx = idx; break
		end
	end
	pData[lastIdxField] = pairIdx
	local lower = states[pairIdx]
	local upper = states[pairIdx + 1] or states[#states]
	local range = upper.Time - lower.Time
	local segmentAlpha = range > 0 and ((t - lower.Time) / range) or 0
	if upper.Transition then segmentAlpha = GraphMod.QueryPointsWithTime(segmentAlpha, upper.Transition, EMPTY_SEED) end
	local mergedTimes = mergedTimesList and mergedTimesList[pairIdx]
	if mergedTimes then
		if propName == "Color" then
			visual[propName] = GraphMod.LerpColorGraphFast(lower.Graph, upper.Graph, segmentAlpha, mergedTimes)
		else
			visual[propName] = GraphMod.LerpGraphFast(lower.Graph, upper.Graph, segmentAlpha, mergedTimes)
		end
	end
end

-- Per-frame Heartbeat update for TrailEmitter particles. Width / Transparency / Color drive
-- through TrailGraphBlender; scalar graphs (Brightness / LightEmission / etc) sample per frame.
function Particle:UpdateTrail(pData, dt, currentTime)
	-- Signed-reverse timescale support: see Update.luau UpdatePart. SetTimescale override wins for its window.
	local real_i = math.min(math.max((currentTime - pData.StartTime) / pData.LifeTime, 0), 1)
	local ts
	if pData._tsOverride ~= nil and currentTime < (pData._tsOverrideUntil or 0) then
		ts = pData._tsOverride
	else
		ts = pData.Graphs.Timescale and GraphMod.QueryPointsWithTime(real_i, pData.Graphs.Timescale, pData.Seeds.Timescale) or 1
	end
	local dtTs = dt * ts
	local lifeTime = pData.LifeTime
	local priorEff = pData._effectiveElapsed or 0
	local newEff = priorEff + (pData._timeFrozen and 0 or dtTs)
	if newEff < 0 then newEff = 0 end
	if newEff > lifeTime then newEff = lifeTime end
	pData._effectiveElapsed = newEff
	local atForwardEnd = newEff >= lifeTime
	local atBackwardEnd = newEff <= 0
	local elapsedTime = newEff
	local i = elapsedTime / lifeTime

	if not pData.VisualPart or not pData.VisualPart.Parent then return true end
	local graphFinished = real_i >= 1
	local isDying = graphFinished and (atForwardEnd or atBackwardEnd)
	i = math.min(math.max(i, 0), 1)

	-- Width / Transparency / Color blender (continuous-time, FPS-independent).
	local t = i
	if not pData.SkipColor then
		_writeBlenderState(pData.VisualPart, "WidthScale",   pData.WidthStates, pData.WidthMergedTimes, "_lastWidthIdx", pData, t)
		_writeBlenderState(pData.VisualPart, "Color",        pData.ColorStates, pData.ColorMergedTimes, "_lastColorIdx", pData, t)
	end
	if not pData.SkipTransparency then
		_writeBlenderState(pData.VisualPart, "Transparency", pData.TransStates, pData.TransMergedTimes, "_lastTransIdx", pData, t)
	end

	-- Step-quantized scalar graphs (Brightness / LightEmission / LightInfluence / TextureLength / MinLength / MaxLength).
	if pData.TotalKeyFrames > 0 then
		local targetStep = math.floor(i * pData.TotalKeyFrames)
		if targetStep ~= pData.CurrentStep then
			pData.CurrentStep = targetStep
			local steppedI = pData.CurrentStep / pData.TotalKeyFrames
			for _, key in ipairs(SCALAR_GRAPHS) do
				local graph = pData.Graphs[key]
				if graph then
					pData.VisualPart[key] = GraphMod.QueryPointsWithTime(steppedI, graph, pData.Seeds[key])
				end
			end
		end
	end

	return isDying
end

local function _collectStatesAndMergedTimes(graphBlender)
	local widthStates, transStates, colorStates = TrailGraphBlender.CollectStates(graphBlender)
	local widthMergedTimes, transMergedTimes, colorMergedTimes = {}, {}, {}
	for idx = 1, #widthStates - 1 do widthMergedTimes[idx] = TrailGraphBlender.PrecomputeMergedTimes(widthStates[idx].Graph, widthStates[idx + 1].Graph) end
	for idx = 1, #transStates - 1 do transMergedTimes[idx] = TrailGraphBlender.PrecomputeMergedTimes(transStates[idx].Graph, transStates[idx + 1].Graph) end
	for idx = 1, #colorStates - 1 do colorMergedTimes[idx] = TrailGraphBlender.PrecomputeMergedColorTimes(colorStates[idx].Graph, colorStates[idx + 1].Graph) end
	return widthStates, transStates, colorStates, widthMergedTimes, transMergedTimes, colorMergedTimes
end

local function _buildScalarGraphs(data)
	local graphs = { Timescale = data.TEmitTimescale }
	local seeds = { Timescale = GraphMod.GenerateSeed(data.TEmitTimescale) }
	for _, key in ipairs(SCALAR_GRAPHS) do
		local g = data["TEmit" .. key] or data[key]
		if g then
			graphs[key] = g
			seeds[key] = GraphMod.GenerateSeed(g)
		end
	end
	return graphs, seeds
end

-- Spawn a TrailEmitter particle: clones RenderTemplate, applies authored Width / Color graphs,
-- registers in ActiveEmits. Trail inherits Attachment0/Attachment1 references from the clone source.
function Particle:EmitTrail(trail, link, emitCtx)
	if not trail or not trail.Parent then return end
	local data = self:GetEmitData(trail, emitCtx)
	if not data or not data.RenderTemplate then return end

	local visual = Pool.acquireOrClone(data.RenderTemplate, "TrailEmitter", data.Pool)
	visual.Archivable = false
	visual.Enabled = true
	-- Static props (Texture/TextureMode/FaceCamera) come from the cloned RT directly; no
	-- attribute-side mirror, so no override needed here.

	-- Bind the ends from the AUTHORED RT references (a pooled visual still carries a previous
	-- parent's clone attachments): the parent clone's copy when one exists, else the source.
	local map = emitCtx and emitCtx._parentCloneMap
	local a0, a1 = data.RenderTemplate.Attachment0, data.RenderTemplate.Attachment1
	local c0 = map and a0 and map[a0]
	local c1 = map and a1 and map[a1]
	visual.Attachment0 = (c0 and c0.Parent) and c0 or a0
	visual.Attachment1 = (c1 and c1.Parent) and c1 or a1

	local safeLifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	if safeLifeTime <= 0 then safeLifeTime = 0.001 end
	-- visual.Lifetime is the Trail's segment fade duration, separate from particle Lifetime.
	local trailLifeRange = data.TrailLife or data.Lifetime
	local trailLifeVal = RangeMod.RandomValueFromRange(trailLifeRange)
	if trailLifeVal <= 0 then trailLifeVal = 0.001 end
	visual.Lifetime = trailLifeVal

	local widthStates, transStates, colorStates,
		widthMergedTimes, transMergedTimes, colorMergedTimes = _collectStatesAndMergedTimes(data.GraphBlender)

	if #widthStates > 0 then visual.WidthScale = widthStates[1].Graph end
	if #transStates > 0 then visual.Transparency = transStates[1].Graph end
	if #colorStates > 0 then visual.Color = colorStates[1].Graph end

	local graphs, seeds = _buildScalarGraphs(data)
	for _, key in ipairs(SCALAR_GRAPHS) do
		if graphs[key] then
			visual[key] = GraphMod.QueryPointsWithTime(0, graphs[key], seeds[key])
		end
	end

	visual.Parent = data.EmitParent or self:GetFolder()

	local pData = {
		Type = "TrailEmitter",
		VisualPart = visual,
		Link = link,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = math.max(1, data.TotalKeyFrames),
		CurrentStep = 0,
		LifeTime = safeLifeTime,
		PartLife = data.PartLife or 0,
		WidthStates = widthStates, TransStates = transStates, ColorStates = colorStates,
		WidthMergedTimes = widthMergedTimes, TransMergedTimes = transMergedTimes, ColorMergedTimes = colorMergedTimes,
		Graphs = graphs,
		Seeds = seeds,
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.TEmitTimescale, seeds.Timescale, safeLifeTime),
	}

	pData._sourceItem = trail
	Particle._seedTsOverride(pData, trail)
	if data.Pool ~= false then pData._sourceRT, pData._poolKind = data.RenderTemplate, "TrailEmitter" end
	self:_registerEmit(pData, emitCtx)

	-- Flipbook: cycle visual.Texture through TrailFlipbooks/Decals. FlipBeam is generic over any
	-- target with a Texture property (Trail qualifies); reuse rather than fork a TrailFlipbook
	-- runtime. Mode/framerate/etc. live in the TEmitFlipbook* attrs read by GetData.
	if data.TrailFlipbookMode and data.TrailFlipbooks then
		local decals = MeshFlipbook.GetSortedBeamTextures(data.TrailFlipbooks)
		if #decals > 0 then
			local spec = {
				FlipbookMode = data.TrailFlipbookMode,
				FlipbookFramerate = data.TrailFlipbookFramerate,
				FlipbookStartRandom = data.TrailFlipbookStartRandom,
				FlipbookReverse = data.TrailFlipbookReverse,
			}
			MeshFlipbook.FlipBeam(pData, spec, decals, visual, safeLifeTime)
		end
	end
end

-- Animate mode: operate on the LIVE RenderTemplate. cancelAnimation/finishAnimate restore the
-- snapshotted intrinsic Trail props and disable the trail when the cycle ends.
function Particle:EmitTrailAnimate(trail, link, emitCtx)
	if not trail or not trail.Parent then return end
	if self.ActiveAnimates[trail] then return end
	local data = self:GetEmitData(trail, emitCtx)
	if not data or not data.RenderTemplate then return end

	local visual = data.RenderTemplate -- LIVE source, not a clone

	-- Snapshot BEFORE mutating so cancelAnimation restores authored values (mirrors Beam pattern).
	local snapshot = {
		Lifetime = visual.Lifetime,
		Brightness = visual.Brightness,
		LightEmission = visual.LightEmission,
		LightInfluence = visual.LightInfluence,
		TextureLength = visual.TextureLength,
		MinLength = visual.MinLength,
		MaxLength = visual.MaxLength,
		Texture = visual.Texture,
		TextureMode = visual.TextureMode,
		FaceCamera = visual.FaceCamera,
		WidthScale = visual.WidthScale,
		Transparency = visual.Transparency,
		Color = visual.Color,
		Enabled = visual.Enabled,
	}

	visual.Enabled = true
	-- Static props (Texture/TextureMode/FaceCamera) come from the live source directly (no clone).

	local safeLifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	if safeLifeTime <= 0 then safeLifeTime = 0.001 end
	local trailLifeRange = data.TrailLife or data.Lifetime
	local trailLifeVal = RangeMod.RandomValueFromRange(trailLifeRange)
	if trailLifeVal <= 0 then trailLifeVal = 0.001 end
	visual.Lifetime = trailLifeVal

	local widthStates, transStates, colorStates,
		widthMergedTimes, transMergedTimes, colorMergedTimes = _collectStatesAndMergedTimes(data.GraphBlender)

	if #widthStates > 0 then visual.WidthScale = widthStates[1].Graph end
	if #transStates > 0 then visual.Transparency = transStates[1].Graph end
	if #colorStates > 0 then visual.Color = colorStates[1].Graph end

	local graphs, seeds = _buildScalarGraphs(data)
	for _, key in ipairs(SCALAR_GRAPHS) do
		if graphs[key] then
			visual[key] = GraphMod.QueryPointsWithTime(0, graphs[key], seeds[key])
		end
	end

	local pData = {
		Type = "TrailEmitter",
		VisualPart = visual,
		Link = link,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = math.max(1, data.TotalKeyFrames),
		CurrentStep = 0,
		LifeTime = safeLifeTime,
		PartLife = data.PartLife or 0,
		IsAnimate = true, AnimateItem = trail,
		TrailEmitterSnapshot = snapshot,
		WidthStates = widthStates, TransStates = transStates, ColorStates = colorStates,
		WidthMergedTimes = widthMergedTimes, TransMergedTimes = transMergedTimes, ColorMergedTimes = colorMergedTimes,
		Graphs = graphs,
		Seeds = seeds,
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.TEmitTimescale, seeds.Timescale, safeLifeTime),
	}

	pData._sourceItem = trail
	Particle._seedTsOverride(pData, trail)
	self.ActiveAnimates[trail] = pData
	self:_registerEmit(pData, emitCtx)

	if data.TrailFlipbookMode and data.TrailFlipbooks then
		local decals = MeshFlipbook.GetSortedBeamTextures(data.TrailFlipbooks)
		if #decals > 0 then
			local spec = {
				FlipbookMode = data.TrailFlipbookMode,
				FlipbookFramerate = data.TrailFlipbookFramerate,
				FlipbookStartRandom = data.TrailFlipbookStartRandom,
				FlipbookReverse = data.TrailFlipbookReverse,
			}
			MeshFlipbook.FlipBeam(pData, spec, decals, visual, safeLifeTime)
		end
	end
end

end
