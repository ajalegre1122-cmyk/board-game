--[[
	Highlight Mixin  -  Emit + Update for Highlight particles.
	Non-spatial (no motion). Animates FillColor / FillTransparency / OutlineColor /
	OutlineTransparency over Lifetime via NumberSequence + ColorSequence graphs. Adornee
	resolved at emit: ObjectValue child → link (nested emit adorns the emitted parent
	clone) → source.Adornee → source.Parent.
]]

local GraphMod = require(script.Parent.Graph)
local RangeMod = require(script.Parent.Range)
local Pool = require(script.Parent.Pool)

return function(Particle)

-- Per-frame Heartbeat update for Highlight particles. Samples FillColor / FillTransparency /
-- OutlineColor / OutlineTransparency graphs at the current life step, with SetTimescale override
-- gating the time-axis.
function Particle:UpdateHighlight(pData, dt, currentTime)
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
	if pData.TotalKeyFrames <= 0 then return true end
	local graphFinished = real_i >= 1
	local isDying = graphFinished and (atForwardEnd or atBackwardEnd)
	i = math.min(math.max(i, 0), 1)

	local targetStep = math.floor(i * pData.TotalKeyFrames)

	if targetStep ~= pData.CurrentStep then
		pData.CurrentStep = targetStep
		local steppedI = pData.CurrentStep / pData.TotalKeyFrames

		if pData.Graphs.HLFillColor and not pData.SkipColor then
			pData.VisualPart.FillColor = GraphMod.QueryColorPointWithTime(steppedI, pData.Graphs.HLFillColor)
		end
		if pData.Graphs.HLFillTransparency and not pData.SkipTransparency then
			pData.VisualPart.FillTransparency = GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.HLFillTransparency, pData.Seeds.HLFillTransparency)
		end
		if pData.Graphs.HLOutlineColor and not pData.SkipColor then
			pData.VisualPart.OutlineColor = GraphMod.QueryColorPointWithTime(steppedI, pData.Graphs.HLOutlineColor)
		end
		if pData.Graphs.HLOutlineTransparency and not pData.SkipTransparency then
			pData.VisualPart.OutlineTransparency = GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.HLOutlineTransparency, pData.Seeds.HLOutlineTransparency)
		end
	end

	return isDying
end

-- Adornee resolution: ObjectValue child → link → source.Adornee → source.Parent IF it's a BasePart
-- or Model (highlightable). link is the emitted parent clone during nested emit — adorning it makes
-- the highlight track the particle instead of the hidden source RenderTemplate. Attachment links
-- adorn their holder part. Returning nil silently skips rendering  -  better than accidentally
-- Adorneeing Workspace and highlighting the whole place.
local function _resolveAdornee(data, source, link)
	if data.Adornee then return data.Adornee end
	if link then
		if link:IsA("BasePart") or link:IsA("Model") then return link end
		if link:IsA("Attachment") then
			local holder = link.Parent
			if holder and (holder:IsA("BasePart") or holder:IsA("Model")) then return holder end
		end
	end
	local cur = source.Adornee
	if cur then return cur end
	local p = source.Parent
	if p and (p:IsA("BasePart") or p:IsA("Model")) then return p end
	return nil
end

-- Spawn a Highlight particle: clones RenderTemplate, resolves Adornee, registers in ActiveEmits.
function Particle:EmitHighlight(highlight, link, emitCtx)
	if not highlight or not highlight.Parent then return end
	local data = self:GetEmitData(highlight, emitCtx)
	if not data or not data.RenderTemplate then return end

	-- PoolHide flipped Enabled=false on release; flip back here.
	local visual = Pool.acquireOrClone(data.RenderTemplate, "Highlight", data.Pool)
	visual.Archivable = false
	visual.Enabled = true
	if data.HLDepthMode then visual.DepthMode = data.HLDepthMode end
	visual.Adornee = _resolveAdornee(data, highlight, link)
	-- Renders through Adornee; the instance lives in a local clone or the live folder, never the user's part.
	local parentInstance = data.EmitParent or link or self:GetFolder()

	local safeLifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	if safeLifeTime <= 0 then safeLifeTime = 0.001 end

	local seedFillTrans = data.HLFillTransparency and GraphMod.GenerateSeed(data.HLFillTransparency) or {}
	local seedOutlineTrans = data.HLOutlineTransparency and GraphMod.GenerateSeed(data.HLOutlineTransparency) or {}
	local seedTimescale = GraphMod.GenerateSeed(data.HLTimescale)

	-- Apply initial values before parenting (1-frame pop prevention).
	if data.HLFillColor then
		visual.FillColor = GraphMod.QueryColorPointWithTime(0, data.HLFillColor)
	end
	if data.HLFillTransparency then
		visual.FillTransparency = GraphMod.QueryPointsWithTime(0, data.HLFillTransparency, seedFillTrans)
	end
	if data.HLOutlineColor then
		visual.OutlineColor = GraphMod.QueryColorPointWithTime(0, data.HLOutlineColor)
	end
	if data.HLOutlineTransparency then
		visual.OutlineTransparency = GraphMod.QueryPointsWithTime(0, data.HLOutlineTransparency, seedOutlineTrans)
	end

	visual.Parent = parentInstance

	local pData = {
		Type = "Highlight",
		VisualPart = visual,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = math.max(1, data.TotalKeyFrames),
		CurrentStep = 0,
		LifeTime = safeLifeTime,
		PartLife = data.PartLife or 0,

		Graphs = {
			HLFillColor = data.HLFillColor,
			HLFillTransparency = data.HLFillTransparency,
			HLOutlineColor = data.HLOutlineColor,
			HLOutlineTransparency = data.HLOutlineTransparency,
			Timescale = data.HLTimescale,
		},
		Seeds = {
			HLFillTransparency = seedFillTrans,
			HLOutlineTransparency = seedOutlineTrans,
			Timescale = seedTimescale,
		},
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.HLTimescale, seedTimescale, safeLifeTime),
	}

	pData._sourceItem = highlight
	Particle._seedTsOverride(pData, highlight)
	if data.Pool ~= false then pData._sourceRT, pData._poolKind = data.RenderTemplate, "Highlight" end
	self:_registerEmit(pData, emitCtx)
end

-- Animate mode: operate on live RenderTemplate (no clone). Lifecycle.cancelAnimation restores the
-- intrinsic FillColor / Transparency / OutlineColor / Transparency from BeamSnapshot-equivalent.
function Particle:EmitHighlightAnimate(highlight, link, emitCtx)
	if not highlight or not highlight.Parent then return end
	if self.ActiveAnimates[highlight] then return end
	local data = self:GetEmitData(highlight, emitCtx)
	if not data or not data.RenderTemplate then return end

	local visual = data.RenderTemplate -- LIVE source, not a clone

	-- Snapshot BEFORE mutating so cancelAnimation restores authored values (mirrors Beam pattern).
	local snapshot = {
		FillColor = visual.FillColor,
		FillTransparency = visual.FillTransparency,
		OutlineColor = visual.OutlineColor,
		OutlineTransparency = visual.OutlineTransparency,
		DepthMode = visual.DepthMode,
		Adornee = visual.Adornee,
		Enabled = visual.Enabled,
	}

	visual.Enabled = true
	if data.HLDepthMode then visual.DepthMode = data.HLDepthMode end
	visual.Adornee = _resolveAdornee(data, highlight, link)

	local safeLifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	if safeLifeTime <= 0 then safeLifeTime = 0.001 end

	local seedFillTrans = data.HLFillTransparency and GraphMod.GenerateSeed(data.HLFillTransparency) or {}
	local seedOutlineTrans = data.HLOutlineTransparency and GraphMod.GenerateSeed(data.HLOutlineTransparency) or {}
	local seedTimescale = GraphMod.GenerateSeed(data.HLTimescale)

	local pData = {
		Type = "Highlight",
		VisualPart = visual,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = math.max(1, data.TotalKeyFrames),
		CurrentStep = 0,
		LifeTime = safeLifeTime,
		PartLife = data.PartLife or 0,
		IsAnimate = true,
		AnimateItem = highlight,
		HighlightSnapshot = snapshot,

		Graphs = {
			HLFillColor = data.HLFillColor,
			HLFillTransparency = data.HLFillTransparency,
			HLOutlineColor = data.HLOutlineColor,
			HLOutlineTransparency = data.HLOutlineTransparency,
			Timescale = data.HLTimescale,
		},
		Seeds = {
			HLFillTransparency = seedFillTrans,
			HLOutlineTransparency = seedOutlineTrans,
			Timescale = seedTimescale,
		},
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.HLTimescale, seedTimescale, safeLifeTime),
	}

	pData._sourceItem = highlight
	Particle._seedTsOverride(pData, highlight)
	self.ActiveAnimates[highlight] = pData
	self:_registerEmit(pData, emitCtx)
end

end
