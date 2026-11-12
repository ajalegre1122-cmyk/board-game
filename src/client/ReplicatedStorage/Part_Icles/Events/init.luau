--[[
	Events  -  Part-Icles runtime; helper module (not a mixin).
	  - Compile cache for per-event Modules (clone-and-require, invalidates on Source change).
	  - ChainCtx (ChainId + Depth) propagation; per-event ChainDepthLimit + hard ceiling.
	  - Per-frame burst cap + once-per-second drop reporting.
	  - Payload builder, world-pos/CFrame helpers, Events.fire dispatcher.
	  - emitTargetInstance (EmitTarget.luau): EmitTarget + EmitMode → in place / origin override / fan-out.
	  - afterUpdate: per-frame OnHit raycast.

	Cross-file invariants:
	  - pData.Events is FROZEN at emit (EventsSchema.readEnabled snapshot); hot path never re-reads.
	  - pData.EventChainCtx propagates through _registerEmit + every event fire.
	  - Plugin teardown MUST call Events.cleanup() to release Module connections.
	  - Events.compile refuses every Module in plugin context unless the gate from Modules/ScriptTrust approves.
	  - Sibling mixins: EmitTarget.luau (emitTargetInstance), Hit.luau (afterUpdate).
]]

local TypeRegistry = require(script.Parent.TypeRegistry)
local EventsPayload = require(script.Parent.EventsPayload)
local HitFilter = require(script.Parent.HitFilter)
local Log = require(script.Parent.Log)

local Events = {}

local MAX_EVENT_FIRES_PER_FRAME = 256
local DEFAULT_CHAIN_DEPTH_LIMIT = 4
local HARD_CHAIN_DEPTH_CEILING  = 32
Events.DEFAULT_CHAIN_DEPTH_LIMIT = DEFAULT_CHAIN_DEPTH_LIMIT
local CONFIG_NAME = TypeRegistry.CONFIG_NAME
local EVENTS_FOLDER_NAME = "Events"

-- Per-Module compile cache; key = source ModuleScript. _invalidate clears entries.
local cache = {}

-- Per-frame burst state.
Events._frameCount = 0
Events._burstDropped = 0
Events._burstReportPending = false

local _depthDropPending = false
local _depthDropped = 0

-- Bumped by cleanup() so stale 1s-delay warn closures bail.
local _reportGeneration = 0

-- Warn-once sentinels for emit-mode mismatches.
local _unsupportedOriginWarned = {}
local _nilOriginWarned = {}
Events._unsupportedOriginWarned = _unsupportedOriginWarned
Events._nilOriginWarned = _nilOriginWarned

local _nextChainId = 0
local function nextChainId()
	_nextChainId += 1
	return _nextChainId
end

function Events.newChainCtx()
	return { ChainId = nextChainId(), Depth = 0 }
end

-- Shallow copy emitCtx + EmitIndex (1-based) for burst-loop clones.
function Events.withEmitIndex(emitCtx, i)
	if not emitCtx then return { EmitIndex = i } end
	local out = { EmitIndex = i }
	for k, v in pairs(emitCtx) do
		if k ~= "EmitIndex" then out[k] = v end
	end
	return out
end

-- Shallow copy + EmitIndex + EmitCount; required pair for EvenDistribution sampler.
function Events.withEmitIndexAndCount(emitCtx, i, n)
	if not emitCtx then return { EmitIndex = i, EmitCount = n } end
	local out = { EmitIndex = i, EmitCount = n }
	for k, v in pairs(emitCtx) do
		if k ~= "EmitIndex" and k ~= "EmitCount" then out[k] = v end
	end
	return out
end

-- Shallow copy + within-burst index (i/count) AND a per-emission EvenDistribution
-- rolling-cycle OFFSET (posIdx/posN, rotIdx/rotN, per property). The sampler keeps the
-- i/count even spread unchanged and ADDS the offset (gap/N step) on top, so each emission
-- shifts the whole pattern. posN/rotN are absolute cycle lengths (0 = no offset). Direction
-- (forward/reverse) is already baked into the supplied idx.
function Events.withEvenOffset(emitCtx, i, count, posIdx, posN, rotIdx, rotN)
	local out = { EmitIndex = i, EmitCount = count }
	if emitCtx then
		for k, v in pairs(emitCtx) do
			if k ~= "EmitIndex" and k ~= "EmitCount"
				and k ~= "EvenOffsetIdx_Pos" and k ~= "EvenOffsetN_Pos"
				and k ~= "EvenOffsetIdx_Rot" and k ~= "EvenOffsetN_Rot" then
				out[k] = v
			end
		end
	end
	if posN and posN > 0 then
		out.EvenOffsetIdx_Pos = posIdx
		out.EvenOffsetN_Pos = posN
	end
	if rotN and rotN > 0 then
		out.EvenOffsetIdx_Rot = rotIdx
		out.EvenOffsetN_Rot = rotN
	end
	return out
end

-- Strip origin-override fields when threading emitCtx into a chained sub-emit;
-- preserves ChainCtx + EmitIndex/EmitCount. Used by Events chain dispatches.
function Events.descendCtx(emitCtx)
	if not emitCtx then return nil end
	if emitCtx.EventOriginCF == nil and emitCtx.IgnoreLink == nil
		and emitCtx.UseFullOrigin == nil and emitCtx.EventOriginResolver == nil then
		return emitCtx
	end
	return {
		ChainCtx  = emitCtx.ChainCtx,
		EmitIndex = emitCtx.EmitIndex,
		EmitCount = emitCtx.EmitCount,
	}
end

-- Compile / cache

-- Plugin context allows Source reads; play / non-plugin lacks PluginOrOpenCloud capability.
-- Play mode: skip clone+require (Source immutable anyway, direct require works).
local _isPluginContext = pcall(function() return (Instance.new("ModuleScript")).Source end)

-- Event Modules run with the caller's permissions, so plugin context runs one only when the
-- installed gate approves it; with no gate every Module is refused. Game runtime is not gated.
-- Producer of the gate: Modules/ScriptTrust (per-place approval).
local _scriptGate = nil
local _noGateWarned = false

function Events.setScriptGate(gate)
	_scriptGate = gate
end

function Events.scriptAllowed(moduleScript)
	if not _isPluginContext then return true end
	if _scriptGate then return _scriptGate(moduleScript) == true end
	if not _noGateWarned then
		_noGateWarned = true
		Log.warn("[Part-Icles Events] event scripts do not run in Studio edit mode outside the Part-Icles plugin")
	end
	return false
end

function Events._compile(moduleScript)
	if not _isPluginContext then
		local ok, fn = pcall(require, moduleScript)
		if not ok then return nil, fn elseif type(fn) ~= "function" then return nil, "module must return function(payload)" end
		return fn, nil, nil
	end
	local clone = moduleScript:Clone()
	clone.Name = "_CompiledEventModule"
	clone.Archivable = false
	clone.Parent = moduleScript.Parent
	local ok, fn = pcall(require, clone)
	if not ok then
		clone:Destroy()
		return nil, fn
	end
	if type(fn) ~= "function" then
		clone:Destroy()
		return nil, "module must return function(payload)"
	end
	return fn, nil, clone
end

function Events._isCacheValid(cacheEntry, moduleScript)
	if not cacheEntry or not moduleScript or not moduleScript:IsA("ModuleScript") then return false end
	if moduleScript.Name ~= "Module" then return false end
	local eventCfg = cacheEntry.expectedEventCfg
	if not eventCfg or not eventCfg.Parent then return false end
	if eventCfg.Name ~= cacheEntry.expectedEventName then return false end
	if not eventCfg.Parent or eventCfg.Parent.Name ~= EVENTS_FOLDER_NAME then return false end
	return moduleScript.Parent == eventCfg
end

-- Single chokepoint to release signals + destroy clone + drop cache entry.
function Events._invalidate(moduleScript)
	local entry = cache[moduleScript]
	if not entry then return end
	if entry.sourceConn then entry.sourceConn:Disconnect(); entry.sourceConn = nil end
	if entry.ancestryConn then entry.ancestryConn:Disconnect(); entry.ancestryConn = nil end
	if entry.nameConn then entry.nameConn:Disconnect(); entry.nameConn = nil end
	if entry.compiledClone then
		pcall(function() entry.compiledClone:Destroy() end)
		entry.compiledClone = nil
	end
	cache[moduleScript] = nil
end

-- Get-or-compile; recompiles on dirty (Source changed) or tree-position mismatch.
function Events.compile(moduleScript)
	if not moduleScript or not moduleScript:IsA("ModuleScript") then return nil end
	if not Events.scriptAllowed(moduleScript) then return nil end
	local entry = cache[moduleScript]
	if entry and not entry.dirty and Events._isCacheValid(entry, moduleScript) then
		return entry.fn
	end
	-- Stale entry: invalidate first so signals don't double-fire on the new entry.
	if entry then Events._invalidate(moduleScript) end

	local fn, err, clone = Events._compile(moduleScript)
	if not fn then
		Events.reportScriptError(moduleScript, err)
		return nil
	end

	local eventCfg = moduleScript.Parent
	if not eventCfg or not eventCfg:IsA("Configuration") then
		clone:Destroy()
		return nil
	end

	local newEntry = {
		fn = fn,
		expectedEventCfg = eventCfg,
		expectedEventName = eventCfg.Name,
		dirty = false,
		compiledClone = clone,
	}
	-- Mark dirty on Source-change; recompile lazily on next fire. Play / non-plugin contexts
	-- lack the PluginOrOpenCloud capability and Source is immutable there anyway  -  skip.
	if _isPluginContext then
		newEntry.sourceConn = moduleScript:GetPropertyChangedSignal("Source"):Connect(function()
			if cache[moduleScript] then cache[moduleScript].dirty = true end
		end)
	end
	-- Module dragged out / destroyed → invalidate.
	newEntry.ancestryConn = moduleScript.AncestryChanged:Connect(function()
		if not Events._isCacheValid(cache[moduleScript], moduleScript) then
			Events._invalidate(moduleScript)
		end
	end)
	-- Snap user-renames back to "Module" so the cache-validity check doesn't
	-- treat every fire as stale and trigger a clone+require+destroy cycle.
	newEntry.nameConn = moduleScript:GetPropertyChangedSignal("Name"):Connect(function()
		if moduleScript.Name ~= "Module" then
			pcall(function() moduleScript.Name = "Module" end)
		end
	end)
	cache[moduleScript] = newEntry
	return fn
end

function Events.cleanup()
	-- Snapshot keys first; mutating during pairs() is undefined.
	local keys = {}
	for moduleScript in pairs(cache) do table.insert(keys, moduleScript) end
	for _, moduleScript in ipairs(keys) do Events._invalidate(moduleScript) end
	-- Bump report gen so in-flight task.delay warn closures bail.
	_reportGeneration += 1
	Events._frameCount = 0
	Events._burstDropped = 0
	Events._burstReportPending = false
	_depthDropped = 0
	_depthDropPending = false
	table.clear(_unsupportedOriginWarned)
	table.clear(_nilOriginWarned)
end

-- Burst cap + reporting

-- Once-per-second summary; per-frame would flood Output at 60fps overflow.
function Events._reportBurst()
	Events._burstDropped += 1
	if not Events._burstReportPending then
		Events._burstReportPending = true
		local gen = _reportGeneration
		task.delay(1, function()
			if gen ~= _reportGeneration then return end
			if Events._burstDropped > 0 then
				Log.warn(("[Part-Icles Events] dropped %d event fires this second."):format(Events._burstDropped))
			end
			Events._burstDropped = 0
			Events._burstReportPending = false
		end)
	end
end

function Events.reserveFrameFire()
	if Events._frameCount >= MAX_EVENT_FIRES_PER_FRAME then
		Events._reportBurst()
		return false
	end
	Events._frameCount += 1
	return true
end

-- Called once per Heartbeat to reset the per-frame counter.
function Events.tickFrame()
	Events._frameCount = 0
end

function Events.dropDepth(eventName)
	_depthDropped += 1
	if not _depthDropPending then
		_depthDropPending = true
		local gen = _reportGeneration
		task.delay(1, function()
			if gen ~= _reportGeneration then return end
			if _depthDropped > 0 then
				Log.warn(("[Part-Icles Events] dropped %d event fire(s) this second (chain depth limit reached%s)."):format(
					_depthDropped, eventName and (" on " .. eventName) or ""))
			end
			_depthDropped = 0
			_depthDropPending = false
		end)
	end
end

function Events.reportScriptError(moduleScript, err)
	local path = moduleScript and moduleScript:GetFullName() or "<destroyed>"
	Log.warn(("[Part-Icles Events] %s\n  %s"):format(path, tostring(err)))
end

-- World-position helpers (type-correct across Attachment/Model/Beam/PL/Screen).
function Events.getWorldCF(pData)
	-- VisualPart-less types first. EventsSchema.VALID_PER_TYPE offers OnDestruction only for
	-- types with a branch here (Lifecycle._fireOnDestruction gates on this returning non-nil).
	if pData.Type == "Distortion" then
		if pData._lastOriginPos then return CFrame.new(pData._lastOriginPos) end
		return Events.getSourceWorldCF(pData._sourceItem)
	end
	if pData.Type == "CameraShake" then
		local cam = workspace.CurrentCamera
		return cam and cam.CFrame or nil
	end
	local v = pData.VisualPart
	if not v or not v.Parent then return nil end
	if v:IsA("BasePart") then return v.CFrame end
	if v:IsA("Attachment") then return v.WorldCFrame end
	if v:IsA("Model") then return v:GetPivot() end
	if v:IsA("Light") or v:IsA("Sound") then
		local p = v.Parent
		if p and p:IsA("BasePart") then return p.CFrame end
		if p and p:IsA("Attachment") then return p.WorldCFrame end
		return nil
	end
	if v:IsA("Beam") then
		local a0 = v.Attachment0
		if a0 then
			local a1 = v.Attachment1
			if a1 then return CFrame.new((a0.WorldPosition + a1.WorldPosition) * 0.5) end
			return CFrame.new(a0.WorldPosition)
		end
		return nil
	end
	return nil
end

function Events.getWorldPosition(pData)
	local cf = Events.getWorldCF(pData)
	return cf and cf.Position or nil
end

function Events.getSourceWorldCF(sourceItem)
	if not sourceItem or not sourceItem.Parent then return nil end
	if sourceItem:IsA("BasePart") then return sourceItem.CFrame end
	if sourceItem:IsA("Attachment") then return sourceItem.WorldCFrame end
	if sourceItem:IsA("Model") then return sourceItem:GetPivot() end
	if sourceItem:IsA("Beam") then
		local a0 = sourceItem.Attachment0
		if a0 then
			local a1 = sourceItem.Attachment1
			if a1 then return CFrame.new((a0.WorldPosition + a1.WorldPosition) * 0.5) end
			return CFrame.new(a0.WorldPosition)
		end
		return nil
	end
	if sourceItem:IsA("Light") or sourceItem:IsA("Sound") then
		local p = sourceItem.Parent
		if p and p:IsA("BasePart") then return p.CFrame end
		if p and p:IsA("Attachment") then return p.WorldCFrame end
		return nil
	end
	return nil
end

-- ============================================================================
-- OnHit raycast filter
-- ============================================================================

-- Explicit table.insert because Lua's `{a, nil, b}` literal is sparse; would drop
-- whichever entry is nil and silently shift the rest, omitting later filters.
function Events.makeHitParams(pData)
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	local filter = {}
	if pData.VisualPart then table.insert(filter, pData.VisualPart) end
	if pData._sourceItem then table.insert(filter, pData._sourceItem) end
	if pData._sourceItem then
		local rt = pData._sourceItem:FindFirstChild("RenderTemplate")
		if rt then table.insert(filter, rt) end
		-- EmitParent ObjectValue: filter the picked anchor + its descendants so the
		-- first afterUpdate raycast doesn't fire OnHit on the user's emission anchor.
		local ep = pData._sourceItem:FindFirstChild("EmitParent")
		if ep and ep:IsA("ObjectValue") and ep.Value then
			table.insert(filter, ep.Value)
		end
	end
	-- Attachments self-hit on first ray without filtering parent BasePart.
	if pData.VisualPart and pData.VisualPart:IsA("Attachment") and pData.VisualPart.Parent then
		table.insert(filter, pData.VisualPart.Parent)
	end
	-- Type-level filter shared with Rocks and Lightning Seek (HitFilter.luau). Read once at
	-- emit time so mid-session edits apply to the next emit cycle.
	if pData._sourceItem then
		local group, excludes = HitFilter.read(pData._sourceItem)
		if group ~= "" then
			-- The group may have been deleted in the collision editor since it was picked.
			pcall(function() p.CollisionGroup = group end)
		end
		for _, inst in ipairs(excludes) do table.insert(filter, inst) end
	end
	p.FilterDescendantsInstances = filter
	p.IgnoreWater = true
	return p
end

-- Payload builder. Thin wrapper; per-event field population lives in EventsPayload.build.
function Events.makePayload(particle, pData, eventName, emitCtx)
	return EventsPayload.build(pData, eventName, emitCtx, Events.getWorldCF(pData))
end

-- EmitMode + dispatch

-- Push OnHit spawn off the hit surface along its normal so the emitted particle's first
-- raycast doesn't immediately re-fire OnHit on the same surface.
local ONHIT_SPAWN_NORMAL_OFFSET = 0.1

-- Resolve origin CF for non-AtTarget modes (AtPosition / AtSource / AtCFrame).
-- OnEmit uses LIVE source position so EmitDelay-gapped emits track movement.
-- OnHit: offset along payload.HitNormal so spawn is just outside the surface.
function Events.resolveEmitModeCF(mode, payload, pData)
	if mode == "AtPosition" then
		if payload and payload._eventName == "OnEmit" then
			local cf = Events.getWorldCF(pData)
			if cf then return cf end
			-- Source destroyed mid-EmitDelay; fall back to last-frame CurrentPosition.
			if pData.CurrentPosition then return CFrame.new(pData.CurrentPosition) end
		end
		local pos = payload.HitPosition or payload.DeathPosition or payload.EmitPosition
		if pos and payload._eventName == "OnHit" and payload.HitNormal then
			pos = pos + payload.HitNormal * ONHIT_SPAWN_NORMAL_OFFSET
		end
		return pos and CFrame.new(pos) or nil
	elseif mode == "AtSource" then
		return Events.getSourceWorldCF(pData._sourceItem)
	elseif mode == "AtCFrame" then
		if payload and payload._eventName == "OnEmit" then
			local cf = Events.getWorldCF(pData)
			if cf then return cf end
		end
		local cf = payload and payload.WorldCFrame
		if cf and payload._eventName == "OnHit" and payload.HitNormal then
			cf = cf + payload.HitNormal * ONHIT_SPAWN_NORMAL_OFFSET
		end
		return cf or nil
	end
	return nil
end

-- Fire dispatcher

function Events.fire(particle, pData, eventName, chainCtx, payload)
	chainCtx = chainCtx or Events.newChainCtx()
	local cfg = pData.Events and pData.Events[eventName]
	-- Enabled gate first; disabled events don't burn depth budget or warn.
	if not cfg or not cfg.Enabled then return end

	-- Two depth checks: fire-side (this event) and _emitTransformed-side (downstream fan-out).
	local depthLimit = math.clamp(math.floor(tonumber(cfg.ChainDepthLimit) or DEFAULT_CHAIN_DEPTH_LIMIT), 1, HARD_CHAIN_DEPTH_CEILING)
	if chainCtx.Depth >= depthLimit then
		Events.dropDepth(eventName)
		return
	end

	-- Nothing wired → no dispatch.
	if not cfg.EmitTarget and not cfg.Module then return end

	-- Backfill payload first so payload.X writes below don't nil-index.
	if not payload then
		payload = Events.makePayload(particle, pData, eventName, nil)
	end
	payload._eventName = payload._eventName or eventName

	-- Burst cap after config check.
	if not Events.reserveFrameFire() then return end

	payload.Source = payload.Source or pData._sourceItem
	payload.Particle = payload.Particle or pData.VisualPart
	payload.RenderTemplate = payload.RenderTemplate or payload.Particle

	-- Inject helpers only when Module runs (avoid closure alloc for EmitTarget-only events).
	if cfg.Module then
		payload.Emit = function(target, mode)
			Events.emitTargetInstance(particle, target, mode or cfg.EmitMode, payload, pData, chainCtx, depthLimit)
		end
		payload.Kill = function()
			if particle._killParticle then
				particle:_killParticle(pData, { fireOnDeath = false })
			end
		end
		-- Setters auto-flip the matching skip flag so per-frame graph writes don't clobber the override.
		EventsPayload.attachSkipSetters(payload, pData)
		payload.SetColor = function(color) EventsPayload.applyColor(pData, color) end
		payload.SetTransparency = function(amount) EventsPayload.applyTransparency(pData, amount) end
		payload.Teleport = function(cf) EventsPayload.applyTeleport(pData, cf) end
		EventsPayload.attachAdvancedSetters(payload, pData)
		payload.SetSpeedMultiplier = function(scalar)
			if type(scalar) == "number" then pData.SpeedMultiplier = scalar end
		end
		-- New total LifeTime in seconds. Clamped to 0.001 to avoid div-by-zero in
		-- the real_i (currentTime - StartTime) / LifeTime computation.
		payload.SetLifetime = function(seconds)
			if type(seconds) == "number" then pData.LifeTime = math.max(0.001, seconds) end
		end
	end

	-- Active-particle cap: skip cfg.EmitTarget when at cap, but always run Module.
	local capHit = #particle.ActiveEmits + (particle._lingerVisualCount or 0) >= (particle.MAX_ACTIVE_PARTICLES or 1000)
	if capHit and cfg.EmitTarget and not Events._capSkipWarned then
		Events._capSkipWarned = true
		Log.warn("[Part-Icles Events] active-particle cap reached; event EmitTargets are being skipped")
	end

	if cfg.EmitTarget and not capHit then
		Events.emitTargetInstance(particle, cfg.EmitTarget, cfg.EmitMode, payload, pData, chainCtx, depthLimit)
	end

	if cfg.Module then
		local fn = Events.compile(cfg.Module)
		if fn then
			task.spawn(function()
				local ok, err = xpcall(fn, debug.traceback, payload)
				if not ok then Events.reportScriptError(cfg.Module, err) end
			end)
		end
	end
end

-- Mixins: EmitTarget (emitTargetInstance / _emitTransformed) and Hit (afterUpdate).
require(script.EmitTarget)(Events)
require(script.Hit)(Events)

return Events
