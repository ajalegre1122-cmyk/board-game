--[[
	Duration  -  compute true real-time wallclock for an emit dispatch.
	Honors EmitDelay, EmitDuration ranges, AnimateLoop, PartLife, and Timescale
	graph distortion (numerical integration; piecewise-linear graphs have no closed form).
	Returns nil to signal "effectively infinite" (AnimateLoop unbounded, Timescale=0,
	or Timescale clamps to a sign that never reaches the death boundary).
]]

local Graph = require(script.Parent.Graph)

local Duration = {}

local INTEGRATION_STEPS = 200

local function resolveDuration(raw)
	if raw == nil then return 0 end
	if typeof(raw) == "number" then return raw end
	local vals = {}
	for v in tostring(raw):gmatch("[^,]+") do
		local n = tonumber(v:match("^%s*(.-)%s*$"))
		if n then table.insert(vals, n) end
	end
	if #vals == 0 then return 0 end
	if #vals == 1 then return vals[1] end
	return math.max(vals[1], vals[2])
end

-- Wallclock time from spawn to death for one particle authored with the given
-- lifetime + Timescale curve. Two-phase: integrate ts(real_i) for real_i in [0,1]
-- (wall time 0 → lifetime), then if effective hasn't crossed the boundary, extend
-- with the terminal ts(1) value held constant until the boundary is reached.
function Duration.computeTrueLifetime(lifetime, timescaleGraph, seed)
	if not lifetime or lifetime <= 0 then return 0 end
	if not timescaleGraph then return lifetime end

	if Graph.IsStatic(timescaleGraph) then
		local v = Graph.GetStaticValue(timescaleGraph, 1)
		if v == 1 then return lifetime end
		if v == 0 then return nil end
		if v > 0 then return lifetime / v end
		return lifetime / (-v)
	end

	local seed_ = seed or {}
	local ts0 = Graph.QueryPointsWithTime(0, timescaleGraph, seed_)
	local reverse = ts0 < 0
	local eff = reverse and lifetime or 0
	local realT = 0
	local dRealT = lifetime / INTEGRATION_STEPS

	for i = 1, INTEGRATION_STEPS do
		local real_i = i / INTEGRATION_STEPS
		local ts = Graph.QueryPointsWithTime(real_i, timescaleGraph, seed_)
		local prevEff = eff
		eff = eff + ts * dRealT
		if not reverse and eff >= lifetime then
			local frac = (lifetime - prevEff) / (eff - prevEff)
			return realT + frac * dRealT
		end
		if reverse and eff <= 0 then
			local frac = prevEff / (prevEff - eff)
			return realT + frac * dRealT
		end
		realT = realT + dRealT
	end

	-- Phase 2: real_i clamps at 1, ts stays constant at ts(1) per Update.luau math.
	local tsTerminal = Graph.QueryPointsWithTime(1, timescaleGraph, seed_)
	if reverse then
		if tsTerminal >= 0 then return nil end
		return realT + eff / (-tsTerminal)
	end
	if tsTerminal <= 0 then return nil end
	return realT + (lifetime - eff) / tsTerminal
end

-- Returns a lifecycle descriptor for a single item, or nil when the item is not
-- fire-eligible (no count, no duration, not a recognized emitter type). `overrides`
-- (EmitAt options Count / Delay / Duration) replace a transformed item's attributes.
-- Descriptor fields:
--   emitDelay   = scheduling delay before this item starts firing
--   emitDur     = burst window or continuous-Enable duration in seconds
--   lifecycle   = trailing real-time after emit ends until the last spawned particle dies
--   infinite    = true when this item is unbounded (AnimateLoop without EmitDuration,
--                 or Timescale that never reaches the death boundary)
function Duration.computeItemLifecycle(item, overrides)
	if item:GetAttribute("Transformed") then
		local config = item:FindFirstChild("PartIcleProperties")
		local emitDelay = item:GetAttribute("EmitDelay") or 0
		local emitDur = resolveDuration(item:GetAttribute("EmitDuration"))
		local rawCount = item:GetAttribute("EmitCount")
		local count = rawCount == nil and 1 or rawCount
		if overrides then
			if overrides.Delay ~= nil then emitDelay = overrides.Delay end
			if overrides.Duration ~= nil then emitDur = resolveDuration(overrides.Duration) end
			if overrides.Count ~= nil then count = overrides.Count end
		end
		local emissionMode = item:GetAttribute("EmissionMode") or "Emit"
		local animateLoop = item:GetAttribute("AnimateLoop") == true

		if emissionMode == "Animate" and animateLoop and emitDur <= 0 then
			return { emitDelay = emitDelay, emitDur = 0, lifecycle = 0, infinite = true }
		end
		local fires = (count > 0) or (emitDur > 0) or (emissionMode == "Animate")
		if not fires then return nil end

		local lifetime = config and config:GetAttribute("Lifetime")
		local lifetimeMax = 0
		if typeof(lifetime) == "NumberRange" then lifetimeMax = lifetime.Max
		elseif type(lifetime) == "number" then lifetimeMax = lifetime end

		local timescale = config and config:GetAttribute("Timescale")
		local trueLife = Duration.computeTrueLifetime(lifetimeMax, timescale, nil)
		if trueLife == nil then
			return { emitDelay = emitDelay, emitDur = emitDur, lifecycle = 0, infinite = true }
		end

		local partLife = (config and config:GetAttribute("PartLife")) or 0
		-- Animate mode runs at minimum one full lifecycle even with EmitDuration=0.
		if emissionMode == "Animate" and trueLife > emitDur then emitDur = trueLife end

		return { emitDelay = emitDelay, emitDur = emitDur, lifecycle = trueLife + partLife, infinite = false }
	end

	if item:IsA("ParticleEmitter") then
		local rawCount = item:GetAttribute("EmitCount")
		local count = rawCount == nil and 1 or rawCount
		local emitDelay = tonumber(item:GetAttribute("EmitDelay")) or 0
		local emitDur = tonumber(item:GetAttribute("EmitDuration")) or 0
		if count <= 0 and emitDur <= 0 then return nil end
		local life = item.Lifetime
		local lifeMax = (typeof(life) == "NumberRange" and life.Max) or 0
		return { emitDelay = emitDelay, emitDur = emitDur, lifecycle = lifeMax, infinite = false }
	end

	if item:IsA("Trail") then
		local tDelay = item:GetAttribute("EmitDelay") or 0
		local tDur = resolveDuration(item:GetAttribute("EmitDuration"))
		if tDur <= 0 then return nil end
		return { emitDelay = tDelay, emitDur = tDur, lifecycle = item.Lifetime or 0, infinite = false }
	end

	if item:IsA("Beam") then
		local bDelay = tonumber(item:GetAttribute("EmitDelay")) or 0
		local bDur = tonumber(item:GetAttribute("EmitDuration")) or 0
		if bDur <= 0 then return nil end
		return { emitDelay = bDelay, emitDur = bDur, lifecycle = 0, infinite = false }
	end

	return nil
end

-- Recursive walk. Returns the max finish-time across this item and its emit-eligible
-- descendants, OR nil if any branch is infinite. Mirrors EmitDispatch.descendantMaxEmitTime
-- traversal: transformed-no-op short-circuits subtree, RenderTemplate children only
-- recurse into transformed descendants (nested per-clone emitters). `overrides` reach the
-- items the call fires directly, never the nested emitters inside a RenderTemplate.
function Duration.computeMaxDuration(item, accumDelay, overrides)
	if not item then return 0 end
	accumDelay = accumDelay or 0

	local info = Duration.computeItemLifecycle(item, overrides)
	local myFinish = 0
	local childAccum = accumDelay
	local skipChildren = false

	if info then
		if info.infinite then return nil end
		myFinish = accumDelay + info.emitDelay + info.emitDur + info.lifecycle
		childAccum = accumDelay + info.emitDelay
		if item:GetAttribute("Transformed") then
			-- Transformed-but-no-fire would have returned nil above; non-fire descendants
			-- inside a transformed item don't run as their own AbsoluteEmit.
		end
	else
		if item:GetAttribute("Transformed") then
			skipChildren = true
		end
	end

	if not skipChildren then
		for _, child in ipairs(item:GetChildren()) do
			if child.Name == "RenderTemplate" then
				for _, desc in ipairs(child:GetDescendants()) do
					if desc:GetAttribute("Transformed") then
						local sub = Duration.computeMaxDuration(desc, childAccum)
						if sub == nil then return nil end
						if sub > myFinish then myFinish = sub end
					end
				end
			else
				local sub = Duration.computeMaxDuration(child, childAccum, overrides)
				if sub == nil then return nil end
				if sub > myFinish then myFinish = sub end
			end
		end
	end

	return myFinish
end

return Duration
