--[[
	Lightning/Rig  -  bolt Model + rig-buffer construction and pool acquire.
	Split from Lightning/init (500-line cap). Owns the weak-keyed Rigs map so
	buffers survive pool release/acquire cycles and gc with the model.
]]

local Pool = require(script.Parent.Parent.Pool)
local GraphMod = require(script.Parent.Parent.Graph)
local BoltGen = require(script.Parent.BoltGen)

local MAX_BOLT_PARTS = 64
local FAR_CFRAME = CFrame.new(1e9, 1e9, 1e9)

local Rig = {}

Rig.MAX_BOLT_PARTS = MAX_BOLT_PARTS
Rig.FAR_CFRAME = FAR_CFRAME

-- Weak-keyed by bolt Model.
Rig.Rigs = setmetatable({}, { __mode = "k" })

-- One segment part cloned from the RT. copyBare strips Transformed children (nested
-- source Part-Icles fire once per BOLT via NestedEmit.walk, never per segment).
-- Returns the first Decal/Texture child too: Transform hides RT decals (Transparency=1),
-- so writeVisuals must drive them alongside the part.
local function buildSegment(rt)
	local seg = Pool.copyBare(rt)
	seg.Anchored = true
	seg.CanCollide = false
	seg.CanQuery = false
	seg.CanTouch = false
	seg.Massless = true
	seg.Locked = true
	seg.Archivable = false
	seg.Transparency = 0
	local decal = seg:FindFirstChildWhichIsA("Decal") or seg:FindFirstChildWhichIsA("Texture")
	return seg, decal
end

-- Rig layout sizes for the range MAXIMUMS; each bolt rolls its own values within
-- them and parks unused slots at FAR_CFRAME.
function Rig.layoutFor(data)
	return BoltGen.layout(data.SegmentCount.Max, data.ForkDepth.Max, data.ForkChance.Max, MAX_BOLT_PARTS)
end

-- Fresh bolt Model + rig with every buffer pre-sized. Called on pool miss or when
-- the defensive rig check fails on a pool hit.
function Rig.buildRig(data)
	local partCount, mainSegs, forkSegs, forkSlots = Rig.layoutFor(data)
	local model = Instance.new("Model")
	model.Name = "LightningBolt"
	model.Archivable = false
	-- Consumed by EmitPointLight: nested lights fan out per segment on bolt Models.
	model:SetAttribute("_lightningBolt", true)
	local rig = {
		partCount = partCount, mainSegs = mainSegs,
		forkSegs = forkSegs, forkSlots = forkSlots,
		parts = table.create(partCount),
		rollCFs = table.create(partCount),
		writeCFs = table.create(partCount),
		segLen = table.create(partCount),
		revealDist = table.create(partCount),
		revealOrder = table.create(partCount),
		widthScale = table.create(partCount),
		decals = table.create(partCount),
		slotDepth = table.create(math.max(forkSlots, 1)),
		ptBuf = table.create(mainSegs + 1),
		basePtBuf = table.create(mainSegs + 1),
		forkPtBuf = table.create(forkSegs + 1),
		forkAnchorPos = {}, forkAnchorDir = {}, forkAnchorReveal = {},
		forkAnchorSlot = {}, forkAnchorPtIdx = {},
		-- Per-slot fork retention for scroll-mode re-anchoring (BoltGen.applyScrollForks).
		forkOriginIdx = {}, forkParentSlot = {}, forkParentPtIdx = {},
		forkLen = {}, forkU = {}, forkV = {}, forkSeedU = {}, forkSeedV = {},
		-- Taper bookkeeping (Rig.applyTaper): where each fork leaves its parent's arc.
		forkStartReveal = {}, forkStartFrac = {},
		forkLocalPts = {}, forkWorldPts = {},
		-- Skip-write caches (BoltGen.diffLive / planSizes).
		prevLive = table.create(partCount),
		lastWrittenLen = table.create(partCount),
		sizeWriteIdx = table.create(partCount),
		newlyLiveIdx = table.create(partCount),
		-- Per-part spatial Gradient sample, recomputed each roll (arc positions move).
		gradColor = table.create(partCount),
		-- Per-part Taper multiplier on Thickness, recomputed each roll.
		taper = table.create(partCount),
	}
	for slot = 1, forkSlots do
		rig.forkLocalPts[slot] = table.create(forkSegs + 1)
		rig.forkWorldPts[slot] = table.create(forkSegs + 1)
		rig.forkOriginIdx[slot] = 0
		rig.forkParentSlot[slot] = 0
	end
	-- Slot depth is fixed at build: first half depth 1, remainder depth 2. Width per
	-- part is a build-time constant (main = 1, forks scale by ForkLengthScale^depth).
	local depth1Slots = forkSlots > 0 and math.max(1, math.ceil(forkSlots / 2)) or 0
	for slot = 1, forkSlots do
		rig.slotDepth[slot] = slot <= depth1Slots and 1 or 2
	end
	-- Fork WIDTH decouples from ForkLengthScale with a floor: at small length scales
	-- length-coupled widths shrink forks to invisible hairlines (0.4² x 0.15-stud
	-- thickness = 0.024 studs).
	local lenScale = math.max(0.45, data.ForkLengthScale and data.ForkLengthScale.Max or 0.4)
	for i = 1, partCount do
		local seg, decal = buildSegment(data.RenderTemplate)
		seg.Name = "Seg" .. i
		seg.CFrame = FAR_CFRAME
		seg.Parent = model
		rig.parts[i] = seg
		rig.decals[i] = decal
		rig.rollCFs[i] = FAR_CFRAME
		rig.writeCFs[i] = FAR_CFRAME
		rig.segLen[i] = 0.05
		rig.revealDist[i] = math.huge
		rig.revealOrder[i] = i
		rig.prevLive[i] = false
		-- Sentinel: first planSizes write is unconditional per part.
		rig.lastWrittenLen[i] = -1
		rig.taper[i] = 1
		if i <= mainSegs then
			rig.widthScale[i] = 1
		else
			local slot = math.floor((i - mainSegs - 1) / forkSegs) + 1
			rig.widthScale[i] = lenScale ^ (rig.slotDepth[slot] or 1)
		end
	end
	Rig.Rigs[model] = rig
	return model, rig
end

-- Per-part width multiplier from the Taper profile (arc 0 = source, 1 = tip). Main parts read
-- their arc fraction of the main polyline; fork parts continue the parent's fraction at the
-- branch point to 1 over the fork's own length. A changed multiplier stamps the planSizes
-- force sentinel so the next flush resizes that part. No profile = every multiplier 1.
function Rig.applyTaper(rig, profile, seed, mainLen)
	local invMain = 1 / math.max(mainLen or 0, 1e-4)
	for i = 1, rig.partCount do
		local revealDist = rig.revealDist[i]
		local value = 1
		if profile and revealDist ~= math.huge then
			local frac
			if i <= rig.mainSegs then
				frac = (revealDist + rig.segLen[i] * 0.5) * invMain
			else
				local slot = math.floor((i - rig.mainSegs - 1) / rig.forkSegs) + 1
				local startFrac = rig.forkStartFrac[slot] or 0
				local along = revealDist - (rig.forkStartReveal[slot] or 0) + rig.segLen[i] * 0.5
				local localFrac = math.clamp(along / math.max(rig.forkLen[slot] or 1, 1e-4), 0, 1)
				frac = startFrac + localFrac * (1 - startFrac)
			end
			value = math.max(GraphMod.QueryPointsWithTime(math.clamp(frac, 0, 1), profile, seed), 0)
		end
		if value ~= rig.taper[i] then
			rig.taper[i] = value
			rig.lastWrittenLen[i] = -1
		end
	end
end

-- Rebuild the GrowthSpeed reveal mask against the current _tipDist over the freshly
-- sorted reveal order. reversed = negative GrowthSpeed: the strike travels from the
-- far end back toward the source (a segment shows once its far-end distance from
-- maxReveal falls within tipDist). Returns the new reveal pointer.
local function rebuildRevealMask(rig, tipDist, reversed)
	local ptr = 0
	local maxReveal = rig.maxReveal or 0
	for k = 1, rig.partCount do
		local idx = rig.revealOrder[k]
		local rd = rig.revealDist[idx]
		local visible
		if reversed then
			visible = rd ~= math.huge and (rd + rig.segLen[idx]) >= (maxReveal - tipDist)
		else
			visible = rd <= tipDist
		end
		if visible then
			rig.writeCFs[idx] = rig.rollCFs[idx]
			ptr = k
		else
			rig.writeCFs[idx] = FAR_CFRAME
		end
	end
	return ptr
end

-- Shared CFrame flush: reveal mask (GrowthSpeed) + batch write. atEmit runs before
-- the model is parented, so it writes CFrames directly (BulkMoveTo requires
-- workspace ancestry).
function Rig.flushCFrames(pData, atEmit)
	local rig = pData._rig
	local useReveal = pData._lSpeed ~= 0
	if useReveal then
		pData._revealPtr = rebuildRevealMask(rig, pData._tipDist or 0, pData._growReversed)
	end
	local cfs = useReveal and rig.writeCFs or rig.rollCFs
	if atEmit then
		for i = 1, rig.partCount do rig.parts[i].CFrame = cfs[i] end
	else
		workspace:BulkMoveTo(rig.parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- Pool acquire with defensive rig re-check: a foreign / externally-mutilated model
-- or a layout change that slipped past the _PoolGen flush rebuilds fresh.
function Rig.acquireBolt(data)
	local expected = Rig.layoutFor(data)
	if data.Pool ~= false then
		local model = Pool.acquire(data.RenderTemplate, "Lightning")
		if model then
			local rig = Rig.Rigs[model]
			if rig and rig.partCount == expected and rig.parts[1] and rig.parts[1].Parent == model then
				model:SetAttribute("_PartIcleEmit", true)
				return model, rig
			end
			pcall(function() model:Destroy() end)
		end
	end
	local model, rig = Rig.buildRig(data)
	model:SetAttribute("_PartIcleEmit", true)
	return model, rig
end

return Rig
