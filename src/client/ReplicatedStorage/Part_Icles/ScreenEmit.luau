-- ScreenEmit  -  Emit / Animate / Update for Blur, Bloom, ColorCorrection, Atmosphere.
-- Property-only animation, clone-per-emit. Animate mode is singleton (re-emits while active drop).

local GraphMod = require(script.Parent.Graph)
local VisualHost = require(script.Parent.VisualHost)
local RangeMod = require(script.Parent.Range)

return function(Particle)

-- EmitParent override wins, else the local camera (Atmosphere: Lighting). Source location never used as default.
local function resolveScreenParent(data, kind)
	if data.EmitParent then return data.EmitParent end
	return VisualHost.screenEffectParent(kind)
end

-- Atmosphere uses AtmTimescale attr; normalize to Graphs.Timescale here.
local function buildGraphs(kind, data)
	if kind == "Blur" then
		return { BlurSize = data.BlurSize, Timescale = data.Timescale }
	elseif kind == "Bloom" then
		return { BloomIntensity = data.BloomIntensity, BloomSize = data.BloomSize, BloomThreshold = data.BloomThreshold, Timescale = data.Timescale }
	elseif kind == "CC" then
		return { CCBrightness = data.CCBrightness, CCContrast = data.CCContrast, CCSaturation = data.CCSaturation, CCTintColor = data.CCTintColor, Timescale = data.Timescale }
	elseif kind == "Atmosphere" then
		return { AtmDensity = data.AtmDensity, AtmOffset = data.AtmOffset, AtmGlare = data.AtmGlare, AtmHaze = data.AtmHaze, AtmColor = data.AtmColor, AtmDecay = data.AtmDecay, Timescale = data.AtmTimescale }
	end
	return {}
end

-- ColorSequences skip seeds.
local function buildSeeds(graphs)
	local seeds = {}
	for k, g in pairs(graphs) do
		if typeof(g) == "NumberSequence" then seeds[k] = GraphMod.GenerateSeed(g) end
	end
	return seeds
end

-- Write a graph/color sample to the visual; kind routes to the property name.
-- skipColor / skipTransparency gate respective channel writes (sourced from pData
-- via payload.SetSkipColor / SetSkipTransparency in user Module scripts).
local function writeSample(kind, visual, graphs, seeds, t, skipColor, skipTransparency)
	if kind == "Blur" and graphs.BlurSize then
		visual.Size = GraphMod.QueryPointsWithTime(t, graphs.BlurSize, seeds.BlurSize)
	elseif kind == "Bloom" then
		if graphs.BloomIntensity then visual.Intensity = GraphMod.QueryPointsWithTime(t, graphs.BloomIntensity, seeds.BloomIntensity) end
		if graphs.BloomSize then visual.Size = GraphMod.QueryPointsWithTime(t, graphs.BloomSize, seeds.BloomSize) end
		if graphs.BloomThreshold then visual.Threshold = GraphMod.QueryPointsWithTime(t, graphs.BloomThreshold, seeds.BloomThreshold) end
	elseif kind == "CC" then
		if graphs.CCBrightness and not skipTransparency then visual.Brightness = GraphMod.QueryPointsWithTime(t, graphs.CCBrightness, seeds.CCBrightness) end
		if graphs.CCContrast then visual.Contrast = GraphMod.QueryPointsWithTime(t, graphs.CCContrast, seeds.CCContrast) end
		if graphs.CCSaturation then visual.Saturation = GraphMod.QueryPointsWithTime(t, graphs.CCSaturation, seeds.CCSaturation) end
		if graphs.CCTintColor and not skipColor then visual.TintColor = GraphMod.QueryColorPointWithTime(t, graphs.CCTintColor) end
	elseif kind == "Atmosphere" then
		if graphs.AtmDensity then visual.Density = GraphMod.QueryPointsWithTime(t, graphs.AtmDensity, seeds.AtmDensity) end
		if graphs.AtmOffset then visual.Offset = GraphMod.QueryPointsWithTime(t, graphs.AtmOffset, seeds.AtmOffset) end
		if graphs.AtmGlare then visual.Glare = GraphMod.QueryPointsWithTime(t, graphs.AtmGlare, seeds.AtmGlare) end
		if graphs.AtmHaze then visual.Haze = GraphMod.QueryPointsWithTime(t, graphs.AtmHaze, seeds.AtmHaze) end
		if graphs.AtmColor and not skipColor then visual.Color = GraphMod.QueryColorPointWithTime(t, graphs.AtmColor) end
		if graphs.AtmDecay and not skipColor then visual.Decay = GraphMod.QueryColorPointWithTime(t, graphs.AtmDecay) end
	end
end

-- Atmosphere has no Enabled; PostProcessEffect kinds do.
local function kindHasEnabled(kind)
	return kind ~= "Atmosphere"
end

-- Emit-mode: clone RT, apply initial sample BEFORE Parent (avoid 1-frame pop), push pData.
local function emitClone(self, kind, item, link, emitCtx)
	local data = self:GetEmitData(item, emitCtx)
	if not data or not data.RenderTemplate then return end

	local visual = data.RenderTemplate:Clone()
	visual.Archivable = false
	if kindHasEnabled(kind) then visual.Enabled = true end
	visual:SetAttribute("_PartIcleEmit", true)

	local safeLife = RangeMod.RandomValueFromRange(data.Lifetime)
	if safeLife <= 0 then safeLife = 0.001 end

	local graphs = buildGraphs(kind, data)
	local seeds = buildSeeds(graphs)
	writeSample(kind, visual, graphs, seeds, 0)

	visual.Parent = resolveScreenParent(data, kind)

	local pData = {
		Type = "Screen", Kind = kind,
		VisualPart = visual,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = math.max(1, data.TotalKeyFrames or 100), CurrentStep = 0,
		LifeTime = safeLife, PartLife = data.PartLife or 0,
		Graphs = graphs, Seeds = seeds,
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(graphs.Timescale, seeds.Timescale, safeLife),
		_sourceItem = item,
	}
	Particle._seedTsOverride(pData, item)
	self:_registerEmit(pData, emitCtx)
end

-- Singleton Animate: clone, play, destroy on end. Re-emits while active are no-ops.
local function emitAnimateInternal(self, kind, item, link, emitCtx)
	if self.ActiveAnimates[item] then return end

	local data = self:GetEmitData(item, emitCtx)
	if not data or not data.RenderTemplate then return end

	local visual = data.RenderTemplate:Clone()
	visual.Archivable = false
	if kindHasEnabled(kind) then visual.Enabled = true end
	visual:SetAttribute("_PartIcleEmit", true)

	local safeLife = RangeMod.RandomValueFromRange(data.Lifetime)
	if safeLife <= 0 then safeLife = 0.001 end

	local graphs = buildGraphs(kind, data)
	local seeds = buildSeeds(graphs)
	writeSample(kind, visual, graphs, seeds, 0)

	visual.Parent = resolveScreenParent(data, kind)

	local pData = {
		Type = "Screen", Kind = kind,
		VisualPart = visual,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = math.max(1, data.TotalKeyFrames or 100), CurrentStep = 0,
		LifeTime = safeLife, PartLife = data.PartLife or 0,
		Graphs = graphs, Seeds = seeds,
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(graphs.Timescale, seeds.Timescale, safeLife),
		IsAnimate = true, AnimateItem = item,
	}
	pData._sourceItem = item
	Particle._seedTsOverride(pData, item)
	self.ActiveAnimates[item] = pData
	self:_registerEmit(pData, emitCtx)
end

-- Per-kind public entry points (dispatched from Emit / EmitAnimate)

function Particle:EmitBlur(item, link, emitCtx) emitClone(self, "Blur", item, link, emitCtx) end
function Particle:EmitBloom(item, link, emitCtx) emitClone(self, "Bloom", item, link, emitCtx) end
function Particle:EmitColorCorrection(item, link, emitCtx) emitClone(self, "CC", item, link, emitCtx) end
function Particle:EmitAtmosphere(item, link, emitCtx) emitClone(self, "Atmosphere", item, link, emitCtx) end

function Particle:EmitBlurAnimate(item, link, emitCtx) emitAnimateInternal(self, "Blur", item, link, emitCtx) end
function Particle:EmitBloomAnimate(item, link, emitCtx) emitAnimateInternal(self, "Bloom", item, link, emitCtx) end
function Particle:EmitColorCorrectionAnimate(item, link, emitCtx) emitAnimateInternal(self, "CC", item, link, emitCtx) end
function Particle:EmitAtmosphereAnimate(item, link, emitCtx) emitAnimateInternal(self, "Atmosphere", item, link, emitCtx) end

-- Per-frame update; returns true when lifetime ends (Heartbeat culls via swap-and-pop).
function Particle:UpdateScreen(pData, dt, currentTime)
	if not pData.VisualPart or not pData.VisualPart.Parent then return true end
	if pData.TotalKeyFrames <= 0 then return true end

	-- Timescale v2 (signed reverse): see Update.luau UpdatePart. SetTimescale override wins for its window.
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
	local elapsed = newEff
	local i = elapsed / lifeTime
	local graphFinished = real_i >= 1
	local isDying = graphFinished and (atForwardEnd or atBackwardEnd)
	if i > 1 then i = 1 end
	if i < 0 then i = 0 end

	local targetStep = math.floor(i * pData.TotalKeyFrames)
	if targetStep ~= pData.CurrentStep then
		pData.CurrentStep = targetStep
		local t = pData.CurrentStep / pData.TotalKeyFrames
		writeSample(pData.Kind, pData.VisualPart, pData.Graphs, pData.Seeds, t, pData.SkipColor, pData.SkipTransparency)
	end

	return isDying
end

end
