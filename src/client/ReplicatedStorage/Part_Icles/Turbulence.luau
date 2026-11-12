--[[
	Turbulence  -  Perlin-noise wander shared by Part / Attachment / Model / Lightning.
	Absolute offset at normalized life i:
	  turb(i) = amp(i) * (noise(t, seed, K0), noise(t, seed, K1), noise(t, seed, K2))
	with t = i * LifeTime * TurbulenceFrequency. Deterministic in i, so reverse
	Timescale and the InvertMotion pre-sim replay the same wander path. Consumers
	integrate a telescoping delta against pData._prevTurbOff  -  separate from
	_prevWorldOff because OnHit Bounce mirrors re-baseline only the PosOffset
	accumulator (EventsCollision.luau); noise is statistically symmetric so it
	never mirrors.
]]

local GraphMod = require(script.Parent.Graph)
local Constants = require(script.Parent.PartConstants)

-- Non-integer axis decorrelation offsets (math.noise returns 0 on the integer lattice).
local K0, K1, K2 = 0.17, 137.7, 291.3

local Turbulence = {}

-- Flat-zero envelopes (the writeDefaults stamp) count as "no turbulence" so idle
-- emitters skip the per-frame noise work entirely.
function Turbulence.isLive(seq)
	if not seq then return nil end
	if GraphMod.IsStatic(seq) and GraphMod.GetStaticValue(seq, 0) == 0 then return nil end
	return seq
end

-- Absolute pre-DisplacementMode offset at normalized life i.
function Turbulence.sampleRaw(ampGraph, ampSeed, turbSeed, freq, lifeTime, i)
	local amp = GraphMod.QueryPointsWithTime(i, ampGraph, ampSeed)
	if amp == 0 then return Vector3.zero end
	local t = i * lifeTime * freq
	return Vector3.new(
		amp * math.noise(t, turbSeed, K0),
		amp * math.noise(t, turbSeed, K1),
		amp * math.noise(t, turbSeed, K2))
end

-- Resolve the absolute offset at i into the DisplacementMode frame (no mirror args).
local function resolvedAt(pData, i)
	return Constants.resolveDisplacement(
		Turbulence.sampleRaw(pData.Graphs.Turbulence, pData.Seeds.Turbulence,
			pData._turbSeed, pData.TurbulenceFrequency, pData.LifeTime, i),
		pData.DisplacementMode or "Global", pData.SpawnRotation, pData.SpawnEmitterRotation)
end

-- World-space frame delta vs the previous sample (telescoping vs _prevTurbOff).
function Turbulence.frameDelta(pData, steppedI)
	local worldOff = resolvedAt(pData, steppedI)
	local delta = worldOff - pData._prevTurbOff
	pData._prevTurbOff = worldOff
	return delta
end

-- Stamp graph/seed/flags onto a freshly built pData and prime the accumulator at
-- turb(0) WITHOUT shifting the spawn pose: wander is relative to the spawn point,
-- and reversing time back to t=0 returns exactly to it. Must run AFTER
-- SpawnRotation / SpawnEmitterRotation / LifeTime are set on pData.
function Turbulence.buildInto(pData, data)
	local seq = Turbulence.isLive(data.Turbulence)
	pData.HasTurbulence = seq ~= nil
	if not seq then
		-- AnimateLoop replay re-runs this: clear a prior cycle's graph when the
		-- user edits Turbulence back to flat 0 mid-loop.
		pData.Graphs.Turbulence = nil
		return
	end
	pData.Graphs.Turbulence = seq
	-- Reuse seeds the InvertMotion pre-sim already rolled into the shared seeds
	-- table (Transform.luau PreSimulateForward) so live replay matches the cache.
	pData.Seeds.Turbulence = pData.Seeds.Turbulence or GraphMod.GenerateSeed(seq)
	pData.TurbulenceFrequency = data.TurbulenceFrequency or 1
	pData._turbSeed = pData.Seeds._turbSeed or (math.random() * 997 + 0.5)
	pData._prevTurbOff = resolvedAt(pData, 0)
end

-- Re-prime at AnimateLoop cycle restart (same seed → each cycle replays the same wander).
function Turbulence.reprime(pData)
	if not pData.HasTurbulence then return end
	pData._prevTurbOff = resolvedAt(pData, 0)
end

return Turbulence
