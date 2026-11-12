--[[
	EvenCycle  -  rolling-cycle math for rate-mode EvenDistribution sampling.
	Per-property cycle length sampled from a NumberRange attribute at every cycle
	wrap. Sign of N drives direction: positive = forward (idx walks 1..|N|), negative
	= reverse (|N|..1). 0 or default zero-range falls back to current cfg.Rate (forward).
]]

local EvenCycle = {}
local EngineAttr = require(script.Parent.EngineAttr)

-- Sample N from a NumberRange cycle attribute stored on the PartIcleProperties
-- Configuration child. Sign-preserving floor to integer.
function EvenCycle.resolve(config, attrName, fallbackRate)
	local r = config and config:GetAttribute(attrName)
	if typeof(r) ~= "NumberRange" or (r.Min == 0 and r.Max == 0) then
		return math.max(1, math.floor(fallbackRate or 12))
	end
	local n = r.Min + (r.Max - r.Min) * math.random()
	n = math.floor(n + (n >= 0 and 0.5 or -0.5))
	if n == 0 then return math.max(1, math.floor(fallbackRate or 12)) end
	return n
end

-- One step of a per-property cycle. On cycle wrap (or first step), re-samples
-- signedN + seeds idx at 1 (forward) or |N| (reverse). Returns (idx, signedN, absN).
function EvenCycle.step(idx, signedN, config, attrName, fallbackRate)
	local absN = math.abs(signedN)
	local function reroll()
		signedN = EvenCycle.resolve(config, attrName, fallbackRate)
		absN = math.abs(signedN)
		if signedN > 0 then idx = 1 else idx = absN end
	end
	if absN == 0 or idx == 0 then
		reroll()
	elseif signedN > 0 then
		idx = idx + 1
		if idx > absN then reroll() end
	else
		idx = idx - 1
		if idx < 1 then reroll() end
	end
	return idx, signedN, absN
end

-- Whether Position / Rotation EvenDistribution is on (PartIcleProperties config flags).
function EvenCycle.evenFlags(config)
	if not config then return false, false end
	local hasPos = (config:GetAttribute("PosXEven") or config:GetAttribute("PosYEven") or config:GetAttribute("PosZEven")) == true
	local hasRot = (config:GetAttribute("RotXEven") or config:GetAttribute("RotYEven") or config:GetAttribute("RotZEven")) == true
	return hasPos, hasRot
end

-- Persistent per-emitter stepping. `store` is a table keyed by a stable emitter id
-- (one slot per authored emitter, shared by all its clones) holding
-- {posIdx, posSignedN, rotIdx, rotSignedN}. Steps each enabled axis once and writes
-- the advanced state back, so discrete bursts and nested re-emits roll the same cycle
-- the continuous loop does. The slot table allocates once per key (first emission);
-- steady-state reuses it in place (zero-alloc hot loop).
function EvenCycle.advance(store, key, config, currentRate, hasPosEven, hasRotEven)
	local slot = store[key]
	if not slot then
		slot = { 0, 0, 0, 0 }
		store[key] = slot
	end
	local posIdx, posAbs, rotIdx, rotAbs = 0, 0, 0, 0
	-- Only roll (offset) when the cycle is EXPLICITLY set; unset = plain even spread.
	if hasPosEven and EvenCycle.isSet(config, "PositionEvenCycle") then
		slot[1], slot[2], posAbs = EvenCycle.step(slot[1], slot[2], config, "PositionEvenCycle", currentRate)
		posIdx = slot[1]
	end
	if hasRotEven and EvenCycle.isSet(config, "RotationEvenCycle") then
		slot[3], slot[4], rotAbs = EvenCycle.step(slot[3], slot[4], config, "RotationEvenCycle", currentRate)
		rotIdx = slot[3]
	end
	return posIdx, posAbs, rotIdx, rotAbs
end

-- True only when the cycle NumberRange attribute is present and non-zero (user set it).
function EvenCycle.isSet(config, attrName)
	local r = config and config:GetAttribute(attrName)
	return typeof(r) == "NumberRange" and not (r.Min == 0 and r.Max == 0)
end

-- Drop a key's cycle state so the next emission restarts at idx 1. Called on full stop.
function EvenCycle.clear(store, key)
	if store and key ~= nil then
		store[key] = nil
	end
end

-- Backfill `_EvenCycleId` for emitters transformed before the id existed: stamp the
-- authored item + any Transformed descendant of its RenderTemplate (the nested
-- emitters that get cloned), so their clones inherit a shared id. No-op once stamped.
-- New transforms get the id at Transform time; this only catches pre-existing saves.
function EvenCycle.ensureIds(item)
	if item:GetAttribute("_EvenCycleId") then return end
	local HttpService = game:GetService("HttpService")
	EngineAttr.write(item, "_EvenCycleId", HttpService:GenerateGUID(false))
	local rt = item:FindFirstChild("RenderTemplate")
	if not rt then return end
	for _, desc in ipairs(rt:GetDescendants()) do
		if desc:GetAttribute("Transformed") and not desc:GetAttribute("_EvenCycleId") then
			EngineAttr.write(desc, "_EvenCycleId", HttpService:GenerateGUID(false))
		end
	end
end

return EvenCycle
