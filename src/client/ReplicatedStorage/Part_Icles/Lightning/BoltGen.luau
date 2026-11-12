--[[
	BoltGen  -  pure lightning-bolt geometry. No engine/pool knowledge.
	Midpoint displacement over caller-owned buffers: every roll overwrites slots in
	the rig arrays allocated once by Lightning/init.buildRig  -  zero table creation
	per roll. Fork slots have build-time-fixed depth; unused slots park at farCF with
	revealDist = math.huge so the growth reveal never shows them.
]]

local BoltGen = {}

local FORK_MIN_ANGLE = math.rad(15)
local FORK_MAX_ANGLE = math.rad(45)
local MIN_SEG_LEN = 0.05

-- Part-count layout for a config. mainSegs = clamped SegmentCount; forks are
-- polylines of half resolution. Clamps forkSlots so the total stays <= maxParts.
-- Slot depths are fixed by position: first half depth 1, remainder depth 2.
function BoltGen.layout(segmentCount, forkDepth, forkChance, maxParts)
	local mainSegs = math.clamp(math.floor(segmentCount or 12), 2, maxParts)
	local forkSlots = 0
	local forkSegs = math.max(2, math.floor(mainSegs / 2))
	-- >= 0.5 matches PDataBuilder's round-to-nearest on the per-bolt roll, so a
	-- ForkDepth that rounds to 1 also gets slots allocated.
	if (forkDepth or 0) >= 0.5 and (forkChance or 0) > 0 then
		local remaining = maxParts - mainSegs
		-- High Segments can leave less part budget than one half-resolution fork;
		-- shrink the per-fork resolution before surrendering slots (a 4-segment
		-- fork beats zero forks).
		if remaining >= 4 and math.floor(remaining / forkSegs) < 2 then
			forkSegs = math.max(4, math.min(forkSegs, math.floor(remaining / 2)))
		end
		forkSlots = math.min(6, math.floor(remaining / forkSegs))
		if forkSlots < 0 then forkSlots = 0 end
	end
	return mainSegs + forkSlots * forkSegs, mainSegs, forkSegs, forkSlots
end

-- Orthonormal basis perpendicular to dir; degenerate dir falls back to world axes.
function BoltGen.basis(dir)
	if dir.Magnitude < 1e-4 then return Vector3.xAxis, Vector3.zAxis end
	local unit = dir.Unit
	local ref = math.abs(unit.Y) < 0.99 and Vector3.yAxis or Vector3.xAxis
	local u = unit:Cross(ref).Unit
	local v = unit:Cross(u)
	return u, v
end

-- Recursive midpoint displacement over pts[lo..hi] (endpoints already set).
-- Offsets in the u/v plane; amplitude decays per level.
local function displace(pts, lo, hi, amp, decay, u, v)
	if hi - lo <= 1 then return end
	local mid = math.floor((lo + hi) / 2)
	local t = (mid - lo) / (hi - lo)
	pts[mid] = pts[lo]:Lerp(pts[hi], t)
		+ u * ((math.random() * 2 - 1) * amp)
		+ v * ((math.random() * 2 - 1) * amp)
	local nextAmp = amp * decay
	displace(pts, lo, mid, nextAmp, decay, u, v)
	displace(pts, mid, hi, nextAmp, decay, u, v)
end

-- Fill pts[1..segs+1] with a polyline from startPos toward endPos. jitter=false
-- skips midpoint displacement (Scroll mode base). Sag applies AFTER displacement:
-- the midpoint recursion lerps between endpoints, so a pre-applied droop would be
-- overwritten.
local function buildPolyline(pts, segs, startPos, endPos, amp, decay, sag, jitter, sagDir, sagShape)
	local delta = endPos - startPos
	local dist = delta.Magnitude
	for i = 1, segs + 1 do
		pts[i] = startPos + delta * ((i - 1) / segs)
	end
	if jitter and amp ~= 0 then
		local u, v = BoltGen.basis(delta)
		displace(pts, 1, segs + 1, amp, decay, u, v)
	end
	-- Signed: negative sag arches upward, along frame down (sagDir, DisplacementMode).
	-- sagShape >= 1: exponent profile (1 = parabola, higher = pointier). Below 1 the
	-- path morphs through EXACT circular-arc geometry: 0.5 = the circle whose sagitta
	-- is the sag depth (past a semicircle it wraps outward as a horseshoe), 0 = square
	-- trough, in-between = point-wise blend. The blend zone bulges along the chord-
	-- perpendicular component of sagDir (arc geometry needs a perpendicular axis).
	if sag ~= 0 and dist > 1e-4 then
		local droop = (sagDir or Vector3.yAxis) * (sag >= 0 and -1 or 1)
		local shape = math.max(sagShape or 1, 0)
		local h = math.abs(sag) * dist
		if shape >= 1 then
			for i = 2, segs do
				local t = (i - 1) / segs
				local profile = 4 * t * (1 - t)
				if shape ~= 1 then profile = profile ^ shape end
				pts[i] = pts[i] + droop * (h * profile)
			end
		else
			local u = delta * (1 / dist)
			local bulge = droop - u * droop:Dot(u)
			if bulge.Magnitude > 1e-4 then
				bulge = bulge.Unit
				-- Sagitta circle through both endpoints: r from chord + depth.
				-- acos, not two-arg atan: Luau's math.atan is single-argument (it
				-- silently ignores a second argument, unlike Lua 5.3).
				local r = (dist * dist * 0.25 + h * h) / (2 * h)
				local halfSweep = math.acos(math.clamp((r - h) / r, -1, 1))
				local center = startPos + delta * 0.5 + bulge * (h - r)
				for i = 2, segs do
					local t = (i - 1) / segs
					local base = startPos + delta * t
					local phi = (2 * t - 1) * halfSweep
					local arcPt = center + (u * math.sin(phi) + bulge * math.cos(phi)) * r
					local target
					if shape >= 0.5 then
						local parabolaPt = base + bulge * (h * 4 * t * (1 - t))
						target = arcPt:Lerp(parabolaPt, (shape - 0.5) * 2)
					else
						local troughPt = base + bulge * h
						target = troughPt:Lerp(arcPt, shape * 2)
					end
					pts[i] = pts[i] + (target - base)
				end
			end
		end
	end
end

-- Write segment CFrames/lengths/reveal distances for pts[1..segs+1] into rig slots
-- starting at slotBase+1. revealBase = arc distance already travelled before this
-- polyline begins (0 for the main bolt, branch-point distance for forks).
local function writeSegments(rig, pts, segs, slotBase, revealBase)
	local arc = revealBase
	for i = 1, segs do
		local p0, p1 = pts[i], pts[i + 1]
		local seg = p1 - p0
		local len = seg.Magnitude
		local slot = slotBase + i
		rig.revealDist[slot] = arc
		if len > 1e-4 then
			rig.rollCFs[slot] = CFrame.lookAt((p0 + p1) * 0.5, p1)
		else
			rig.rollCFs[slot] = CFrame.new((p0 + p1) * 0.5)
		end
		rig.segLen[slot] = math.max(len, MIN_SEG_LEN)
		arc += len
	end
	return arc - revealBase
end

-- One full geometry roll. Overwrites rig buffers only. params reads: _amplitude
-- (fraction of bolt length), _decay, _forkChance, _forkDepth, _forkLenScale, _sag.
-- Returns the main polyline's arc length.
function BoltGen.roll(rig, params, startPos, endPos, farCF)
	-- Per-bolt segment count within the max-sized rig; leftover main slots park far.
	local mainSegs = math.clamp(params._segCount or rig.mainSegs, 2, rig.mainSegs)
	local dist = (endPos - startPos).Magnitude
	local amp = (params._amplitude or 0) * dist
	local mode = params._shapeMode or "Jitter"

	-- Scroll = straight+sag base (traveling wave applied per frame by applyScroll);
	-- Jitter/JitterScroll = midpoint-displaced base re-rolled here at JitterRate.
	buildPolyline(rig.ptBuf, mainSegs, startPos, endPos, amp, params._decay or 0.5, params._sag or 0, mode ~= "Scroll",
		params._sagDirWorld, params._sagShape)
	if mode ~= "Jitter" then
		for i = 1, mainSegs + 1 do rig.basePtBuf[i] = rig.ptBuf[i] end
		rig.scrollU, rig.scrollV = BoltGen.basis(endPos - startPos)
		rig.scrollDist = dist
	end
	rig.curSegs = mainSegs
	local totalLen = writeSegments(rig, rig.ptBuf, mainSegs, 0, 0)
	for i = mainSegs + 1, rig.mainSegs do
		rig.rollCFs[i] = farCF
		rig.segLen[i] = MIN_SEG_LEN
		rig.revealDist[i] = math.huge
	end

	-- Forks. Depth-1 slots branch off the main polyline; depth-2 slots branch off a
	-- depth-1 fork that fired THIS roll (anchor cached per slot). Chance-gated per roll.
	local forkSlots = rig.forkSlots
	local depth1Fired = 0
	for slot = 1, forkSlots do
		-- Slot layout is FIXED at rig.mainSegs (range Max); only the polyline uses the
		-- per-bolt rolled count.
		local slotBase = rig.mainSegs + (slot - 1) * rig.forkSegs
		local depth = rig.slotDepth[slot]
		local fired = false
		if (params._forkChance or 0) > math.random() and (params._forkDepth or 0) >= depth then
			local originPos, originDir, originReveal
			local originIdx, parentSlot, parentPtIdx = 0, 0, 0
			if depth == 1 then
				local idx = math.random(2, mainSegs)
				originPos = rig.ptBuf[idx]
				originDir = (rig.ptBuf[idx + 1] or endPos) - originPos
				-- Point idx is the START of segment idx; revealDist[idx] is the arc there.
				originReveal = rig.revealDist[idx] or 0
				originIdx = idx
			elseif depth1Fired > 0 then
				local src = math.random(1, depth1Fired)
				originPos = rig.forkAnchorPos[src]
				originDir = rig.forkAnchorDir[src]
				originReveal = rig.forkAnchorReveal[src]
				parentSlot = rig.forkAnchorSlot[src]
				parentPtIdx = rig.forkAnchorPtIdx[src]
			end
			if originPos and originDir and originDir.Magnitude > 1e-4 then
				local scale = (params._forkLenScale or 0.4) ^ depth
				local forkLen = math.max(1, dist * scale)
				local u, v = BoltGen.basis(originDir)
				local phi = math.random() * math.pi * 2
				local axis = u * math.cos(phi) + v * math.sin(phi)
				local ang = FORK_MIN_ANGLE + math.random() * (FORK_MAX_ANGLE - FORK_MIN_ANGLE)
				local forkDir = CFrame.fromAxisAngle(axis, ang):VectorToWorldSpace(originDir.Unit)
				local forkEnd = originPos + forkDir * forkLen
				buildPolyline(rig.forkPtBuf, rig.forkSegs, originPos, forkEnd, amp * scale, params._decay or 0.5, 0, true)
				writeSegments(rig, rig.forkPtBuf, rig.forkSegs, slotBase, originReveal)
				-- Retain fork geometry LOCAL to its root + the anchor identity so scroll
				-- modes can re-anchor to the moving main polyline per frame.
				local lp = rig.forkLocalPts[slot]
				for i = 1, rig.forkSegs + 1 do lp[i] = rig.forkPtBuf[i] - originPos end
				rig.forkOriginIdx[slot] = originIdx or 0
				rig.forkParentSlot[slot] = parentSlot or 0
				rig.forkParentPtIdx[slot] = parentPtIdx or 0
				rig.forkLen[slot] = forkLen
				-- Taper continuation: the parent's arc fraction at the branch point (Rig.applyTaper).
				rig.forkStartReveal[slot] = originReveal
				if depth == 1 then
					rig.forkStartFrac[slot] = originReveal / math.max(totalLen, 1e-4)
				else
					local parentStart = rig.forkStartFrac[parentSlot] or 0
					local parentLocal = (originReveal - (rig.forkStartReveal[parentSlot] or 0)) / math.max(rig.forkLen[parentSlot] or 1, 1e-4)
					rig.forkStartFrac[slot] = parentStart + math.clamp(parentLocal, 0, 1) * (1 - parentStart)
				end
				local fu, fv = BoltGen.basis(forkDir)
				rig.forkU[slot], rig.forkV[slot] = fu, fv
				rig.forkSeedU[slot] = math.random() * 100
				rig.forkSeedV[slot] = 100 + math.random() * 100
				if depth == 1 then
					depth1Fired += 1
					local midIdx = math.max(2, math.floor(rig.forkSegs / 2) + 1)
					rig.forkAnchorPos[depth1Fired] = rig.forkPtBuf[midIdx]
					rig.forkAnchorDir[depth1Fired] = forkDir
					rig.forkAnchorReveal[depth1Fired] = originReveal
					rig.forkAnchorSlot[depth1Fired] = slot
					rig.forkAnchorPtIdx[depth1Fired] = midIdx
				end
				fired = true
			end
		end
		if not fired then
			rig.forkOriginIdx[slot] = 0
			rig.forkParentSlot[slot] = 0
			for i = 1, rig.forkSegs do
				local slotIdx = slotBase + i
				rig.rollCFs[slotIdx] = farCF
				rig.segLen[slotIdx] = MIN_SEG_LEN
				rig.revealDist[slotIdx] = math.huge
			end
		end
	end

	-- Max reveal distance (arc at the farthest segment END, forks included)  -
	-- reverse GrowthSpeed measures from here back toward the source.
	local maxReveal = 0
	for i = 1, rig.partCount do
		local rd = rig.revealDist[i]
		if rd ~= math.huge and rd + rig.segLen[i] > maxReveal then
			maxReveal = rd + rig.segLen[i]
		end
	end
	rig.maxReveal = maxReveal

	-- Reveal order: indices ascending by revealDist. In-place insertion sort  -
	-- <= 64 ints, mostly-sorted between rolls.
	BoltGen.sortReveal(rig)

	return totalLen
end

-- Diff live-vs-parked after a roll. Fills rig.newlyLiveIdx[1..m], updates
-- rig.prevLive, and stamps a lastWrittenLen sentinel on newly-live slots so
-- planSizes force-writes their Size (width can drift while a slot is parked).
-- Liveness = revealDist ~= huge; only BoltGen.roll changes it, so callers run
-- this once per roll (never per scroll frame).
function BoltGen.diffLive(rig)
	local m = 0
	for i = 1, rig.partCount do
		local live = rig.revealDist[i] ~= math.huge
		if live and not rig.prevLive[i] then
			m += 1
			rig.newlyLiveIdx[m] = i
			rig.lastWrittenLen[i] = -1
		end
		rig.prevLive[i] = live
	end
	return m
end

-- Plan which parts need a Size write this flush: fills rig.sizeWriteIdx[1..n]
-- and maintains the rig.lastWrittenLen / rig.lastThick caches. EXACT compares
-- only  -  rendered geometry must stay bit-identical to unconditional writes.
-- Parked slots are skipped entirely (their Size is invisible at farCF; the
-- diffLive sentinel forces a write when they revive). Every Size write path in
-- Lightning/init.luau MUST go through this plan or the caches lie.
function BoltGen.planSizes(rig, thick, force)
	local thickChanged = force or thick ~= rig.lastThick
	local n = 0
	for i = 1, rig.partCount do
		if rig.revealDist[i] ~= math.huge then
			local len = rig.segLen[i]
			if thickChanged or len ~= rig.lastWrittenLen[i] then
				n += 1
				rig.sizeWriteIdx[n] = i
				rig.lastWrittenLen[i] = len
			end
		end
	end
	rig.lastThick = thick
	return n
end

-- Per-frame traveling wave (Scroll / JitterScroll). Adds 2-octave Perlin offsets in
-- the roll-time u/v basis to the cached base polyline, endpoint-pinned by 4s(1-s),
-- then rewrites MAIN segment CFrames/lengths in place. Fork slots + revealDist stay
-- from the last full roll. Buffer slot writes only  -  no table allocation.
function BoltGen.applyScroll(rig, params, phase)
	local segs = rig.curSegs
	local u, v = rig.scrollU, rig.scrollV
	if not segs or segs < 2 or not u then return end
	local amp = (params._amplitude or 0) * (rig.scrollDist or 0)
	local waves = params._waves or 3
	local decay = params._decay or 0.5
	local seedA = params._noiseSeedA or 0
	local seedB = params._noiseSeedB or 500
	local pts, base = rig.ptBuf, rig.basePtBuf
	for i = 1, segs + 1 do
		local s = (i - 1) / segs
		-- Squared taper: zero slope at the pinned endpoints so the wave fades in
		-- instead of kinking the exit direction (plain 4s(1-s) has max slope there).
		local env = 4 * s * (1 - s)
		env = env * env
		local x1 = s * waves - phase
		local x2 = s * waves * 2.7 - phase * 1.6
		local offU = (math.noise(x1, seedA) + math.noise(x2, seedA + 37.1) * decay) * amp * env
		local offV = (math.noise(x1, seedB) + math.noise(x2, seedB + 37.1) * decay) * amp * env
		pts[i] = base[i] + u * offU + v * offV
	end
	for i = 1, segs do
		local p0, p1 = pts[i], pts[i + 1]
		local seg = p1 - p0
		local len = seg.Magnitude
		if len > 1e-4 then
			rig.rollCFs[i] = CFrame.lookAt((p0 + p1) * 0.5, p1)
		else
			rig.rollCFs[i] = CFrame.new((p0 + p1) * 0.5)
		end
		rig.segLen[i] = math.max(len, MIN_SEG_LEN)
	end
end

-- Per-frame fork re-anchor + scroll (Scroll / JitterScroll). Each fired fork's root
-- follows the CURRENT (scrolled) main polyline point (depth-2 forks follow their
-- parent fork's current midpoint  -  depth-1 slots come first in slot order, so
-- parents are always up to date); the fork body adds its own root-pinned Perlin
-- wave with a per-slot seed and slightly offset phase so branches move
-- independently of the trunk. Buffer slot writes only.
function BoltGen.applyScrollForks(rig, params, phase)
	local segs = rig.forkSegs
	local waves = params._waves or 3
	for slot = 1, rig.forkSlots do
		local originIdx = rig.forkOriginIdx[slot] or 0
		local parentSlot = rig.forkParentSlot[slot] or 0
		if originIdx ~= 0 or parentSlot ~= 0 then
			local root
			if parentSlot ~= 0 then
				local pw = rig.forkWorldPts[parentSlot]
				root = pw and pw[rig.forkParentPtIdx[slot]]
			else
				root = rig.ptBuf[originIdx]
			end
			if root then
				local lp = rig.forkLocalPts[slot]
				local wp = rig.forkWorldPts[slot]
				local u, v = rig.forkU[slot], rig.forkV[slot]
				local amp = (params._amplitude or 0) * (rig.forkLen[slot] or 1)
				local su = rig.forkSeedU[slot] or 0
				local sv = rig.forkSeedV[slot] or 50
				for i = 1, segs + 1 do
					local s = (i - 1) / segs
					local x1 = s * waves - phase * 1.35
					wp[i] = root + lp[i]
						+ u * (math.noise(x1, su) * amp * s)
						+ v * (math.noise(x1, sv) * amp * s)
				end
				local slotBase = rig.mainSegs + (slot - 1) * segs
				for i = 1, segs do
					local p0, p1 = wp[i], wp[i + 1]
					local d = p1 - p0
					local len = d.Magnitude
					local idx = slotBase + i
					if len > 1e-4 then
						rig.rollCFs[idx] = CFrame.lookAt((p0 + p1) * 0.5, p1)
					else
						rig.rollCFs[idx] = CFrame.new((p0 + p1) * 0.5)
					end
					rig.segLen[idx] = math.max(len, MIN_SEG_LEN)
				end
			end
		end
	end
end

-- In-place insertion sort of revealOrder by revealDist.
function BoltGen.sortReveal(rig)
	local order, rd = rig.revealOrder, rig.revealDist
	for i = 2, rig.partCount do
		local key = order[i]
		local keyDist = rd[key]
		local j = i - 1
		while j >= 1 and rd[order[j]] > keyDist do
			order[j + 1] = order[j]
			j -= 1
		end
		order[j + 1] = key
	end
end

return BoltGen
